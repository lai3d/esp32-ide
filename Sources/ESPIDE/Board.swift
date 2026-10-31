import AppKit
import ESPIDECore
import Observation

/// The connected ESP32: serial port, REPL transcript, program output and the board's files.
@MainActor
@Observable
final class Board {
    enum State: Equatable {
        case disconnected
        case connected
        /// A command is using the raw REPL (upload, listing, …).
        case busy(String)
    }

    private(set) var ports: [String] = []
    /// The chosen port, remembered across launches.
    var port: String? = UserDefaults.standard.string(forKey: "port") {
        didSet { UserDefaults.standard.set(port, forKey: "port") }
    }
    private(set) var state: State = .disconnected
    private(set) var connectedPort: String?
    /// The interactive REPL transcript.
    private(set) var terminal = ""
    /// Output of the program started with Run.
    private(set) var output = ""
    private(set) var isRunning = false
    private(set) var files: [DeviceFile] = []
    private(set) var filesLoaded = false
    /// Set when something fails, shown in the status bar.
    var onStatus: ((String) -> Void)?
    /// Switches the bottom panel (Output / REPL) when a command starts.
    var onShowPanel: ((BottomTab) -> Void)?

    @ObservationIgnored private var device: MicroPythonDevice?
    @ObservationIgnored private var portScanner: Task<Void, Never>?
    @ObservationIgnored private var runTask: Task<Void, Never>?

    var isConnected: Bool { state != .disconnected }
    var isIdle: Bool { state == .connected && !isRunning }

    var statusLabel: String {
        switch state {
        case .disconnected: "Not connected"
        case .connected: isRunning ? "Running on \(portName)" : "Connected: \(portName)"
        case let .busy(what): "\(what)…"
        }
    }

    private var portName: String { (connectedPort ?? port ?? "").replacingOccurrences(of: "/dev/cu.", with: "") }

    init() {
        refreshPorts()
        // Plugging a board in or out changes /dev; keep the menu current.
        portScanner = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.refreshPorts()
            }
        }
    }

    func refreshPorts() {
        let found = SerialPort.availablePorts()
        if found != ports { ports = found }
        if port == nil || !(ports.contains(port!) || port == connectedPort) { port = ports.first ?? port }
    }

    // MARK: - Connection

    func connect() {
        guard device == nil else { return }
        refreshPorts()
        guard let port else {
            onStatus?("No board found — plug it in with a data USB cable")
            return
        }
        do {
            let serial = try SerialPort(path: port)
            let device = MicroPythonDevice(transport: serial)
            device.onTerminalOutput = { [weak self] text in
                Task { @MainActor in self?.appendTerminal(text) }
            }
            device.onDisconnect = { [weak self] in
                Task { @MainActor in self?.handleDisconnect(message: "Board disconnected") }
            }
            self.device = device
            connectedPort = port
            state = .connected
            appendTerminal("\n# Connected to \(port). Press ⏹ (Ctrl-C) to stop main.py and get a >>> prompt.\n")
            onShowPanel?(.repl)
            refreshFiles()
        } catch {
            onStatus?(error.localizedDescription)
            appendTerminal("\n# \(error.localizedDescription)\n")
        }
    }

    func disconnect() {
        runTask?.cancel()
        device?.close()
        handleDisconnect(message: "Disconnected")
    }

    private func handleDisconnect(message: String) {
        guard device != nil else { return }
        device = nil
        connectedPort = nil
        state = .disconnected
        isRunning = false
        files = []
        filesLoaded = false
        appendTerminal("\n# \(message)\n")
    }

    func toggleConnection() {
        isConnected ? disconnect() : connect()
    }

    // MARK: - REPL

    func sendLine(_ line: String) {
        guard let device else { return }
        do {
            if isRunning {
                // A running program reads it with input().
                appendOutput(line + "\n")
                try device.sendTerminal(line + "\r")
            } else {
                try device.sendTerminal(line + "\r")
            }
        } catch {
            onStatus?(error.localizedDescription)
        }
    }

    /// Sends code to the interactive REPL through paste mode.
    func paste(_ code: String) {
        guard let device, isIdle else {
            onStatus?(isConnected ? "The board is busy" : "Connect to a board first")
            return
        }
        onShowPanel?(.repl)
        try? device.paste(code)
    }

    /// Ctrl-C: stops main.py or the program started with Run.
    func interrupt() {
        device?.interrupt()
    }

    /// Ctrl-D: restarts MicroPython, running boot.py and main.py.
    func softReset() {
        guard let device, isIdle else { return }
        onShowPanel?(.repl)
        try? device.softReset()
    }

    func clearTerminal() { terminal = "" }

    private func appendTerminal(_ text: String) {
        TerminalText.append(text, to: &terminal)
        if terminal.utf16.count > 400_000 { terminal = String(terminal.suffix(300_000)) }
    }

    // MARK: - Run

    /// Runs code on a freshly reset interpreter without saving it to the board (like `mpremote run`).
    func run(_ code: String, name: String) {
        guard let device else {
            onStatus?("Connect to a board first")
            return
        }
        guard isIdle else { return }
        output = "$ run \(name) on \(portName)\n"
        isRunning = true
        onShowPanel?(.output)
        runTask = Task {
            do {
                _ = try await device.withRawREPL(softReset: true) { session in
                    try await session.exec(code, timeout: nil) { text in
                        Task { @MainActor in self.appendOutput(text) }
                    }
                }
                // Let the last streamed chunks land before the footer.
                try? await Task.sleep(for: .milliseconds(30))
                appendOutput("\n[finished]\n")
            } catch let error as DeviceError {
                try? await Task.sleep(for: .milliseconds(30))
                if case let .exception(traceback) = error {
                    appendOutput(TerminalText.cleaned(traceback))
                    appendOutput(traceback.contains("KeyboardInterrupt") ? "\n[stopped]\n" : "\n[failed]\n")
                } else {
                    appendOutput("\n[\(error.localizedDescription)]\n")
                }
            } catch {
                appendOutput("\n[\(error.localizedDescription)]\n")
            }
            isRunning = false
            runTask = nil
        }
    }

    func stop() {
        guard isRunning else { return }
        device?.interrupt()
    }

    private func appendOutput(_ text: String) {
        TerminalText.append(text, to: &output)
        if output.utf16.count > 400_000 { output = String(output.suffix(300_000)) }
    }

    // MARK: - Files

    func refreshFiles() {
        perform("Reading files") { session in
            let files = try await session.listFiles()
            await MainActor.run {
                self.files = files
                self.filesLoaded = true
            }
        }
    }

    /// Uploads local files to board paths, skipping those whose contents already match.
    func upload(_ items: [(local: URL, remote: String)], force: Bool = false) {
        guard !items.isEmpty else { return }
        let items = items.compactMap { item in (try? Data(contentsOf: item.local)).map { (item.remote, $0) } }
        perform("Uploading") { session in
            let remoteHashes = force ? [:] : try await session.hashes(of: items.map(\.0))
            let changed = items.filter { remoteHashes[$0.0] != $0.1.sha256Hex }
            for (index, (path, data)) in changed.enumerated() {
                await MainActor.run { self.state = .busy("Uploading \(index + 1)/\(changed.count) \(path)") }
                try await session.writeFile(path, contents: data)
            }
            let files = try await session.listFiles()
            await MainActor.run {
                self.files = files
                let skipped = items.count - changed.count
                self.onStatus?(changed.isEmpty ? "Board is up to date"
                               : "Uploaded \(changed.count) file\(changed.count == 1 ? "" : "s")"
                                   + (skipped > 0 ? " (\(skipped) unchanged)" : ""))
            }
        }
    }

    func download(_ path: String) async -> Data? {
        await withCheckedContinuation { continuation in
            perform("Downloading \(path)", onFailure: { continuation.resume(returning: nil) }) { session in
                let data = try await session.readFile(path)
                continuation.resume(returning: data)
            }
        }
    }

    func delete(_ path: String) {
        perform("Deleting \(path)") { session in
            try await session.remove(path)
            let files = try await session.listFiles()
            await MainActor.run { self.files = files }
        }
    }

    func makeFolder(_ path: String) {
        perform("Creating \(path)") { session in
            try await session.makeDirectory(path)
            let files = try await session.listFiles()
            await MainActor.run { self.files = files }
        }
    }

    /// Runs a raw-REPL command, showing it in the status bar while it works.
    private func perform(_ title: String, onFailure: (@Sendable () -> Void)? = nil,
                         _ body: @escaping @Sendable (MicroPythonDevice.RawSession) async throws -> Void) {
        guard let device, isIdle else {
            onStatus?(isConnected ? "The board is busy" : "Connect to a board first")
            onFailure?()
            return
        }
        state = .busy(title)
        Task {
            do {
                try await device.withRawREPL(body)
            } catch {
                onStatus?("\(title) failed: \(TerminalText.cleaned(error.localizedDescription))")
                onFailure?()
            }
            if self.device === device { state = .connected }
        }
    }
}

extension TerminalText {
    static func cleaned(_ text: String) -> String {
        var out = ""
        append(text, to: &out)
        return out
    }
}

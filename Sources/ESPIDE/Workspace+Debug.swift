import AppKit
import ESPIDECore

/// Breakpoints, watches and debug sessions: MicroPython on the board (instrumented run) or
/// ESP-IDF apps on the chip (OpenOCD + GDB).
extension Workspace {
    var isDebugging: Bool { debugSession?.isActive ?? false }

    var currentBreakpoints: Set<Int> { Set((breakpoints[currentDocumentID] ?? [:]).keys) }

    var currentConditionalBreakpoints: Set<Int> {
        Set((breakpoints[currentDocumentID] ?? [:]).filter { $0.value.isConditional }.keys)
    }

    var currentExecutionLine: Int? {
        guard let executionLocation, executionLocation.key == currentDocumentID else { return nil }
        return executionLocation.line
    }

    /// Breakpoints go on Python files in MicroPython projects and on C/C++ files in ESP-IDF ones.
    var canSetBreakpoints: Bool {
        guard let currentFile else { return false }
        return isIDFProject ? CHighlighter.isCSource(currentFile) : Self.isPython(currentFile)
    }

    private static func sourceBreakpoints(_ lines: [Int: BreakpointSpec]) -> [SourceBreakpoint] {
        lines.map { SourceBreakpoint(line: $0.key + 1, spec: $0.value) }
    }

    func updateBreakpoints(_ lines: [Int: BreakpointSpec], for key: String) {
        breakpoints[key] = lines.isEmpty ? nil : lines
        debugSession?.setBreakpoints(path: key, Self.sourceBreakpoints(lines))
        saveBreakpoints()
    }

    /// Breakpoints are kept per project: path → {"1-based line": condition}.
    func saveBreakpoints() {
        let stored = breakpoints.mapValues { lines in
            Dictionary(uniqueKeysWithValues: lines.map { (String($0.key + 1), $0.value.condition) })
        }
        UserDefaults.standard.set(stored.isEmpty ? nil : stored, forKey: defaultsKey("breakpoints"))
    }

    func loadBreakpoints() {
        let stored = UserDefaults.standard.dictionary(forKey: defaultsKey("breakpoints")) as? [String: [String: String]] ?? [:]
        breakpoints = stored.compactMapValues { lines in
            let parsed = Dictionary(uniqueKeysWithValues: lines.compactMap { line, condition in
                Int(line).map { ($0 - 1, BreakpointSpec(condition: condition)) }
            })
            return parsed.isEmpty ? nil : parsed
        }
    }

    func toggleBreakpoint(line: Int) {
        guard canSetBreakpoints else { return }
        let key = currentDocumentID
        var lines = breakpoints[key] ?? [:]
        if lines[line] != nil { lines.removeValue(forKey: line) } else { lines[line] = BreakpointSpec() }
        updateBreakpoints(lines, for: key)
    }

    func toggleBreakpointAtCaret() {
        toggleBreakpoint(line: LineIndex(text).position(of: caretOffset).line)
    }

    func removeBreakpoint(line: Int) {
        var lines = breakpoints[currentDocumentID] ?? [:]
        lines.removeValue(forKey: line)
        updateBreakpoints(lines, for: currentDocumentID)
    }

    func clearAllBreakpoints() {
        for key in breakpoints.keys { debugSession?.setBreakpoints(path: key, []) }
        breakpoints = [:]
        saveBreakpoints()
    }

    /// Asks for an expression; the breakpoint only pauses when it is true.
    func editBreakpointCondition(line: Int) {
        guard canSetBreakpoints else { return }
        let key = currentDocumentID
        let language = isIDFProject ? "C" : "Python"
        guard let value = Self.prompt(
            title: "Breakpoint condition (line \(line + 1))",
            message: "Pause only when this \(language) expression is true. Leave empty to always pause.",
            placeholder: isIDFProject ? "e.g. i == 3" : "e.g. temp > 30", initial: breakpoints[key]?[line]?.condition ?? "")
        else { return }
        var lines = breakpoints[key] ?? [:]
        var spec = lines[line] ?? BreakpointSpec()
        spec.condition = value
        lines[line] = spec
        updateBreakpoints(lines, for: key)
    }

    private static func prompt(title: String, message: String, placeholder: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(string: initial)
        field.placeholderString = placeholder
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Watch expressions

    func addWatch(_ expression: String) {
        let trimmed = expression.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !watchExpressions.contains(trimmed) else { return }
        watchExpressions.append(trimmed)
        debugSession?.setWatches(watchExpressions)
    }

    func removeWatch(_ expression: String) {
        watchExpressions.removeAll { $0 == expression }
        debugSession?.setWatches(watchExpressions)
    }

    // MARK: Sessions

    func startDebugging() async {
        guard rootURL != nil, !isDebugging else { return }
        if isIDFProject {
            await startIDFDebugging()
        } else {
            startMicroPythonDebugging()
        }
    }

    func stopDebugging() {
        debugSession?.stop()
    }

    /// A new session wired to the editor: stops reveal the line, the Debug panel comes up.
    private func makeSession(adapter: DebugAdapter, programName: String) -> DebugSession {
        let session = DebugSession(adapter: adapter, breakpoints: breakpoints.mapValues(Self.sourceBreakpoints),
                                   programName: programName)
        session.onLocation = { [weak self, weak session] location in
            guard let self, self.debugSession === session else { return }
            guard let (path, line) = location else {
                self.executionLocation = nil
                return
            }
            let url = URL(fileURLWithPath: path)
            self.executionLocation = ExecutionLocation(key: Self.key(for: url), line: max(line - 1, 0))
            self.navigate(to: url, position: TextPosition(line: max(line - 1, 0), character: 0))
            self.bottomTab = .debug
        }
        session.onEnd = { [weak self, weak session] in
            guard let self, self.debugSession === session else { return }
            self.executionLocation = nil
        }
        session.setWatches(watchExpressions)
        debugSession = session
        bottomTab = .debug
        return session
    }

    /// Runs the current file (or main.py) on the board with probes that let it pause.
    private func startMicroPythonDebugging() {
        guard let file = runTarget() else {
            flashStatus("Nothing to debug: open a .py file (or add main.py)")
            return
        }
        saveAllNow()
        let key = Self.key(for: file)
        let source = documents.first { $0.id == key }?.text ?? (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        guard let device = board.beginDebugging(name: relativePath(file)) else { return }
        let adapter = MicroPythonDebugAdapter(
            path: key, source: source,
            run: { runtime, program, onOutput in
                try await device.withRawREPL(softReset: true) { session in
                    _ = try await session.exec(runtime, timeout: .seconds(10))
                    _ = try await session.exec(program, timeout: nil, onOutput: onOutput)
                }
            },
            write: { try? device.sendTerminal($0) },
            interrupt: { device.interrupt() })
        let session = makeSession(adapter: adapter, programName: file.lastPathComponent)
        session.sendInput = { adapter.sendInput($0) }
        session.onCleanup = { [weak self] in self?.board.finishDebugging() }
        session.log("Debugging \(relativePath(file)) on \(board.portName). Only this file stops at breakpoints; "
                    + "modules it imports run normally.\n\n")
        session.start { client in
            _ = try await client.request("launch", arguments: [:])
        }
    }

    // MARK: ESP-IDF

    /// Debugs the built app: on the chip through OpenOCD (JTAG), or — `inQEMU` — in Espressif's
    /// emulator, which needs no hardware. GDB attaches to either on :3333, the chip restarts, and the
    /// app runs with the breakpoints in place.
    func startIDFDebugging(inQEMU: Bool = false) async {
        guard let rootURL, !isDebugging else { return }
        guard let setup = idfSetupScript else {
            flashStatus("ESP-IDF not found — ESP-IDF → Choose ESP-IDF…")
            return
        }
        let buildDirectory = Clangd.buildDirectory(project: rootURL, idfOptions: IDFProject.shellWords(idfOptions))
        guard let build = IDFDebug.build(in: buildDirectory), FileManager.default.fileExists(atPath: build.elf.path) else {
            flashStatus(inQEMU ? "Build the app first (⌘B)" : "Build (⌘B) and flash the app first")
            return
        }
        if inQEMU, !IDFDebug.qemuSupports(target: build.target) {
            flashStatus("QEMU emulates the ESP32, ESP32-S3 and ESP32-C3, not the \(build.target.uppercased())")
            return
        }
        saveAllNow()

        let gdb = DAPClient()
        let session = makeSession(adapter: gdb, programName: build.elf.lastPathComponent + (inQEMU ? " (QEMU)" : ""))
        let server = PipedProcess()
        session.onCleanup = { server.terminate() }
        let tool = inQEMU ? "idf.py" : "openocd"
        let arguments = inQEMU ? ["qemu", "--gdb"] : build.openOCDArguments
        session.log("$ \(tool) \(arguments.joined(separator: " "))\n")
        if !inQEMU, IDFDebug.needsExternalAdapter(target: build.target) {
            session.log("(the \(build.target.uppercased()) has no built-in USB-JTAG: this needs an adapter such as ESP-Prog; "
                        + "Debug → Debug App in QEMU needs no hardware)\n")
        }

        // The GDB server first (QEMU's output is the app's serial console); GDB connects once it listens.
        let watcher = ServerWatcher(readyText: inQEMU ? IDFDebug.qemuStarting : IDFDebug.openOCDReady)
        server.onOutput = { [weak session] text in
            watcher.feed(text)
            Task { @MainActor in session?.log(TerminalText.cleaned(text)) }
        }
        server.onExit = { status in watcher.exited(status) }
        do {
            try server.start(arguments: ["/bin/bash"] + IDFProject.toolCommand(
                setupScript: setup, directory: rootURL, tool: tool, arguments: arguments),
                environment: ProcessInfo.processInfo.environment, currentDirectory: rootURL)
        } catch {
            session.log("Failed to start \(tool): \(error.localizedDescription)\n")
            session.stop()
            return
        }
        switch await watcher.wait(timeout: .seconds(inQEMU ? 60 : 20)) {
        case .ready:
            if inQEMU { try? await Task.sleep(for: .seconds(1)) }
        case let .failed(output):
            if inQEMU, output.contains("qemu-system") && output.contains("not found") || output.contains("QEMU is not installed") {
                session.log("\nQEMU isn't installed. In Terminal, after sourcing ESP-IDF:\n  \(IDFDebug.qemuInstallCommand(target: build.target))\n")
            } else if let error = IDFDebug.openOCDError(in: output) {
                session.log("\n" + (IDFDebug.advice(forOpenOCDError: error, target: build.target) ?? error) + "\n")
            }
            session.stop()
            return
        }

        do {
            try gdb.start(executable: URL(fileURLWithPath: "/bin/bash"),
                          arguments: IDFProject.toolCommand(setupScript: setup, directory: rootURL,
                                                            tool: IDFDebug.gdb(target: build.target), arguments: ["-i", "dap"]),
                          environment: ProcessInfo.processInfo.environment, currentDirectory: rootURL)
        } catch {
            session.log("Failed to start GDB: \(error.localizedDescription)\n")
            session.stop()
            return
        }
        session.start { client in
            for command in IDFDebug.setupCommands {
                _ = try? await client.request("evaluate", arguments: ["expression": .string(command), "context": "repl"])
            }
            // GDB answers `attach` after configurationDone (sent when it reports `initialized`).
            _ = try await client.request("attach", arguments: IDFDebug.attachArguments(elf: build.elf))
        } afterConfiguration: { session in
            // GDB reports a stop once attached; then restart the chip and run. QEMU is already halted
            // at reset (and doesn't know `monitor reset halt`).
            guard await session.waitUntilStopped(timeout: .seconds(15)) else { return }
            if !inQEMU {
                for command in IDFDebug.resetCommands {
                    _ = try? await session.adapter.request("evaluate", arguments: ["expression": .string(command), "context": "repl"])
                }
            }
            session.resume()
        }
    }
}

/// Waits for a GDB server (OpenOCD, QEMU) to print that it's ready, or to exit.
final class ServerWatcher: @unchecked Sendable {
    enum Outcome { case ready, failed(String) }

    private let lock = NSLock()
    private let readyText: String
    private var output = ""
    private var outcome: Outcome?

    init(readyText: String) {
        self.readyText = readyText
    }

    func feed(_ text: String) {
        lock.withLock {
            output += text
            if outcome == nil, output.contains(readyText) { outcome = .ready }
        }
    }

    func exited(_ status: Int32) {
        lock.withLock { if outcome == nil { outcome = .failed(output) } }
    }

    func wait(timeout: Duration) async -> Outcome {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let outcome = lock.withLock({ outcome }) { return outcome }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return .failed(lock.withLock { output } + "\nError: the GDB server didn't start within \(timeout)\n")
    }
}

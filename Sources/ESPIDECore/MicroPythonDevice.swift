import Foundation

public enum DeviceError: LocalizedError, Equatable {
    case timeout(String)
    case protocolError(String)
    /// The code raised; carries MicroPython's traceback.
    case exception(String)
    case disconnected

    public var errorDescription: String? {
        switch self {
        case let .timeout(what): "Timed out waiting for \(what)"
        case let .protocolError(message): "Unexpected reply from the board: \(message)"
        case let .exception(traceback): traceback.trimmingCharacters(in: .whitespacesAndNewlines)
        case .disconnected: "The board is disconnected"
        }
    }
}

/// Talks to MicroPython over a transport, mirroring what mpremote does.
///
/// While idle the board is in the normal (friendly) REPL and everything it prints goes to
/// `onTerminalOutput`. Commands (`exec`, `run`, file operations) switch to the raw REPL
/// (Ctrl-A), where each block of code is sent, ended with Ctrl-D, and answered with
/// `OK<stdout>\x04<stderr>\x04>`; they switch back (Ctrl-B) when done.
public final class MicroPythonDevice: @unchecked Sendable {
    public typealias TextHandler = @Sendable (String) -> Void

    private let transport: DeviceTransport
    private let lock = NSLock()
    private var buffer = Data()
    private var capturing = false
    private var closed = false
    private var terminalDecoder = UTF8StreamDecoder()
    private var _onTerminalOutput: TextHandler?
    private var _onDisconnect: (@Sendable () -> Void)?
    private let commands = AsyncLock()

    /// Bytes sent per write while transferring code; the board's UART buffer is small.
    public var chunkSize = 256
    public var chunkDelay: Duration = .milliseconds(10)

    public var onTerminalOutput: TextHandler? {
        get { lock.withLock { _onTerminalOutput } }
        set { lock.withLock { _onTerminalOutput = newValue } }
    }

    public var onDisconnect: (@Sendable () -> Void)? {
        get { lock.withLock { _onDisconnect } }
        set { lock.withLock { _onDisconnect = newValue } }
    }

    public var isClosed: Bool { lock.withLock { closed } }

    public init(transport: DeviceTransport) {
        self.transport = transport
        transport.onData = { [weak self] data in self?.receive(data) }
        transport.onClose = { [weak self] in
            guard let self else { return }
            let handler = self.lock.withLock {
                self.closed = true
                return self._onDisconnect
            }
            handler?()
        }
    }

    public func close() {
        lock.withLock { closed = true }
        transport.close()
    }

    private func receive(_ data: Data) {
        let forward: (TextHandler, String)? = lock.withLock {
            if capturing {
                buffer.append(data)
                return nil
            }
            guard let handler = _onTerminalOutput else { return nil }
            return (handler, terminalDecoder.decode(data))
        }
        if let (handler, text) = forward, !text.isEmpty { handler(text) }
    }

    // MARK: - Friendly REPL

    /// Types text into the normal REPL (the board echoes it).
    public func sendTerminal(_ text: String) throws {
        try transport.write(Data(text.utf8))
    }

    /// Ctrl-C: interrupts the running program (also stops code started by `run`).
    public func interrupt() {
        try? transport.write(Data([0x03]))
    }

    /// Ctrl-D in the normal REPL: soft reset, which runs boot.py and main.py again.
    public func softReset() throws {
        try transport.write(Data([0x03, 0x03, 0x04]))
    }

    /// Sends multi-line code through paste mode (Ctrl-E … Ctrl-D) so indentation survives.
    public func paste(_ code: String) throws {
        var data = Data([0x05])
        data.append(Data(code.replacingOccurrences(of: "\r\n", with: "\n").utf8))
        data.append(0x04)
        try transport.write(data)
    }

    // MARK: - Raw REPL commands

    /// Runs `body` in the raw REPL with exclusive use of the board.
    /// `softReset` gives the code a fresh interpreter (main.py is not re-run).
    public func withRawREPL<T: Sendable>(softReset: Bool = false,
                                         _ body: @Sendable (RawSession) async throws -> T) async throws -> T {
        try await commands.run {
            guard !self.isClosed else { throw DeviceError.disconnected }
            try await self.enterRawREPL(softReset: softReset)
            do {
                let result = try await body(RawSession(device: self))
                try? await self.exitRawREPL()
                return result
            } catch {
                try? await self.exitRawREPL()
                throw error
            }
        }
    }

    /// Executes code and returns what it printed; throws `DeviceError.exception` with the traceback.
    public func exec(_ code: String, timeout: Duration = .seconds(10)) async throws -> String {
        try await withRawREPL { try await $0.exec(code, timeout: timeout) }
    }

    private func enterRawREPL(softReset: Bool) async throws {
        lock.withLock {
            capturing = true
            buffer.removeAll()
        }
        // Ctrl-C twice stops a running main.py; then give the board a moment to print the traceback.
        try transport.write(Data([0x0D, 0x03]))
        try await Task.sleep(for: .milliseconds(100))
        try transport.write(Data([0x03]))
        try await Task.sleep(for: .milliseconds(100))
        lock.withLock { buffer.removeAll() }
        try transport.write(Data([0x0D, 0x01]))
        let banner = Data("raw REPL; CTRL-B to exit\r\n>".utf8)
        _ = try await readUntil(banner, timeout: .seconds(3), what: "the raw REPL")
        if softReset {
            try transport.write(Data([0x04]))
            _ = try await readUntil(Data("soft reboot\r\n".utf8), timeout: .seconds(5), what: "soft reboot")
            _ = try await readUntil(banner, timeout: .seconds(5), what: "the raw REPL after reboot")
        }
    }

    private func exitRawREPL() async throws {
        defer {
            let leftover: (TextHandler, String)? = lock.withLock {
                capturing = false
                let text = terminalDecoder.decode(buffer)
                buffer.removeAll()
                return _onTerminalOutput.map { ($0, text) }
            }
            if let (handler, text) = leftover, !text.isEmpty { handler(text) }
        }
        guard !isClosed else { return }
        try transport.write(Data([0x0D, 0x02]))
        // Ctrl-B prints the banner of the normal REPL; let it arrive so it isn't mixed into the next command.
        try? await Task.sleep(for: .milliseconds(50))
    }

    /// Sends one block of code; streams its stdout to `onOutput` and returns it all.
    fileprivate func execRaw(_ code: String, timeout: Duration?, onOutput: TextHandler?) async throws -> String {
        let bytes = Data(code.utf8)
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + chunkSize, bytes.count)
            try transport.write(bytes.subdata(in: offset..<end))
            offset = end
            if offset < bytes.count { try await Task.sleep(for: chunkDelay) }
        }
        try transport.write(Data([0x04]))
        let ok = try await readUntil(Data("OK".utf8), timeout: .seconds(3), what: "the board to accept the code")
        guard ok.isEmpty else {
            throw DeviceError.protocolError(String(decoding: ok, as: UTF8.self))
        }
        var decoder = UTF8StreamDecoder()
        let stdout = try await readUntil(Data([0x04]), timeout: timeout, what: "the code to finish") { chunk in
            let text = decoder.decode(chunk)
            if !text.isEmpty { onOutput?(text) }
        }
        let stderr = try await readUntil(Data([0x04, 0x3E]), timeout: .seconds(5), what: "the error output")
        if !stderr.isEmpty { throw DeviceError.exception(String(decoding: stderr, as: UTF8.self)) }
        return String(decoding: stdout, as: UTF8.self)
    }

    /// Waits until `marker` arrives, returning (and consuming) the bytes before it.
    /// `progress` receives bytes as they come in, holding back any that may start the marker.
    private func readUntil(_ marker: Data, timeout: Duration?, what: String,
                           progress: ((Data) -> Void)? = nil) async throws -> Data {
        let clock = ContinuousClock()
        let deadline = timeout.map { clock.now + $0 }
        var delivered = 0
        while true {
            let (found, pending, isClosed): (Data?, Data, Bool) = lock.withLock {
                if let range = buffer.range(of: marker) {
                    let before = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                    buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                    return (before, Data(), closed)
                }
                let safe = max(delivered, buffer.count - (marker.count - 1))
                let pending = safe > delivered ? buffer.subdata(in: (buffer.startIndex + delivered)..<(buffer.startIndex + safe)) : Data()
                return (nil, pending, closed)
            }
            if let found {
                if delivered < found.count { progress?(found.subdata(in: (found.startIndex + delivered)..<found.endIndex)) }
                return found
            }
            if !pending.isEmpty {
                progress?(pending)
                delivered += pending.count
            }
            if isClosed { throw DeviceError.disconnected }
            if let deadline, clock.now > deadline { throw DeviceError.timeout(what) }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// A handle for running several commands inside one raw-REPL session.
    public struct RawSession: Sendable {
        fileprivate let device: MicroPythonDevice

        public func exec(_ code: String, timeout: Duration? = .seconds(10),
                         onOutput: TextHandler? = nil) async throws -> String {
            try await device.execRaw(code, timeout: timeout, onOutput: onOutput)
        }
    }
}

/// Serializes async work (one command on the wire at a time).
actor AsyncLock {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        }
        busy = true
        defer {
            if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
        }
        return try await body()
    }
}

/// Decodes UTF-8 that arrives in arbitrary chunks, keeping a split multi-byte character for the next chunk.
public struct UTF8StreamDecoder: Sendable {
    private var pending = Data()

    public init() {}

    public mutating func decode(_ data: Data) -> String {
        var bytes = pending + data
        pending = Data()
        // Find where an incomplete trailing sequence starts (at most 3 bytes back).
        var cut = bytes.count
        var i = bytes.count - 1
        while i >= 0 && i >= bytes.count - 4 {
            let byte = bytes[bytes.startIndex + i]
            if byte & 0xC0 == 0x80 { i -= 1; continue }  // continuation byte
            let length = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
            if i + length > bytes.count { cut = i }
            break
        }
        if cut < bytes.count {
            pending = bytes.subdata(in: (bytes.startIndex + cut)..<bytes.endIndex)
            bytes = bytes.subdata(in: bytes.startIndex..<(bytes.startIndex + cut))
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

import Foundation
import Testing
@testable import ESPIDECore

/// Pretends to be MicroPython's raw REPL: answers each block of code with `respond(code)`.
final class FakeBoard: DeviceTransport, @unchecked Sendable {
    var onData: (@Sendable (Data) -> Void)?
    var onClose: (@Sendable () -> Void)?
    private let lock = NSLock()
    private var raw = false
    private var code = Data()
    private(set) var executed: [String] = []
    let respond: @Sendable (String) -> (stdout: String, stderr: String)

    init(respond: @escaping @Sendable (String) -> (stdout: String, stderr: String) = { _ in ("", "") }) {
        self.respond = respond
    }

    func write(_ data: Data) throws {
        for byte in data { handle(byte) }
    }

    private func handle(_ byte: UInt8) {
        var reply: Data?
        lock.withLock {
            switch (raw, byte) {
            case (false, 0x01):
                raw = true
                reply = Data("raw REPL; CTRL-B to exit\r\n>".utf8)
            case (true, 0x02):
                raw = false
                reply = Data("\r\nMicroPython v1.29.0\r\n>>> ".utf8)
            case (true, 0x04) where code.isEmpty:
                reply = Data("soft reboot\r\nraw REPL; CTRL-B to exit\r\n>".utf8)
            case (true, 0x04):
                let source = String(decoding: code, as: UTF8.self)
                executed.append(source)
                code.removeAll()
                let (out, err) = respond(source)
                reply = Data("OK\(out)\u{04}\(err)\u{04}>".utf8)
            case (true, 0x03), (true, 0x0D) where code.isEmpty, (false, _):
                break
            case (true, _):
                code.append(byte)
            }
        }
        if let reply { onData?(reply) }
    }

    func close() { onClose?() }

    var executedCode: [String] { lock.withLock { executed } }
}

@Suite struct DeviceTests {
    func device(_ board: FakeBoard) -> MicroPythonDevice {
        let device = MicroPythonDevice(transport: board)
        device.chunkDelay = .zero
        return device
    }

    @Test func execReturnsStdout() async throws {
        let board = FakeBoard { code in (code == "print(1+1)" ? "2\r\n" : "", "") }
        let output = try await device(board).exec("print(1+1)")
        #expect(output == "2\r\n")
    }

    @Test func execThrowsTraceback() async throws {
        let board = FakeBoard { _ in ("", "Traceback (most recent call last):\r\nNameError: x\r\n") }
        await #expect(throws: DeviceError.exception("Traceback (most recent call last):\r\nNameError: x\r\n")) {
            _ = try await device(board).exec("x")
        }
    }

    @Test func streamsOutputAndSplitsUTF8() async throws {
        let board = FakeBoard { _ in ("温度 23.5\r\n", "") }
        let collected = Collector()
        let output = try await device(board).withRawREPL(softReset: true) { session in
            try await session.exec("run", onOutput: { collected.append($0) })
        }
        #expect(output == "温度 23.5\r\n")
        #expect(collected.text == output)
    }

    @Test func terminalOutputResumesAfterCommand() async throws {
        let board = FakeBoard { _ in ("x", "") }
        let device = device(board)
        let collected = Collector()
        device.onTerminalOutput = { collected.append($0) }
        _ = try await device.exec("print('x')")
        try await Task.sleep(for: .milliseconds(20))
        #expect(collected.text.contains(">>> "))
        #expect(!collected.text.contains("raw REPL"))
    }

    @Test func writeFileSendsChunksAndMakesFolders() async throws {
        let board = FakeBoard()
        let contents = Data(repeating: 0x41, count: 2500)
        try await device(board).withRawREPL { try await $0.writeFile("/lib/a.py", contents: contents) }
        let code = board.executedCode
        #expect(code.first?.contains("'/lib'") == true)
        #expect(code.filter { $0.hasPrefix("_f.write(") }.count == 3)
        #expect(code.contains("_f = open('/lib/a.py', 'wb')"))
    }

    @Test func readFileDecodesHex() async throws {
        let board = FakeBoard { _ in ("68656c6c6f\r\n0a\r\n", "") }
        let data = try await device(board).withRawREPL { try await $0.readFile("/main.py") }
        #expect(String(decoding: data, as: UTF8.self) == "hello\n")
    }

    @Test func parsesListingIntoTree() {
        let tree = DeviceFiles.parseListing("F 120 /main.py\r\nD 0 /lib\r\nF 30 /lib/ssd1306.py\r\nF 5 /boot.py\r\n")
        #expect(tree.map(\.name) == ["lib", "boot.py", "main.py"])
        #expect(tree[0].children?.map(\.path) == ["/lib/ssd1306.py"])
        #expect(tree[2].size == 120)
    }

    @Test func bytesLiteralEscapes() {
        #expect(DeviceFiles.bytesLiteral(Data("a'b\\\n\u{1}é".utf8)) == #"b'a\'b\\\n\x01\xc3\xa9'"#)
        #expect(DeviceFiles.literal("it's") == #"'it\'s'"#)
    }

    @Test func utf8DecoderKeepsSplitCharacters() {
        var decoder = UTF8StreamDecoder()
        let bytes = Data("温".utf8)
        #expect(decoder.decode(bytes.prefix(2)) == "")
        #expect(decoder.decode(bytes.suffix(1)) == "温")
        #expect(decoder.decode(Data("ok".utf8)) == "ok")
    }

    @Test func recognizesBoardPorts() {
        #expect(SerialPort.isLikelyBoard("cu.usbserial-110"))
        #expect(SerialPort.isLikelyBoard("cu.usbmodem14101"))
        #expect(!SerialPort.isLikelyBoard("cu.Bluetooth-Incoming-Port"))
    }
}

/// Runs against a real board when ESPIDE_TEST_PORT is set, e.g. ESPIDE_TEST_PORT=/dev/cu.usbserial-110.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ESPIDE_TEST_PORT"] != nil))
struct RealBoardTests {
    @Test func roundTrip() async throws {
        let port = try SerialPort(path: ProcessInfo.processInfo.environment["ESPIDE_TEST_PORT"]!)
        let device = MicroPythonDevice(transport: port)
        defer { device.close() }
        let contents = Data("# ESPIDE test 温度\nprint('hi')\n".utf8)
        let (sum, read, listed, hashes) = try await device.withRawREPL { session in
            let sum = try await session.exec("print(6*7)")
            try await session.writeFile("/espide_test/t.py", contents: contents)
            let read = try await session.readFile("/espide_test/t.py")
            let listed = try await session.listFiles()
            let hashes = try await session.hashes(of: ["/espide_test/t.py", "/nope.py"])
            try await session.remove("/espide_test")
            return (sum, read, listed, hashes)
        }
        #expect(sum == "42\r\n")
        let machine = try await device.exec("import sys\nprint(sys.implementation._machine)")
        #expect(PinScanner.Chip(machine: machine) == .esp32, "\(machine)")
        #expect(read == contents)
        #expect(listed.contains { $0.path == "/espide_test" })
        #expect(hashes["/espide_test/t.py"] == contents.sha256Hex)
        #expect(hashes["/nope.py"] == nil)
    }

    /// Installs ssd1306 from micropython-lib into a scratch folder, checks it, removes it (needs internet).
    @Test func installsLibrary() async throws {
        let files = try await Mip.resolve("ssd1306", target: "/espide_mip", fetch: Mip.fetch)
        #expect(files.map(\.path) == ["/espide_mip/ssd1306.py"])
        let data = try await files[0].download(fetch: Mip.fetch)
        let port = try SerialPort(path: ProcessInfo.processInfo.environment["ESPIDE_TEST_PORT"]!)
        let device = MicroPythonDevice(transport: port)
        defer { device.close() }
        let hashes = try await device.withRawREPL { session in
            try await session.writeFile(files[0].path, contents: data)
            let hashes = try await session.hashes(of: [files[0].path])
            try await session.remove("/espide_mip")
            return hashes
        }
        #expect(hashes[files[0].path] == data.sha256Hex)
    }

    /// Typing a line into the friendly REPL: the echo and output come back intact.
    @Test func terminalLineRoundTrip() async throws {
        let port = try SerialPort(path: ProcessInfo.processInfo.environment["ESPIDE_TEST_PORT"]!)
        let device = MicroPythonDevice(transport: port)
        defer { device.close() }
        let collected = Collector()
        device.onTerminalOutput = { collected.append($0) }
        device.interrupt()
        try await Task.sleep(for: .milliseconds(300))
        try device.sendTerminal("for i in range(3): print((i+1)*7)\r")
        try await Task.sleep(for: .milliseconds(200))
        try device.sendTerminal("\r")
        try await Task.sleep(for: .milliseconds(500))
        var text = ""
        TerminalText.append(collected.text, to: &text)
        #expect(text.contains("for i in range(3): print((i+1)*7)"), "\(text)")
        #expect(text.contains("7\n14\n21"), "\(text)")
    }

    /// The app's sequence: list files over the raw REPL, Ctrl-C, then type lines into the friendly REPL.
    @Test func terminalAfterRawREPL() async throws {
        let port = try SerialPort(path: ProcessInfo.processInfo.environment["ESPIDE_TEST_PORT"]!)
        let device = MicroPythonDevice(transport: port)
        defer { device.close() }
        let collected = Collector()
        device.onTerminalOutput = { collected.append($0) }
        _ = try await device.withRawREPL { try await $0.listFiles() }
        device.interrupt()
        try await Task.sleep(for: .milliseconds(300))
        for n in 1...5 {
            try device.sendTerminal("print(\"line\", (\(n)+1)*(2))\r")
            try await Task.sleep(for: .milliseconds(300))
        }
        var text = ""
        TerminalText.append(collected.text, to: &text)
        for n in 1...5 {
            #expect(text.contains("print(\"line\", (\(n)+1)*(2))"), "\(text)")
        }
    }

    /// The board describes its secrets.py by name and type; the output must not contain the values.
    @Test func describesBoardOnlyModuleWithoutValues() async throws {
        let port = try SerialPort(path: ProcessInfo.processInfo.environment["ESPIDE_TEST_PORT"]!)
        let device = MicroPythonDevice(transport: port)
        defer { device.close() }
        let output = try await device.exec(BoardModules.describeScript("secrets"))
        #expect(output.contains("WIFI_SSID str"))
        #expect(output.contains("WIFI_PASSWORD str"))
        #expect(output.split(whereSeparator: \.isNewline).allSatisfy { $0.split(separator: " ").count == 2 })
    }

    /// The LCD1602 backpack on the test board is wired to SDA=21, SCL=22.
    @Test func scansI2C() async throws {
        let port = try SerialPort(path: ProcessInfo.processInfo.environment["ESPIDE_TEST_PORT"]!)
        let device = MicroPythonDevice(transport: port)
        defer { device.close() }
        let output = try await device.exec(I2C.scanScript(sda: 21, scl: 22))
        #expect(I2C.parseScan(output)?.contains(0x27) == true)
    }
}

final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var parts: [String] = []
    func append(_ s: String) { lock.withLock { parts.append(s) } }
    var text: String { lock.withLock { parts.joined() } }
}

@Suite struct TerminalTextTests {
    @Test func cleansREPLOutput() {
        var text = ">>> "
        TerminalText.append("prinx\u{08}t(1)\r\n1\r\n\u{1B}[K>>> ", to: &text)
        #expect(text == ">>> print(1)\n1\n>>> ")
    }
}

import Foundation
import Testing
@testable import ESPIDECore

@Suite struct InstrumenterTests {
    let sample = """
    import time
    from machine import Pin

    def add(a, b=1, *rest, **kw):
        \"\"\"Adds.
        # not a comment
        \"\"\"
        s = a + b  # sum
        if s > 3:
            return s
        for i, (j, k) in enumerate([(1, 2)]):
            s += i
        data = {
            'x': 1,
        }
        global counter
        counter = 1
        return s

    @micropython.native
    def fast(x):
        return x * 2

    class Thing:
        size = 3
        def grow(self):
            self.size += 1

    total = 0
    if total == 0: total = 1
    else:
        total = 2
    """

    @Test func probesSimpleStatementsOnTheirOwnLines() {
        let result = PythonInstrumenter.instrument(sample)
        let lines = result.code.components(separatedBy: "\n")
        #expect(lines.count == sample.components(separatedBy: "\n").count)
        #expect(lines[0] == "_K(1)and _P(1);import time")
        #expect(lines[7].hasPrefix("    _K(8)and _P(8,lambda:a,lambda:b,lambda:data,lambda:i,lambda:j,lambda:k,lambda:kw,lambda:rest,lambda:s);s = a + b"))
        #expect(result.localNames["add"] == ["a", "b", "data", "i", "j", "k", "kw", "rest", "s"])
        // Headers, docstring continuation, dict continuation lines, `global`, native code: untouched.
        for line in [4, 5, 6, 7, 9, 11, 14, 15, 16, 20, 21, 22, 24, 26, 30, 31] {
            #expect(!result.probeLines.contains(line), "line \(line)")
        }
        #expect(result.probeLines.contains(13))  // data = { … starts here
        #expect(result.probeLines.contains(25))  // class body
        #expect(result.probeLines.contains(27))  // method body
        #expect(result.functionOf[27] == "Thing.grow")
        #expect(result.functionOf[25] == nil)
        #expect(result.exitLines.isSuperset(of: [10, 18, 27]))
        #expect(result.probeLine(atOrAfter: 4) == 8)  // a breakpoint on `def` stops at the first statement
    }

    @Test func splitsAssignments() {
        #expect(PythonInstrumenter.splitAssignments("a = b = f(x=1)").count == 3)
        #expect(PythonInstrumenter.splitAssignments("n += 1") == ["n ", " 1"])
        #expect(PythonInstrumenter.splitAssignments("x >>= 2") == ["x ", " 2"])
        #expect(PythonInstrumenter.splitAssignments("if a == b").count == 1)
        #expect(PythonInstrumenter.splitAssignments("f = lambda x=1: x").count == 2)
    }

    @Test func instrumentedCodeCompiles() throws {
        let result = PythonInstrumenter.instrument(sample.replacingOccurrences(of: "@micropython.native\n", with: ""))
        let output = try runPython("import sys\ncompile(sys.stdin.read(), 'main.py', 'exec')\nprint('ok')", stdin: result.code)
        #expect(output == "ok\n")
    }
}

/// Runs the MicroPython debugger's board half under CPython, driven through the adapter.
@Suite struct MicroPythonDebugAdapterTests {
    let program = """
    def add(a, b):
        s = a + b
        return s

    total = 0
    for i in range(3):
        total = add(total, i)
    print("done", total)
    """

    @Test func breakpointsConditionsStepsAndEvaluation() async throws {
        let python = PythonProcess()
        let adapter = MicroPythonDebugAdapter(
            path: "/p/main.py", source: program,
            run: { runtime, program, onOutput in try await python.run(runtime: runtime, program: program, onOutput: onOutput) },
            write: { python.write($0) }, interrupt: { python.kill() })
        let events = EventLog()
        adapter.onEvent = { event, body in events.add(event, body) }

        _ = try await adapter.request("initialize", arguments: [:])
        let set = try await adapter.request("setBreakpoints", arguments: [
            "source": ["path": "/p/main.py"], "breakpoints": [["line": 1, "condition": "a == 1"]],
        ])
        #expect(set["breakpoints"]?[0]?["line"]?.intValue == 2)
        _ = try await adapter.request("configurationDone", arguments: .null)

        try await events.wait(for: "stopped", count: 1)
        var frames = try await adapter.request("stackTrace", arguments: [:])
        #expect(frames["stackFrames"]?[0]?["line"]?.intValue == 2)
        #expect(frames["stackFrames"]?[0]?["name"]?.stringValue == "add")
        let locals = try await adapter.request("variables", arguments: ["variablesReference": 1])
        let names = (locals["variables"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
        #expect(names == ["a", "b"])  // s isn't assigned yet
        #expect(locals["variables"]?[0]?["value"]?.stringValue == "1")
        let value = try await adapter.request("evaluate", arguments: ["expression": "a * 10 + b"])
        #expect(value["result"]?.stringValue == "12")
        await #expect(throws: (any Error).self) { _ = try await adapter.request("evaluate", arguments: ["expression": "nope"]) }

        _ = try await adapter.request("next", arguments: [:])  // to `return s`
        try await events.wait(for: "stopped", count: 2)
        frames = try await adapter.request("stackTrace", arguments: [:])
        #expect(frames["stackFrames"]?[0]?["line"]?.intValue == 3)

        _ = try await adapter.request("next", arguments: [:])  // returns: back in the caller
        try await events.wait(for: "stopped", count: 3)
        frames = try await adapter.request("stackTrace", arguments: [:])
        #expect(frames["stackFrames"]?[0]?["line"]?.intValue == 8)
        #expect(frames["stackFrames"]?[0]?["name"]?.stringValue == "<module>")
        let globals = try await adapter.request("variables", arguments: ["variablesReference": 2])
        #expect((globals["variables"]?.arrayValue ?? []).contains { $0["name"]?.stringValue == "total" && $0["value"]?.stringValue == "3" })

        _ = try await adapter.request("continue", arguments: [:])
        try await events.wait(for: "terminated", count: 1)
        #expect(events.output.contains("done 3"))
        #expect(!events.output.contains("\u{1E}"))
    }

    @Test func stepIntoAndOut() async throws {
        let python = PythonProcess()
        let adapter = MicroPythonDebugAdapter(
            path: "/p/main.py", source: program,
            run: { runtime, program, onOutput in try await python.run(runtime: runtime, program: program, onOutput: onOutput) },
            write: { python.write($0) }, interrupt: { python.kill() })
        let events = EventLog()
        adapter.onEvent = { event, body in events.add(event, body) }
        _ = try await adapter.request("initialize", arguments: [:])
        _ = try await adapter.request("setBreakpoints", arguments: ["source": ["path": "/p/main.py"], "breakpoints": [["line": 7]]])
        _ = try await adapter.request("configurationDone", arguments: .null)
        try await events.wait(for: "stopped", count: 1)
        _ = try await adapter.request("setBreakpoints", arguments: ["source": ["path": "/p/main.py"], "breakpoints": []])
        _ = try await adapter.request("stepIn", arguments: [:])
        try await events.wait(for: "stopped", count: 2)
        var frames = try await adapter.request("stackTrace", arguments: [:])
        #expect(frames["stackFrames"]?[0]?["line"]?.intValue == 2)
        _ = try await adapter.request("stepOut", arguments: [:])
        try await events.wait(for: "stopped", count: 3)
        frames = try await adapter.request("stackTrace", arguments: [:])
        #expect(frames["stackFrames"]?[0]?["line"]?.intValue == 7)  // the loop's next iteration, in the caller
        _ = try await adapter.request("continue", arguments: [:])
        try await events.wait(for: "terminated", count: 1)
        #expect(events.output.contains("done 3"))
    }

    @Test func hidesSecretLookingValues() async throws {
        let python = PythonProcess()
        let adapter = MicroPythonDebugAdapter(
            path: "/p/main.py", source: "WIFI_SSID = 'home'\nWIFI_PASSWORD = 'hunter2'\napi_key = 'k'\nx = 1\n",
            run: { runtime, program, onOutput in try await python.run(runtime: runtime, program: program, onOutput: onOutput) },
            write: { python.write($0) }, interrupt: { python.kill() })
        let events = EventLog()
        adapter.onEvent = { events.add($0, $1) }
        let log = Collector()
        _ = try await adapter.request("initialize", arguments: [:])
        _ = try await adapter.request("setBreakpoints", arguments: ["source": ["path": "/p/main.py"], "breakpoints": [["line": 4]]])
        _ = try await adapter.request("configurationDone", arguments: .null)
        try await events.wait(for: "stopped", count: 1)
        let globals = try await adapter.request("variables", arguments: ["variablesReference": 2])
        let values = Dictionary(uniqueKeysWithValues: (globals["variables"]?.arrayValue ?? []).compactMap { item in
            item["name"]?.stringValue.map { ($0, item["value"]?.stringValue ?? "") }
        })
        log.append("\(values)")
        #expect(values["WIFI_SSID"] == "'home'")
        #expect(values["WIFI_PASSWORD"] == "'***'")
        #expect(values["api_key"] == "'***'")
        _ = try await adapter.request("continue", arguments: [:])
        try await events.wait(for: "terminated", count: 1)
    }

    @Test func reportsTracebackWithFileName() async throws {
        let python = PythonProcess()
        let adapter = MicroPythonDebugAdapter(
            path: "/p/main.py", source: "x = 1\ny = x / 0\n",
            run: { runtime, program, onOutput in try await python.run(runtime: runtime, program: program, onOutput: onOutput) },
            write: { python.write($0) }, interrupt: { python.kill() })
        let events = EventLog()
        adapter.onEvent = { event, body in events.add(event, body) }
        _ = try await adapter.request("initialize", arguments: [:])
        _ = try await adapter.request("configurationDone", arguments: .null)
        try await events.wait(for: "terminated", count: 1)
        #expect(events.output.contains("main.py\", line 2"))
        #expect(events.output.contains("ZeroDivisionError"))
    }
}

/// Runs the runtime and program in one CPython namespace, like one raw-REPL session on the board.
final class PythonProcess: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()

    func run(runtime: String, program: String, onOutput: @escaping @Sendable (String) -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("espide-debug-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try runtime.write(to: folder.appendingPathComponent("runtime.py"), atomically: true, encoding: .utf8)
        try program.write(to: folder.appendingPathComponent("program.py"), atomically: true, encoding: .utf8)
        let driver = """
        import sys
        g = {'__name__': '__main__'}
        exec(open(sys.argv[1]).read(), g)
        try:
            exec(compile(open(sys.argv[2]).read(), '<stdin>', 'exec'), g)
        except BaseException:
            import traceback
            sys.stdout.flush()
            sys.stderr.write(traceback.format_exc())
            sys.exit(1)
        """
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-u", "-c", driver,
                             folder.appendingPathComponent("runtime.py").path, folder.appendingPathComponent("program.py").path]
        let output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { onOutput(String(decoding: data, as: UTF8.self)) }
        }
        try process.run()
        while process.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(50))
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if process.terminationStatus != 0 { throw DeviceError.exception(stderr) }
    }

    func write(_ text: String) { try? input.fileHandleForWriting.write(contentsOf: Data(text.utf8)) }
    func kill() { process.terminate() }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [(String, JSONValue)] = []

    func add(_ event: String, _ body: JSONValue) { lock.withLock { events.append((event, body)) } }

    var output: String {
        lock.withLock { events.filter { $0.0 == "output" }.compactMap { $0.1["output"]?.stringValue }.joined() }
    }

    func last(_ event: String) -> JSONValue? {
        lock.withLock { events.last { $0.0 == event }?.1 }
    }

    func wait(for event: String, count: Int, where matches: (JSONValue) -> Bool = { _ in true }) async throws {
        for _ in 0..<3000 {
            if lock.withLock({ events.filter { $0.0 == event && matches($0.1) }.count }) >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting for \(event) #\(count); output: \(output)")
        throw CancellationError()
    }
}

func runPython(_ script: String, stdin: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", "-c", script]
    let input = Pipe(), output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = output
    try process.run()
    try input.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
    try input.fileHandleForWriting.close()
    process.waitUntilExit()
    return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
}

/// ESPIDE_INSTRUMENT_DIR=/path/to/project: every .py there must still compile once instrumented.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ESPIDE_INSTRUMENT_DIR"] != nil))
struct InstrumentRealProjectTests {
    @Test func projectStillCompiles() throws {
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ESPIDE_INSTRUMENT_DIR"]!)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "py" }
        #expect(!files.isEmpty)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let result = PythonInstrumenter.instrument(source)
            let output = try runPython("import sys\ncompile(sys.stdin.read(), 'x.py', 'exec')\nprint('ok')", stdin: result.code)
            #expect(output == "ok\n", "\(file.lastPathComponent): \(output)")
            print("\(file.lastPathComponent): \(source.utf8.count) → \(result.code.utf8.count) bytes, \(result.probeLines.count) probes")
        }
    }
}

@Suite struct IDFDebugTests {
    @Test func readsBuildDescription() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("espide-build-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"app_elf": "hello.elf", "target": "esp32s3", "debug_arguments_openocd": "-f board/esp32s3-builtin.cfg"}"#.utf8)
            .write(to: folder.appendingPathComponent("project_description.json"))
        let build = try #require(IDFDebug.build(in: folder))
        #expect(build.elf.lastPathComponent == "hello.elf")
        #expect(build.openOCDArguments == ["-f", "board/esp32s3-builtin.cfg"])
        #expect(IDFDebug.gdb(target: "esp32s3") == "xtensa-esp32s3-elf-gdb")
        #expect(IDFDebug.gdb(target: "esp32c6") == "riscv32-esp-elf-gdb")
        #expect(IDFDebug.defaultOpenOCDArguments(target: "esp32c3") == ["-f", "board/esp32c3-builtin.cfg"])
    }

    @Test func explainsOpenOCDErrors() {
        let output = "Open On-Chip Debugger v0.12.0\nError: libusb_open() failed with LIBUSB_ERROR_ACCESS\nError: no device found\n"
        let error = IDFDebug.openOCDError(in: output)
        #expect(error == "Error: libusb_open() failed with LIBUSB_ERROR_ACCESS")
        #expect(IDFDebug.advice(forOpenOCDError: error!, target: "esp32")?.contains("ESP-Prog") == true)
        #expect(IDFDebug.advice(forOpenOCDError: error!, target: "esp32s3")?.contains("USB port") == true)
    }
}

/// GDB's DAP server against QEMU's GDB stub (no JTAG hardware needed), in the order the Debug panel
/// uses. Needs a built ESP32 project and QEMU (`idf_tools.py install qemu-xtensa`):
/// ESPIDE_IDF_SETUP=…/idf-env.sh ESPIDE_QEMU_PROJECT=…/hello_world (unmodified hello_world_main.c).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ESPIDE_QEMU_PROJECT"] != nil))
struct GDBOverQEMUTests {
    @Test func stopsAtBreakpointAndReadsLocals() async throws {
        let env = ProcessInfo.processInfo.environment
        let setup = URL(fileURLWithPath: env["ESPIDE_IDF_SETUP"]!)
        let project = URL(fileURLWithPath: env["ESPIDE_QEMU_PROJECT"]!)
        let build = try #require(IDFDebug.build(in: project.appendingPathComponent("build")))

        let qemu = PipedProcess()
        let qemuLog = Collector()
        qemu.onOutput = { qemuLog.append($0) }
        try qemu.start(arguments: ["/bin/bash"] + IDFProject.toolCommand(setupScript: setup, directory: project, tool: "idf.py",
                                                                         arguments: ["qemu", "--gdb"]),
                       environment: env, currentDirectory: project)
        defer { qemu.terminate() }
        for _ in 0..<600 where !qemuLog.text.contains(IDFDebug.qemuStarting) { try await Task.sleep(for: .milliseconds(100)) }
        try await Task.sleep(for: .seconds(1))

        let gdb = DAPClient()
        let events = EventLog()
        gdb.onEvent = { events.add($0, $1) }
        try gdb.start(executable: URL(fileURLWithPath: "/bin/bash"),
                      arguments: IDFProject.toolCommand(setupScript: setup, directory: project,
                                                        tool: IDFDebug.gdb(target: build.target), arguments: ["-i", "dap"]),
                      environment: env, currentDirectory: project)
        defer { gdb.terminate() }

        _ = try await gdb.request("initialize", arguments: ["adapterID": "espide", "linesStartAt1": true, "pathFormat": "path"])
        let attach = Task { try await gdb.request("attach", arguments: IDFDebug.attachArguments(elf: build.elf)) }
        try await events.wait(for: "initialized", count: 1)
        let source = project.appendingPathComponent("main/hello_world_main.c").path
        _ = try await gdb.request("setBreakpoints", arguments: [
            "source": ["path": .string(source)], "breakpoints": [["line": 46, "condition": "i == 8"]],
        ])
        _ = try await gdb.request("configurationDone")
        _ = try await attach.value
        _ = try await gdb.request("continue", arguments: ["threadId": 1])

        try await events.wait(for: "stopped", count: 1, where: { $0["reason"]?.stringValue == "breakpoint" })
        let thread = try #require(events.last("stopped")?["threadId"]?.intValue)
        let stack = try await gdb.request("stackTrace", arguments: ["threadId": .int(thread)])
        let top = try #require(stack["stackFrames"]?[0])
        #expect(top["line"]?.intValue == 46, "\(stack)")
        #expect(top["name"]?.stringValue == "app_main")
        let frame = try #require(top["id"]?.intValue)
        let scopes = try await gdb.request("scopes", arguments: ["frameId": .int(frame)])
        let locals = try #require(scopes["scopes"]?.arrayValue?.first { $0["name"]?.stringValue == "Locals" }?["variablesReference"]?.intValue)
        let variables = try await gdb.request("variables", arguments: ["variablesReference": .int(locals)])
        #expect((variables["variables"]?.arrayValue ?? []).contains { $0["name"]?.stringValue == "i" && $0["value"]?.stringValue == "8" },
                "\(variables)")
        let value = try await gdb.request("evaluate", arguments: ["expression": "i * 2", "frameId": .int(frame), "context": "watch"])
        #expect(value["result"]?.stringValue == "16")
        // The app's printf output arrives through QEMU's serial console.
        #expect(qemuLog.text.contains("Hello world!"))
        _ = try? await gdb.request("disconnect", arguments: ["terminateDebuggee": false])
    }
}

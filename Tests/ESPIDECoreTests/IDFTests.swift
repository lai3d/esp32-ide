import Foundation
import Testing
@testable import ESPIDECore

@Suite struct IDFProjectTests {
    @Test func splitsShellWords() {
        #expect(IDFProject.shellWords(#"-B build-x -DSDKCONFIG_DEFAULTS="a;b c" build"#)
                == ["-B", "build-x", "-DSDKCONFIG_DEFAULTS=a;b c", "build"])
        #expect(IDFProject.shellWords(#"  'it''s' a\ b "" "#) == ["its", "a b", ""])
        #expect(IDFProject.shellWords("") == [])
    }

    @Test func parsesCompilerDiagnostics() {
        let project = URL(fileURLWithPath: "/p")
        let output = """
        [5/10] Building C object esp-idf/main/CMakeFiles/__idf_main.dir/main.c.obj
        /p/main/main.c:12:5: error: 'x' undeclared (first use in this function)
        /p/main/main.c:12:5: note: each undeclared identifier is reported only once
        main/util.c:3:1: warning: unused variable 'y' [-Wunused-variable]
        /p/main/main.c:12:5: error: 'x' undeclared (first use in this function)
        ninja: build stopped: subcommand failed.
        """
        let diagnostics = IDFProject.diagnostics(inBuildOutput: output, project: project)
        #expect(diagnostics["/p/main/main.c"]?.count == 1)
        #expect(diagnostics["/p/main/main.c"]?.first?.start == TextPosition(line: 11, character: 4))
        #expect(diagnostics["/p/main/util.c"]?.first?.severity == .warning)
    }

    @Test func findsSetupScriptInParents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("sdk/esp32")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "".write(to: root.appendingPathComponent("idf-env.sh"), atomically: true, encoding: .utf8)
        #expect(IDFProject.findSetupScript(near: project, environment: [:])?.lastPathComponent == "idf-env.sh")
        try "include($ENV{IDF_PATH}/tools/cmake/project.cmake)\nproject(x)\n"
            .write(to: project.appendingPathComponent("CMakeLists.txt"), atomically: true, encoding: .utf8)
        #expect(IDFProject.isProject(project))
        #expect(!IDFProject.isProject(root))
    }

    @Test func quotesTerminalScript() {
        #expect(IDFProject.shellQuote("it's") == #"'it'\''s'"#)
        let script = IDFProject.terminalScript(setupScript: URL(fileURLWithPath: "/a/idf-env.sh"),
                                               project: URL(fileURLWithPath: "/p q"), idfArguments: ["-DX=a;b", "menuconfig"])
        #expect(script.contains("cd '/p q'"))
        #expect(script.contains("idf.py '-DX=a;b' 'menuconfig'"))
    }

    @Test func commandPassesPathsAsArguments() {
        let args = IDFProject.command(setupScript: URL(fileURLWithPath: "/a b/idf-env.sh"),
                                      project: URL(fileURLWithPath: "/p q"), idfArguments: ["-B", "b", "build"])
        #expect(args.suffix(5) == ["/a b/idf-env.sh", "/p q", "-B", "b", "build"])
    }
}

/// Builds ESP-IDF's hello_world with the real toolchain when ESPIDE_IDF_SETUP points at an env script.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ESPIDE_IDF_SETUP"] != nil))
struct IDFBuildTests {
    @Test func buildsHelloWorld() throws {
        let env = ProcessInfo.processInfo.environment
        let setup = URL(fileURLWithPath: env["ESPIDE_IDF_SETUP"]!)
        let project = URL(fileURLWithPath: env["ESPIDE_IDF_PROJECT"]!)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = IDFProject.command(setupScript: setup, project: project, idfArguments: ["build"])
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(output.suffix(2000))")
        #expect(FileManager.default.fileExists(atPath: project.appendingPathComponent("build/hello_world.bin").path))
    }
}

@Suite struct CHighlighterTests {
    @Test func tokenizesC() {
        let code = "#include \"x.h\"\n// hi\nstatic int f(void) { return 0x1F; } /* c */ gpio_set_level(2, 1);"
        let ns = code as NSString
        let tokens = CHighlighter.tokenize(code).map { (ns.substring(with: $0.range), $0.kind) }
        #expect(tokens.contains { $0 == ("#include", .decorator) })
        #expect(tokens.contains { $0 == ("\"x.h\"", .string) })
        #expect(tokens.contains { $0 == ("// hi", .comment) })
        #expect(tokens.contains { $0 == ("static", .keyword) })
        #expect(tokens.contains { $0 == ("int", .type) })
        #expect(tokens.contains { $0 == ("0x1F", .number) })
        #expect(tokens.contains { $0 == ("gpio_set_level", .function) })
        #expect(tokens.contains { $0 == ("/* c */", .comment) })
    }
}

@Suite struct ClangdTests {
    @Test func sanitizesGCCOnlyFlags() throws {
        let input = Data(#"[{"directory":"/b","command":"/t/xtensa-esp32-elf-gcc -DX=\"1\" -mlongcalls -specs=/b/p.specs -fdiagnostics-color=always -Wall -c /p/main.c","file":"/p/main.c"}]"#.utf8)
        let output = try JSONDecoder().decode(JSONValue.self, from: Clangd.sanitize(input))
        let args = output[0]?["arguments"]?.arrayValue?.compactMap(\.stringValue)
        #expect(args == ["/t/xtensa-esp32-elf-gcc", "-DX=1", "-specs=/b/p.specs", "-Wall", "-c", "/p/main.c"])
        #expect(output[0]?["command"] == nil)
        #expect(output[0]?["file"]?.stringValue == "/p/main.c")
    }

    @Test func expandsResponseFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("toolchain"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "-mlongcalls -Wno-frame-address".write(to: dir.appendingPathComponent("toolchain/cflags"), atomically: true, encoding: .utf8)
        var cache: [String: [String]] = [:]
        let args = Clangd.expandResponseFiles(["gcc", "@toolchain/cflags", "-c", "x.c"], directory: dir, cache: &cache)
        #expect(Clangd.sanitize(arguments: args) == ["gcc", "-Wno-frame-address", "-c", "x.c"])
    }

    @Test func findsBuildDirectory() {
        let project = URL(fileURLWithPath: "/p")
        #expect(Clangd.buildDirectory(project: project, idfOptions: []).path == "/p/build")
        #expect(Clangd.buildDirectory(project: project, idfOptions: ["-B", "build-s3", "-DX=1"]).path == "/p/build-s3")
        #expect(Clangd.buildDirectory(project: project, idfOptions: ["--build-dir=/tmp/b"]).path == "/tmp/b")
    }
}

/// Runs `clangd --check` on hello_world with the cleaned database (needs a built ESPIDE_IDF_PROJECT).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ESPIDE_IDF_PROJECT"] != nil && Clangd.locate() != nil))
struct ClangdCheckTests {
    @Test func cleanDatabaseHasNoErrors() throws {
        let project = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ESPIDE_IDF_PROJECT"]!)
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        let folder = try #require(try Clangd.prepareCompileCommands(buildDirectory: project.appendingPathComponent("build"), cache: cache))
        let process = Process()
        process.executableURL = Clangd.locate()
        process.arguments = ["--check=" + project.appendingPathComponent("main/hello_world_main.c").path]
            + Clangd.arguments(compileCommandsDirectory: folder).filter { !$0.hasPrefix("--log") }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let errors = output.split(separator: "\n").filter { $0.hasPrefix("E[") }
        #expect(errors.isEmpty, "\(errors.joined(separator: "\n"))")
        #expect(process.terminationStatus == 0)
    }
}

/// clangd as the IDE runs it: completes ESP-IDF APIs in a built project.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ESPIDE_IDF_PROJECT"] != nil && Clangd.locate() != nil))
struct ClangdCompletionTests {
    @Test(.timeLimit(.minutes(1))) func completesESPIDFFunctions() async throws {
        let project = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ESPIDE_IDF_PROJECT"]!)
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        let folder = try #require(try Clangd.prepareCompileCommands(buildDirectory: project.appendingPathComponent("build"), cache: cache))
        let client = LSPClient()
        try client.start(executable: Clangd.locate()!, arguments: Clangd.arguments(compileCommandsDirectory: folder),
                         environment: ToolLocator.environment(), currentDirectory: project)
        defer { Task { await client.shutdown() } }
        _ = try await client.request("initialize", params: [
            "processId": .int(Int(getpid())),
            "rootUri": .string(project.absoluteString),
            "capabilities": ["textDocument": ["completion": ["completionItem": ["snippetSupport": false]]]],
        ])
        try client.notify("initialized", params: [:])
        let file = project.appendingPathComponent("main/hello_world_main.c")
        let source = try String(contentsOf: file, encoding: .utf8) + "\nvoid espide_probe(void) { esp_restar }\n"
        try client.notify("textDocument/didOpen", params: ["textDocument": [
            "uri": .string(file.absoluteString), "languageId": "c", "version": 1, "text": .string(source)]])
        let lines = source.components(separatedBy: "\n")
        let line = lines.lastIndex { $0.contains("esp_restar") }!
        let character = (lines[line] as NSString).range(of: "esp_restar").upperBound
        let result = try await client.request("textDocument/completion", params: [
            "textDocument": ["uri": .string(file.absoluteString)],
            "position": ["line": .int(line), "character": .int(character)],
        ])
        let labels = CompletionItem.parseList(result).map(\.label)
        #expect(labels.contains { $0.contains("esp_restart") }, "\(labels.prefix(10))")
    }
}

@Suite struct BoardModulesTests {
    @Test func findsBoardOnlyImports() {
        let imported = BoardModules.imports(in: ["import network\nfrom secrets import WIFI_SSID\nimport a.b as c\n  from tm1637 import X"])
        #expect(imported == ["network", "secrets", "a", "tm1637"])
        let files = DeviceFiles.parseListing("F 62 /secrets.py\nF 4000 /main.py\nF 2000 /tm1637.py\nD 0 /lib\nF 9 /lib/ssd1306.py\n")
        let candidates = BoardModules.candidates(imported: imported.union(["ssd1306", "main"]), boardFiles: files,
                                                 localModules: ["tm1637", "main"])
        #expect(candidates == ["secrets", "ssd1306"])
    }

    @Test func stubHasTypesNotValues() {
        let stub = BoardModules.stub(fromDescription: "WIFI_SSID str\r\nWIFI_PASSWORD str\r\nretries int\r\nconnect function\r\nos module\r\n",
                                     module: "secrets")
        #expect(stub.contains("WIFI_SSID: str"))
        #expect(stub.contains("retries: int"))
        #expect(stub.contains("def connect("))
        #expect(!stub.contains("os"))
    }
}

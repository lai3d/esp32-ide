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

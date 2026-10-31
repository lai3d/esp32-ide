import Foundation

/// C/C++ language features for ESP-IDF projects through clangd.
///
/// ESP-IDF's compile_commands.json is written for GCC; clang rejects a handful of its flags
/// (`-mlongcalls`, `-fstrict-volatile-bitfields`, …). We write a cleaned copy into ESPIDE's cache
/// and point clangd there, so the project itself is never modified.
public enum Clangd {
    /// GCC-only flags clang doesn't know (exact matches, then prefixes).
    static let removedFlags: Set<String> = [
        "-mlongcalls", "-fno-shrink-wrap", "-fstrict-volatile-bitfields", "-fno-tree-switch-conversion",
        "-fno-malloc-dce", "-mdisable-hardware-atomics", "-fno-jump-tables",
    ]
    static let removedPrefixes = ["-fzero-init-padding-bits", "-fdiagnostics-color", "-mfix-esp32-psram-cache"]

    public static func locate() -> URL? {
        ToolLocator.find("clangd")
    }

    public static func arguments(compileCommandsDirectory: URL) -> [String] {
        [
            "--compile-commands-dir=\(compileCommandsDirectory.path)",
            // Lets clangd ask the cross compiler for its target and system headers.
            "--query-driver=**/xtensa-esp*-elf-g*,**/riscv32-esp-elf-g*",
            // Indexing all of ESP-IDF in the background is heavy; open files are enough for editing.
            "--background-index=false",
            "--header-insertion=never",
            "--log=error",
        ]
    }

    /// The build folder idf.py uses: `-B dir` / `--build-dir dir` in the options, else `build`.
    public static func buildDirectory(project: URL, idfOptions: [String]) -> URL {
        var dir = "build"
        for (index, option) in idfOptions.enumerated() {
            if (option == "-B" || option == "--build-dir"), index + 1 < idfOptions.count {
                dir = idfOptions[index + 1]
            } else if option.hasPrefix("--build-dir=") {
                dir = String(option.dropFirst("--build-dir=".count))
            }
        }
        return dir.hasPrefix("/") ? URL(fileURLWithPath: dir) : project.appendingPathComponent(dir)
    }

    /// Rewrites compile_commands.json with clang-incompatible flags removed; entries get an `arguments` array.
    public static func sanitize(_ data: Data) throws -> Data {
        guard case let .array(entries) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var responseFiles: [String: [String]] = [:]
        let cleaned: [JSONValue] = entries.map { entry in
            guard case var .object(object) = entry else { return entry }
            let arguments = object["arguments"]?.arrayValue?.compactMap(\.stringValue)
                ?? IDFProject.shellWords(object["command"]?.stringValue ?? "")
            let directory = URL(fileURLWithPath: object["directory"]?.stringValue ?? "/")
            let expanded = expandResponseFiles(arguments, directory: directory, cache: &responseFiles)
            object["arguments"] = .array(sanitize(arguments: expanded).map(JSONValue.string))
            object.removeValue(forKey: "command")
            return .object(object)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(JSONValue.array(cleaned))
    }

    /// Inlines `@file` arguments (ESP-IDF keeps toolchain flags such as -mlongcalls in build/toolchain/cflags).
    static func expandResponseFiles(_ arguments: [String], directory: URL, cache: inout [String: [String]],
                                    depth: Int = 0) -> [String] {
        guard depth < 4 else { return arguments }
        var result: [String] = []
        for argument in arguments {
            guard argument.hasPrefix("@"), argument.count > 1 else {
                result.append(argument)
                continue
            }
            let path = String(argument.dropFirst())
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path)
            if cache[url.path] == nil {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                    result.append(argument)
                    continue
                }
                cache[url.path] = expandResponseFiles(IDFProject.shellWords(text), directory: directory,
                                                      cache: &cache, depth: depth + 1)
            }
            result += cache[url.path] ?? []
        }
        return result
    }

    static func sanitize(arguments: [String]) -> [String] {
        arguments.filter { argument in
            !removedFlags.contains(argument) && !removedPrefixes.contains { argument.hasPrefix($0) }
        }
    }

    /// Writes the cleaned database for `buildDirectory` into a cache folder; returns that folder.
    public static func prepareCompileCommands(buildDirectory: URL, cache: URL) throws -> URL? {
        let source = buildDirectory.appendingPathComponent("compile_commands.json")
        guard let data = try? Data(contentsOf: source) else { return nil }
        let folder = cache.appendingPathComponent(String(source.path.utf8.reduce(UInt64(5381)) { ($0 << 5) &+ $0 &+ UInt64($1) }, radix: 36))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try sanitize(data).write(to: folder.appendingPathComponent("compile_commands.json"), options: .atomic)
        return folder
    }

    public static func languageID(for url: URL) -> String {
        ["cpp", "cc", "cxx", "hpp", "hh"].contains(url.pathExtension.lowercased()) ? "cpp" : "c"
    }
}

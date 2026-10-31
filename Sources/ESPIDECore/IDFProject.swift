import Foundation

/// ESP-IDF (C/C++) projects: detection, the environment that provides `idf.py`, commands and
/// compiler diagnostics.
public enum IDFProject {
    /// A folder is an ESP-IDF project when its CMakeLists.txt includes IDF's project.cmake.
    public static func isProject(_ root: URL) -> Bool {
        guard let cmake = try? String(contentsOf: root.appendingPathComponent("CMakeLists.txt"), encoding: .utf8) else {
            return false
        }
        return cmake.contains("tools/cmake/project.cmake")
    }

    /// A script that, when sourced by bash, puts `idf.py` on PATH: an explicit choice, else a
    /// project-local wrapper such as `idf-env.sh` in the project or a parent folder, else
    /// `$IDF_PATH/export.sh`, else the default `~/esp/esp-idf/export.sh`.
    public static func findSetupScript(near root: URL,
                                       environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let fm = FileManager.default
        var folder = root
        for _ in 0..<5 {
            for name in ["idf-env.sh", "export-idf.sh"] {
                let candidate = folder.appendingPathComponent(name)
                if fm.fileExists(atPath: candidate.path) { return candidate }
            }
            let parent = folder.deletingLastPathComponent()
            if parent.path == folder.path { break }
            folder = parent
        }
        var exports: [String] = []
        if let idf = environment["IDF_PATH"] { exports.append(idf + "/export.sh") }
        exports.append(fm.homeDirectoryForCurrentUser.path + "/esp/esp-idf/export.sh")
        return exports.first(where: fm.fileExists(atPath:)).map(URL.init(fileURLWithPath:))
    }

    /// Accepts an ESP-IDF folder (uses its export.sh) or a script file.
    public static func setupScript(fromChoice url: URL) -> URL? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        if !isDir.boolValue { return url }
        let export = url.appendingPathComponent("export.sh")
        return FileManager.default.fileExists(atPath: export.path) ? export : nil
    }

    /// `bash -c …` arguments that source the setup script quietly, cd into the project and run idf.py.
    /// Paths and arguments are passed as positional parameters, so nothing needs shell quoting.
    public static func command(setupScript: URL, project: URL, idfArguments: [String]) -> [String] {
        let script = #"""
        source "$1" >/dev/null || { echo "ESPIDE: sourcing $1 failed" >&2; exit 127; }
        command -v idf.py >/dev/null || { echo "ESPIDE: idf.py not found after sourcing $1" >&2; exit 127; }
        cd "$2" && shift 2 && exec idf.py "$@"
        """#
        return ["-c", script, "bash", setupScript.path, project.path] + idfArguments
    }

    /// Splits a command line like a shell: spaces separate, quotes group, backslash escapes.
    /// `-DSDKCONFIG_DEFAULTS="a;b"` → `-DSDKCONFIG_DEFAULTS=a;b`.
    public static func shellWords(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var escape = false
        for char in line {
            if escape {
                current.append(char)
                escape = false
            } else if char == "\\" && quote != "'" {
                escape = true
                inWord = true
            } else if let q = quote {
                if char == q { quote = nil } else { current.append(char) }
            } else if char == "\"" || char == "'" {
                quote = char
                inWord = true
            } else if char.isWhitespace {
                if inWord { words.append(current) }
                current = ""
                inWord = false
            } else {
                current.append(char)
                inWord = true
            }
        }
        if inWord { words.append(current) }
        return words
    }

    public static let targets = ["esp32", "esp32s2", "esp32s3", "esp32c2", "esp32c3", "esp32c5", "esp32c6", "esp32h2", "esp32p4"]

    /// GCC/Clang diagnostics (`/abs/main.c:12:5: error: …`) keyed by file path. Relative paths
    /// (as CMake sometimes prints them) resolve against the project.
    public static func diagnostics(inBuildOutput output: String, project: URL) -> [String: [Diagnostic]] {
        let regex = try! NSRegularExpression(
            pattern: #"^(.+?):(\d+):(?:(\d+):)? (fatal error|error|warning|note): (.*)$"#, options: .anchorsMatchLines)
        let ns = output as NSString
        var result: [String: [Diagnostic]] = [:]
        var seen = Set<String>()
        for match in regex.matches(in: output, range: NSRange(location: 0, length: ns.length)) {
            let kind = ns.substring(with: match.range(at: 4))
            guard kind != "note", let line = Int(ns.substring(with: match.range(at: 2))) else { continue }
            var path = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            if !path.hasPrefix("/") { path = project.appendingPathComponent(path).standardizedFileURL.path }
            let column = match.range(at: 3).location == NSNotFound ? 1 : Int(ns.substring(with: match.range(at: 3))) ?? 1
            let message = ns.substring(with: match.range(at: 5))
            guard seen.insert("\(path):\(line):\(column):\(message)").inserted else { continue }
            let start = TextPosition(line: max(line - 1, 0), character: max(column - 1, 0))
            let end = TextPosition(line: start.line, character: start.character + 1)
            let severity: Diagnostic.Severity = kind == "warning" ? .warning : .error
            let key = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            result[key, default: []].append(Diagnostic(start: start, end: end, severity: severity, message: message, source: "gcc"))
        }
        return result
    }
}

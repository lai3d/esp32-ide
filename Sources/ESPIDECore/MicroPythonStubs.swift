import Foundation

/// Type stubs for MicroPython (`micropython-esp32-stubs` from PyPI), so pyright knows `machine`,
/// `network`, … and checks code against MicroPython's smaller standard library instead of CPython's.
public enum MicroPythonStubs {
    public static let package = "micropython-esp32-stubs"

    /// ESPIDE's private install location (`pip install --target`); projects are not modified.
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ESPIDE/stubs/esp32", isDirectory: true)
    }

    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("machine.pyi").path)
    }

    /// The install command: uv if available, else the interpreter's pip.
    public static func installCommand(interpreter: URL?) -> (executable: URL, arguments: [String])? {
        if let uv = ToolLocator.find("uv") {
            return (uv, ["pip", "install", "--target", directory.path, "--upgrade", package])
        }
        guard let python = interpreter ?? ToolLocator.find("python3") else { return nil }
        return (python, ["-m", "pip", "install", "--target", directory.path, "--upgrade", package])
    }

    /// pyright analysis settings: the stubs replace typeshed, so CPython-only modules show up as missing.
    static func analysisSettings(stubs: URL?) -> [String: JSONValue] {
        guard let stubs else {
            // Without stubs `machine`, `network`, … can't resolve; that's noise, not a mistake.
            return ["diagnosticSeverityOverrides": [
                "reportMissingImports": "none",
                "reportMissingModuleSource": "none",
                "reportAttributeAccessIssue": "warning",
            ]]
        }
        return [
            "stubPath": .string(stubs.path),
            "typeshedPaths": [.string(stubs.path)],
            "diagnosticSeverityOverrides": [
                // Libraries installed on the board with mip (ssd1306, …) aren't on the Mac.
                "reportMissingImports": "warning",
                "reportMissingModuleSource": "none",
                // Drivers often add attributes dynamically; stubs are also incomplete in places.
                "reportAttributeAccessIssue": "warning",
            ],
        ]
    }
}

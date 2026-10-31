import Foundation

/// Debugging ESP-IDF apps on the chip: OpenOCD talks JTAG (the built-in USB-JTAG on S3/C3/C6, or an
/// external adapter such as ESP-Prog on the classic ESP32) and serves GDB's remote protocol on :3333;
/// ESP's GDB runs as a Debug Adapter Protocol server (`gdb -i dap`) and attaches to it.
public enum IDFDebug {
    /// What a build says about itself (build/project_description.json).
    public struct Build: Sendable, Equatable {
        public let elf: URL
        public let target: String
        /// OpenOCD's board config for the target, e.g. `-f board/esp32s3-builtin.cfg`.
        public let openOCDArguments: [String]
    }

    public static func build(in buildDirectory: URL) -> Build? {
        guard let data = try? Data(contentsOf: buildDirectory.appendingPathComponent("project_description.json")),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data),
              let elf = json["app_elf"]?.stringValue, let target = json["target"]?.stringValue else { return nil }
        let arguments = json["debug_arguments_openocd"]?.stringValue.map(IDFProject.shellWords) ?? []
        return Build(elf: buildDirectory.appendingPathComponent(elf), target: target,
                     openOCDArguments: arguments.isEmpty ? defaultOpenOCDArguments(target: target) : arguments)
    }

    /// Chips with built-in USB-JTAG use it; the classic ESP32 and S2 need an external FTDI adapter.
    static func defaultOpenOCDArguments(target: String) -> [String] {
        switch target {
        case "esp32": ["-f", "board/esp32-wrover-kit-3.3v.cfg"]
        case "esp32s2": ["-f", "board/esp32s2-kaluga-1.cfg"]
        default: ["-f", "board/\(target)-builtin.cfg"]
        }
    }

    /// Whether debugging the target needs an external JTAG adapter.
    public static func needsExternalAdapter(target: String) -> Bool {
        ["esp32", "esp32s2"].contains(target)
    }

    /// ESP's GDB for the target (the Xtensa ones are per chip; one RISC-V GDB covers C3/C6/H2/P4).
    public static func gdb(target: String) -> String {
        switch target {
        case "esp32", "esp32s2", "esp32s3": "xtensa-\(target)-elf-gdb"
        default: "riscv32-esp-elf-gdb"
        }
    }

    public static let gdbPort = 3333
    public static let openOCDReady = "Listening on port 3333 for gdb connections"

    /// The first error OpenOCD printed, e.g. no adapter found.
    public static func openOCDError(in output: String) -> String? {
        output.components(separatedBy: "\n").first { $0.hasPrefix("Error:") }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Plain-language advice for common OpenOCD failures.
    public static func advice(forOpenOCDError error: String, target: String) -> String? {
        let lower = error.lowercased()
        if lower.contains("libusb") || lower.contains("no device found") || lower.contains("unable to open") || lower.contains("ftdi") {
            return needsExternalAdapter(target: target)
                ? "The \(target.uppercased()) has no built-in USB-JTAG: connect a JTAG adapter (e.g. ESP-Prog) to GPIO12–15."
                : "No USB-JTAG device found: plug the board in by its USB port (not the UART/CH340 one)."
        }
        if lower.contains("address already in use") { return "Another OpenOCD is already running (port 3333 is taken)." }
        return nil
    }

    /// The DAP `attach` request: load the ELF's symbols and `target remote` OpenOCD's (or QEMU's) GDB
    /// server. GDB answers it only after `configurationDone`.
    public static func attachArguments(elf: URL, target remote: String = ":3333") -> JSONValue {
        ["program": .string(elf.path), "target": .string(remote)]
    }

    /// Espressif's QEMU emulates these; `idf.py qemu --gdb` waits for GDB on :3333 with the CPU halted.
    public static func qemuSupports(target: String) -> Bool {
        ["esp32", "esp32c3", "esp32s3"].contains(target)
    }

    /// QEMU starts listening right after idf.py prints its command line.
    public static let qemuStarting = "Running qemu"

    /// How to install QEMU into the ESP-IDF tools folder.
    public static func qemuInstallCommand(target: String) -> String {
        "python $IDF_PATH/tools/idf_tools.py install " + (target.hasPrefix("esp32c") ? "qemu-riscv32" : "qemu-xtensa")
    }

    /// GDB commands after connecting, as in ESP-IDF's gdbinit: restart the chip and stop at its first
    /// instruction, so the app runs from the beginning with the breakpoints in place.
    public static let resetCommands = ["monitor reset halt", "maintenance flush register-cache"]

    /// The ESP32 has two hardware watchpoints.
    public static let setupCommands = ["set remote hardware-watchpoint-limit 2"]
}

extension IDFProject {
    /// `bash -c …` arguments that source the setup script quietly and exec `tool` (e.g. openocd or
    /// a GDB) in `directory`. Nothing from the setup script reaches stdout, so a DAP stream stays clean.
    public static func toolCommand(setupScript: URL, directory: URL, tool: String, arguments: [String]) -> [String] {
        let script = #"""
        source "$1" >/dev/null 2>&1 || { echo "ESPIDE: sourcing $1 failed" >&2; exit 127; }
        command -v "$3" >/dev/null || { echo "ESPIDE: $3 not found after sourcing $1" >&2; exit 127; }
        cd "$2" && shift 2 && exec "$@"
        """#
        return ["-c", script, "bash", setupScript.path, directory.path, tool] + arguments
    }
}

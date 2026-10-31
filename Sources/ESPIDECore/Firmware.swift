import Foundation

/// MicroPython firmware images and flashing them with esptool.
public enum Firmware {
    /// Board families on micropython.org/download and where their image goes in flash.
    public enum Family: String, CaseIterable, Identifiable, Sendable {
        case esp32 = "ESP32_GENERIC"
        case esp32s3 = "ESP32_GENERIC_S3"
        case esp32s2 = "ESP32_GENERIC_S2"
        case esp32c3 = "ESP32_GENERIC_C3"
        case esp32c6 = "ESP32_GENERIC_C6"
        case esp32p4 = "ESP32_GENERIC_P4"

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .esp32: "ESP32"
            case .esp32s3: "ESP32-S3"
            case .esp32s2: "ESP32-S2"
            case .esp32c3: "ESP32-C3"
            case .esp32c6: "ESP32-C6"
            case .esp32p4: "ESP32-P4"
            }
        }

        /// Where the image (bootloader first) goes: 0x1000 on the classic ESP32, 0x2000 on the P4, 0 on the rest.
        public var flashOffset: String {
            switch self {
            case .esp32: "0x1000"
            case .esp32p4: "0x2000"
            default: "0x0"
            }
        }

        public var downloadPage: URL { URL(string: "https://micropython.org/download/\(rawValue)/")! }

        /// Maps esptool's chip name ("ESP32-D0WD-V3", "ESP32-S3 (QFN56)") to a family.
        public init?(chipDescription: String) {
            let upper = chipDescription.uppercased()
            if upper.contains("ESP32-S3") { self = .esp32s3 }
            else if upper.contains("ESP32-S2") { self = .esp32s2 }
            else if upper.contains("ESP32-C3") { self = .esp32c3 }
            else if upper.contains("ESP32-C6") { self = .esp32c6 }
            else if upper.contains("ESP32-P4") { self = .esp32p4 }
            else if upper.contains("ESP32") { self = .esp32 }
            else { return nil }
        }
    }

    /// The newest stable `.bin` linked from a micropython.org download page.
    public static func latestImage(onPage html: String, family: Family) -> URL? {
        let pattern = #"/resources/firmware/\#(family.rawValue)-\d{8}-v\d+\.\d+(?:\.\d+)?\.bin"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = html as NSString
        // The page lists releases newest first; preview builds have a "-preview" suffix and don't match.
        guard let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return URL(string: "https://micropython.org" + ns.substring(with: match.range))
    }

    /// How to run esptool: an installed `esptool`/`esptool.py`, else `uvx esptool`, else `python -m esptool`.
    public static func esptool(interpreter: URL?) -> (executable: URL, prefix: [String])? {
        if let tool = ToolLocator.find("esptool") ?? ToolLocator.find("esptool.py") { return (tool, []) }
        if let uvx = ToolLocator.find("uvx") { return (uvx, ["esptool"]) }
        if let python = interpreter ?? ToolLocator.find("python3") { return (python, ["-m", "esptool"]) }
        return nil
    }

    public static func chipIDArguments(port: String) -> [String] {
        ["--port", port, "chip_id"]
    }

    public static func eraseArguments(port: String) -> [String] {
        ["--port", port, "--baud", "460800", "erase_flash"]
    }

    public static func writeArguments(port: String, image: URL, family: Family) -> [String] {
        ["--chip", family.title.lowercased().replacingOccurrences(of: "-", with: ""),
         "--port", port, "--baud", "460800", "write_flash", "-z", family.flashOffset, image.path]
    }

    /// The chip esptool reports: "Chip is ESP32-D0WD-V3 (revision v3.1)" (v4) or "Chip type: ESP32-D0WD-V3 …" (v5).
    public static func chipDescription(inOutput output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            for prefix in ["Chip is ", "Chip type:"] {
                if let range = line.range(of: prefix) {
                    return line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return nil
    }

    /// The last percentage in esptool's progress output ("Writing at 0x00010000... (5 %)" or "… 12.3% 147456/…").
    public static func progress(inOutput output: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: #"(\d{1,3}(?:\.\d+)?) ?%"#) else { return nil }
        let ns = output as NSString
        guard let match = regex.matches(in: output, range: NSRange(location: 0, length: ns.length)).last,
              let value = Double(ns.substring(with: match.range(at: 1)))
        else { return nil }
        return min(value, 100) / 100
    }
}

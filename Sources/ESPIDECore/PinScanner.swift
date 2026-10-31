import Foundation

/// Finds the GPIOs a MicroPython project uses, by reading its source, and flags the ones that are
/// risky on a classic ESP32 (flash pins, input-only pins, boot strapping pins, ADC2 with Wi-Fi).
public enum PinScanner {
    public enum Kind: String, Sendable {
        case output, input, analog, pwm, bus, unknown
    }

    public struct Use: Sendable, Hashable, Identifiable {
        public let pin: Int
        public let kind: Kind
        public let file: URL
        /// Zero-based.
        public let line: Int
        public let text: String
        public var id: String { "\(file.path):\(line):\(pin)" }
    }

    public enum Severity: Int, Sendable, Comparable {
        case info, warning, error
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    public struct Note: Sendable, Hashable {
        public let severity: Severity
        public let message: String
    }

    public struct Pin: Sendable, Identifiable {
        public let number: Int
        public let uses: [Use]
        public let notes: [Note]
        public var id: Int { number }
        public var severity: Severity? { notes.map(\.severity).max() }
    }

    // `Pin(16`, `Pin(16, Pin.OUT)`; ADC/PWM wrap a Pin.
    private static let pinCall = try! NSRegularExpression(pattern: #"\b(ADC|PWM|DAC|TouchPad)?\(?\s*(?:machine\.)?Pin\(\s*(\d+)([^)]*)\)"#)
    // Driver keyword arguments that name a GPIO: TM1637(clk=16, dio=17), LCD1602(rs=…, d4=…).
    private static let keyword = try! NSRegularExpression(
        pattern: #"\b(clk|dio|sda|scl|rs|rw|en|e|d[0-7]|tx|rx|pin|cs|dc|rst|reset|mosi|miso|sck|trig|echo|data|din|bl|led)\s*=\s*(\d+)\b"#)
    // Constants such as BEEP_PIN = 25 or LED_GPIO = 2.
    private static let constant = try! NSRegularExpression(pattern: #"^\s*[A-Z][A-Z0-9_]*(?:PIN|GPIO)[A-Z0-9_]*\s*=\s*(\d+)\s*$"#)

    /// Every pin use in the given Python sources.
    public static func scan(_ sources: [(url: URL, text: String)]) -> [Use] {
        var uses: [Use] = []
        for (url, text) in sources {
            for (index, raw) in text.components(separatedBy: "\n").enumerated() {
                let code = stripComment(raw)
                guard !code.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                let ns = code as NSString
                let range = NSRange(location: 0, length: ns.length)
                let display = raw.trimmingCharacters(in: .whitespaces)
                var seen = Set<Int>()
                func add(_ pin: Int, _ kind: Kind) {
                    guard pin <= 48, seen.insert(pin).inserted else { return }
                    uses.append(Use(pin: pin, kind: kind, file: url, line: index, text: display))
                }
                for match in pinCall.matches(in: code, range: range) {
                    guard let pin = Int(ns.substring(with: match.range(at: 2))) else { continue }
                    let wrapper = match.range(at: 1).location == NSNotFound ? "" : ns.substring(with: match.range(at: 1))
                    let rest = ns.substring(with: match.range(at: 3))
                    let kind: Kind = switch wrapper {
                    case "ADC": .analog
                    case "PWM": .pwm
                    case "DAC": .output
                    case "TouchPad": .input
                    default: rest.contains("OUT") || rest.contains("OPEN_DRAIN") ? .output
                        : rest.contains("IN") ? .input
                        : code.range(of: #"\b(scl|sda)\s*=\s*(machine\.)?Pin\("#, options: .regularExpression) != nil ? .bus
                        : .unknown
                    }
                    add(pin, kind)
                }
                for match in keyword.matches(in: code, range: range) {
                    guard let pin = Int(ns.substring(with: match.range(at: 2))) else { continue }
                    let name = ns.substring(with: match.range(at: 1))
                    add(pin, ["sda", "scl", "mosi", "miso", "sck", "clk", "dio"].contains(name) ? .bus
                        : ["echo", "rx"].contains(name) ? .input : .unknown)
                }
                for match in constant.matches(in: code, range: range) {
                    if let pin = Int(ns.substring(with: match.range(at: 1))) { add(pin, .unknown) }
                }
            }
        }
        return uses
    }

    /// Pin facts per chip family, from Espressif's datasheets.
    public struct Chip: Sendable, Hashable {
        public let name: String
        let valid: Set<Int>
        /// Wired to the SPI flash / PSRAM on common modules.
        let flash: Set<Int>
        let inputOnly: Set<Int>
        /// Read at reset to choose boot mode or flash voltage; `critical` ones can stop the board booting.
        let strapping: Set<Int>
        let criticalStrapping: [Int: String]
        let adc2: Set<Int>
        let uart0: [Int: String]
        let usb: Set<Int>

        public static let esp32 = Chip(
            name: "ESP32", valid: Set(0...19).union([21, 22, 23, 25, 26, 27]).union(32...39),
            flash: Set(6...11), inputOnly: Set(34...39), strapping: [0, 2, 5, 15],
            criticalStrapping: [12: "pulled high at boot it selects 1.8 V flash and the board won't start"],
            adc2: [0, 2, 4, 12, 13, 14, 15, 25, 26, 27], uart0: [1: "TX", 3: "RX"], usb: [])
        public static let esp32s3 = Chip(
            name: "ESP32-S3", valid: Set(0...21).union(26...48),
            flash: Set(26...32), inputOnly: [], strapping: [0, 3, 45, 46],
            criticalStrapping: [45: "selects the flash voltage at boot — keep it low on 3.3 V flash modules"],
            adc2: Set(11...20), uart0: [43: "TX", 44: "RX"], usb: [19, 20])
        public static let esp32c3 = Chip(
            name: "ESP32-C3", valid: Set(0...21),
            flash: Set(12...17), inputOnly: [], strapping: [2, 8],
            criticalStrapping: [9: "BOOT button: low at reset enters the bootloader"],
            adc2: [5], uart0: [21: "TX", 20: "RX"], usb: [18, 19])

        public static let all = [esp32, esp32s3, esp32c3]

        /// From MicroPython's `sys.implementation._machine` / `os.uname().machine`,
        /// e.g. "Generic ESP32S3 module with ESP32S3".
        public init?(machine: String) {
            let upper = machine.uppercased().replacingOccurrences(of: "-", with: "")
            if upper.contains("ESP32S3") { self = .esp32s3 }
            else if upper.contains("ESP32C3") { self = .esp32c3 }
            else if upper.contains("ESP32") { self = .esp32 }
            else { return nil }
        }

        init(name: String, valid: Set<Int>, flash: Set<Int>, inputOnly: Set<Int>, strapping: Set<Int>,
             criticalStrapping: [Int: String], adc2: Set<Int>, uart0: [Int: String], usb: Set<Int>) {
            self.name = name
            self.valid = valid
            self.flash = flash
            self.inputOnly = inputOnly
            self.strapping = strapping
            self.criticalStrapping = criticalStrapping
            self.adc2 = adc2
            self.uart0 = uart0
            self.usb = usb
        }
    }

    /// Groups uses by pin and adds the chip's warnings.
    public static func pins(_ uses: [Use], usesWiFi: Bool, chip: Chip = .esp32) -> [Pin] {
        Dictionary(grouping: uses, by: \.pin).map { number, uses in
            Pin(number: number, uses: uses.sorted { ($0.file.path, $0.line) < ($1.file.path, $1.line) },
                notes: notes(for: number, uses: uses, usesWiFi: usesWiFi, chip: chip))
        }
        .sorted { $0.number < $1.number }
    }

    static func notes(for pin: Int, uses: [Use], usesWiFi: Bool, chip: Chip = .esp32) -> [Note] {
        var notes: [Note] = []
        let drives = uses.contains { [.output, .pwm, .bus].contains($0.kind) }
        if !chip.valid.contains(pin) {
            notes.append(Note(severity: .error, message: "GPIO\(pin) doesn't exist on the \(chip.name)"))
        }
        if chip.flash.contains(pin) {
            notes.append(Note(severity: .error, message: "Connected to the SPI flash/PSRAM — using it crashes the board"))
        }
        if chip.inputOnly.contains(pin) {
            notes.append(Note(severity: drives ? .error : .info,
                              message: drives ? "Input only — can't drive an output, PWM or I2C"
                                  : "Input only, no internal pull-up/down"))
        }
        if let role = chip.uart0[pin] {
            notes.append(Note(severity: .warning, message: "UART0 \(role) — the serial link to the Mac (REPL, uploads)"))
        }
        if chip.usb.contains(pin) {
            notes.append(Note(severity: .warning, message: "Native USB D\(pin == chip.usb.min() ? "−" : "+") — used by USB serial/JTAG"))
        }
        if let critical = chip.criticalStrapping[pin] {
            notes.append(Note(severity: .warning, message: "Strapping pin: \(critical)"))
        } else if chip.strapping.contains(pin) {
            notes.append(Note(severity: .info, message: "Strapping pin: what's connected can affect booting"))
        }
        if usesWiFi, chip.adc2.contains(pin), uses.contains(where: { $0.kind == .analog }) {
            notes.append(Note(severity: .error, message: "ADC2 can't be read while Wi-Fi is on — use an ADC1 pin"))
        }
        // The same pin in several places is normal (a constant and its use, a driver's default);
        // used as different kinds of thing usually means two devices share it.
        let kinds = Set(uses.map(\.kind)).subtracting([.unknown])
        if kinds.count > 1 {
            notes.append(Note(severity: .warning,
                              message: "Used as " + kinds.map(\.rawValue).sorted().joined(separator: " and ") + " — two devices on one pin?"))
        }
        return notes
    }

    /// True if the code connects to Wi-Fi.
    public static func usesWiFi(_ sources: [(url: URL, text: String)]) -> Bool {
        sources.contains { $0.text.contains("network.WLAN") || $0.text.contains("WLAN(") }
    }

    /// Drops a trailing `# comment`, ignoring `#` inside quotes.
    static func stripComment(_ line: String) -> String {
        var quote: Character?
        for (offset, char) in line.enumerated() {
            if let q = quote {
                if char == q { quote = nil }
            } else if char == "'" || char == "\"" {
                quote = char
            } else if char == "#" {
                return String(line.prefix(offset))
            }
        }
        return line
    }
}

import Foundation
import Testing
@testable import ESPIDECore

@Suite struct PinScannerTests {
    let url = URL(fileURLWithPath: "/p/main.py")

    @Test func findsPinsInCallsKeywordsAndConstants() {
        let code = """
        BEEP_PIN = 25
        disp = TM1637(clk=16, dio=17)
        led = Pin(2, Pin.OUT)  # Pin(99) in a comment
        adc = ADC(Pin(34))
        bmp = BMP280(SoftI2C(scl=Pin(14), sda=Pin(13)), 0x76)
        s = PWM(Pin(27), freq=50)
        msg = "Pin(5)"
        """
        let uses = PinScanner.scan([(url, code)])
        let byPin = Dictionary(uses.map { ($0.pin, $0.kind) }, uniquingKeysWith: { a, _ in a })
        #expect(byPin[25] == .unknown)
        #expect(byPin[16] == .bus && byPin[17] == .bus)
        #expect(byPin[2] == .output)
        #expect(byPin[34] == .analog)
        #expect(byPin[14] == .bus && byPin[13] == .bus)
        #expect(byPin[27] == .pwm)
        #expect(byPin[99] == nil)
        #expect(uses.first { $0.pin == 2 }?.line == 2)
    }

    @Test func flagsRiskyPins() {
        let uses = PinScanner.scan([(url, "a = Pin(35, Pin.OUT)\nb = ADC(Pin(26))\nc = Pin(12, Pin.IN)\nd = Pin(7)")])
        let pins = Dictionary(uniqueKeysWithValues: PinScanner.pins(uses, usesWiFi: true).map { ($0.number, $0) })
        #expect(pins[35]?.severity == .error)
        #expect(pins[26]?.notes.contains { $0.message.contains("ADC2") } == true)
        #expect(pins[12]?.severity == .warning)
        #expect(pins[7]?.severity == .error)
        let offline = PinScanner.pins(uses, usesWiFi: false).first { $0.number == 26 }
        #expect(offline?.severity == nil)
    }

    @Test func commentsIgnoreQuotedHashes() {
        #expect(PinScanner.stripComment("x = '#' + y  # note") == "x = '#' + y  ")
    }
}

@Suite struct MipTests {
    @Test func parsesPackageAndDeps() throws {
        let json = Data(#"{"version":"0.1.0","v":1,"hashes":[["umqtt/robust.py","167c5cd5"]],"deps":[["umqtt.simple","latest"]]}"#.utf8)
        let package = try Mip.parsePackage(json, name: "umqtt.robust")
        #expect(package.files == [Mip.File(path: "/lib/umqtt/robust.py",
                                           source: URL(string: "https://micropython.org/pi/v2/file/16/167c5cd5")!,
                                           hash: "167c5cd5")])
        #expect(package.deps.map(\.name) == ["umqtt.simple"])
    }

    @Test func resolvesDependenciesOnce() async throws {
        let index: [String: String] = [
            "a": #"{"hashes":[["a.py","aa11"]],"deps":[["b","latest"],["c","latest"]]}"#,
            "b": #"{"hashes":[["b.py","bb22"]],"deps":[["c","latest"]]}"#,
            "c": #"{"hashes":[["c.py","cc33"]]}"#,
        ]
        let files = try await Mip.resolve("a") { url in
            let name = url.deletingLastPathComponent().lastPathComponent
            return index[name].map { (Data($0.utf8), 200) } ?? (Data(), 404)
        }
        #expect(files.map(\.path) == ["/lib/a.py", "/lib/b.py", "/lib/c.py"])
        await #expect(throws: Mip.Error.self) {
            _ = try await Mip.resolve("missing") { _ in (Data(), 404) }
        }
    }

    @Test func singleFileSpecs() {
        #expect(Mip.singleFileURL("github:user/repo/drivers/st7789.py")?.absoluteString
                == "https://raw.githubusercontent.com/user/repo/HEAD/drivers/st7789.py")
        #expect(Mip.singleFileURL("https://example.com/x.py") != nil)
        #expect(Mip.singleFileURL("ssd1306") == nil)
    }
}

@Suite struct PinConflictTests {
    @Test func warnsOnlyWhenKindsDiffer() {
        let url = URL(fileURLWithPath: "/p/main.py")
        let same = PinScanner.pins(PinScanner.scan([(url, "LED_PIN = 23\nled = Pin(23, Pin.OUT)")]), usesWiFi: false)
        #expect(same.first?.notes.isEmpty == true)
        let mixed = PinScanner.pins(PinScanner.scan([(url, "a = Pin(4, Pin.OUT)\nb = ADC(Pin(4))")]), usesWiFi: false)
        #expect(mixed.first?.severity == .warning)
    }
}

@Suite struct MipHashTests {
    @Test func rejectsCorruptDownloads() async throws {
        let good = Data("print(1)\n".utf8)
        let file = Mip.File(path: "/lib/x.py", source: URL(string: "https://x/y")!, hash: String(good.sha256Hex.prefix(8)))
        #expect(try await file.download { _ in (good, 200) } == good)
        await #expect(throws: Mip.Error.self) { _ = try await file.download { _ in (Data("evil".utf8), 200) } }
    }
}

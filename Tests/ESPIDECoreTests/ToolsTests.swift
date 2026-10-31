import Foundation
import Testing
@testable import ESPIDECore

@Suite struct FirmwareTests {
    @Test func findsNewestStableImage() {
        let html = """
        <a href="/resources/firmware/ESP32_GENERIC-20261030-v1.30.0-preview.45.g1234abcd.bin">preview</a>
        <a href="/resources/firmware/ESP32_GENERIC_S3-20260824-v1.29.0.bin">s3</a>
        <a href="/resources/firmware/ESP32_GENERIC-20260824-v1.29.0.bin">v1.29.0</a>
        <a href="/resources/firmware/ESP32_GENERIC-20260406-v1.28.0.bin">v1.28.0</a>
        """
        #expect(Firmware.latestImage(onPage: html, family: .esp32)?.absoluteString
                == "https://micropython.org/resources/firmware/ESP32_GENERIC-20260824-v1.29.0.bin")
        #expect(Firmware.latestImage(onPage: html, family: .esp32s3)?.lastPathComponent == "ESP32_GENERIC_S3-20260824-v1.29.0.bin")
        #expect(Firmware.latestImage(onPage: html, family: .esp32c3) == nil)
    }

    @Test func readsChipFromEsptoolOutput() {
        let v5 = "Connected to ESP32 on /dev/cu.usbserial-110:\nChip type:          ESP32-D0WD-V3 (revision v3.1)\n"
        let v4 = "Chip is ESP32-S3 (QFN56) (revision v0.2)\n"
        #expect(Firmware.chipDescription(inOutput: v5) == "ESP32-D0WD-V3 (revision v3.1)")
        #expect(Firmware.chipDescription(inOutput: v5).flatMap(Firmware.Family.init(chipDescription:)) == .esp32)
        #expect(Firmware.chipDescription(inOutput: v4).flatMap(Firmware.Family.init(chipDescription:)) == .esp32s3)
        #expect(Firmware.Family(chipDescription: "ESP32-P4 (revision v1.0)") == .esp32p4)
        #expect(Firmware.Family.esp32p4.flashOffset == "0x2000")
        #expect(Firmware.Family.esp32c6.flashOffset == "0x0")
    }

    @Test func writeArgumentsUseChipOffset() {
        let image = URL(fileURLWithPath: "/tmp/fw.bin")
        #expect(Firmware.writeArguments(port: "/dev/x", image: image, family: .esp32)
                == ["--chip", "esp32", "--port", "/dev/x", "--baud", "460800", "write_flash", "-z", "0x1000", "/tmp/fw.bin"])
        #expect(Firmware.writeArguments(port: "/dev/x", image: image, family: .esp32s3).prefix(2) == ["--chip", "esp32s3"])
        #expect(Firmware.writeArguments(port: "/dev/x", image: image, family: .esp32s3).contains("0x0"))
    }

    @Test func parsesProgress() {
        #expect(Firmware.progress(inOutput: "Writing at 0x00010000... (5 %)\nWriting at 0x00014000... (12 %)") == 0.12)
        #expect(Firmware.progress(inOutput: "Writing at 0x0001b8c0 [====>   ]  37.5% 147456/393216 bytes") == 0.375)
        #expect(Firmware.progress(inOutput: "Connecting....") == nil)
    }
}

@Suite struct PlotTests {
    @Test func parsesNamedAndBareValues() {
        #expect(PlotParser.values(in: "t=23.5 hPa: 1011.7").map(\.name) == ["t", "hPa"])
        #expect(PlotParser.values(in: "23.5, 1011.7").map(\.value) == [23.5, 1011.7])
        #expect(PlotParser.values(in: "-3").map(\.value) == [-3])
        #expect(PlotParser.values(in: "Traceback (most recent call last):").isEmpty)
        #expect(PlotParser.values(in: "blink 3").isEmpty)
        #expect(PlotParser.values(in: "").isEmpty)
    }

    @Test func feedsCompleteLinesOnly() {
        var plot = PlotData()
        plot.feed("1\n2\n3")
        #expect(plot.series["1"]?.map(\.value) == [1, 2])
        plot.feed("4\n")
        #expect(plot.series["1"]?.map(\.value) == [1, 2, 34])
        plot.capacity = 2
        plot.feed("5\n")
        #expect(plot.series["1"]?.count == 2)
    }
}

@Suite struct I2CTests {
    @Test func parsesScanOutput() {
        #expect(I2C.parseScan("[39, 60]\r\n") == [39, 60])
        #expect(I2C.parseScan("[]\r\n") == [])
        #expect(I2C.parseScan("Traceback") == nil)
        #expect(I2C.describe(0x3C) == "0x3C  SSD1306/SH1106 OLED")
        #expect(I2C.describe(0x01) == "0x01  (unknown)")
    }
}

@Suite struct StubsTests {
    @Test func configurationUsesStubsWhenInstalled() {
        let stubs = URL(fileURLWithPath: "/stubs")
        let config = LanguageServerSpec.configuration(items: [["section": "python.analysis"]], pythonPath: nil, stubs: stubs)
        #expect(config[0]?["stubPath"]?.stringValue == "/stubs")
        #expect(config[0]?["diagnosticSeverityOverrides"]?["reportMissingImports"]?.stringValue == "warning")
        let bare = LanguageServerSpec.configuration(items: [["section": "python.analysis"]], pythonPath: nil)
        #expect(bare[0]?["stubPath"] == nil)
        #expect(bare[0]?["diagnosticSeverityOverrides"]?["reportMissingImports"]?.stringValue == "none")
    }
}

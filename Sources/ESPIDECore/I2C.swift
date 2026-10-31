import Foundation

/// I2C bus scanning and the usual parts at each address.
public enum I2C {
    public static func scanScript(sda: Int, scl: Int) -> String {
        """
        from machine import SoftI2C, Pin
        print(SoftI2C(scl=Pin(\(scl)), sda=Pin(\(sda)), freq=100000).scan())
        """
    }

    /// Parses `[39, 60]` into addresses.
    public static func parseScan(_ output: String) -> [Int]? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { return nil }
        let inner = trimmed.dropFirst().dropLast()
        if inner.trimmingCharacters(in: .whitespaces).isEmpty { return [] }
        let values = inner.split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        return values.contains(nil) ? nil : values.compactMap { $0 }
    }

    public static let knownDevices: [Int: String] = [
        0x10: "RDA5807M FM radio",
        0x1E: "HMC5883L compass",
        0x20: "PCF8574 I/O expander (LCD backpack)",
        0x23: "BH1750 light sensor",
        0x27: "PCF8574 LCD1602 backpack",
        0x38: "AHT10/AHT20 humidity",
        0x3C: "SSD1306/SH1106 OLED",
        0x3D: "SSD1306 OLED (alt address)",
        0x3F: "PCF8574A LCD backpack",
        0x40: "INA219 / HTU21D / PCA9685",
        0x44: "SHT3x humidity",
        0x48: "ADS1115 ADC / LM75",
        0x50: "AT24C EEPROM",
        0x53: "ADXL345 accelerometer",
        0x57: "AT24C32 EEPROM (RTC module)",
        0x5A: "MLX90614 IR thermometer",
        0x60: "Si4703 / MCP4725 DAC",
        0x68: "MPU6050 IMU / DS3231 RTC",
        0x69: "MPU6050 (AD0 high)",
        0x76: "BMP280/BME280 pressure",
        0x77: "BMP280/BME280/BMP180 (alt address)",
    ]

    public static func describe(_ address: Int) -> String {
        let hex = String(format: "0x%02X", address)
        return knownDevices[address].map { "\(hex)  \($0)" } ?? "\(hex)  (unknown)"
    }
}

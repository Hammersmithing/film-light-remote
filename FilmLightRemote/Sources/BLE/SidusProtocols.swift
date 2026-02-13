import Foundation

// MARK: - Protocol Interface

protocol SidusProtocol {
    var commandType: UInt8 { get }
    func getSendData() -> Data
}

// MARK: - CCT Protocol (Command Type = 2)

/// Controls Color Temperature lights (like Amaran 120C)
/// Ported from CCTProtocol.java
struct CCTProtocol: SidusProtocol {
    let commandType: UInt8 = 2

    /// Intensity 0-1000 (represents 0-100% * 10)
    var intensity: Int

    /// Color temperature: 320-560 (represents 3200K-5600K / 10)
    var cct: Int

    /// Green-Magenta adjustment: 0-200 (100 = neutral)
    var gm: Int

    /// GM interpretation mode
    var gmFlag: Int

    /// Sleep mode enabled
    var sleepMode: Int

    /// Auto-patch flag
    var autoPatchFlag: Int

    init(intensity: Int = 500, cct: Int = 440, gm: Int = 100, gmFlag: Int = 0, sleepMode: Int = 1, autoPatchFlag: Int = 0) {
        self.intensity = max(0, min(1000, intensity))
        self.cct = max(180, min(2000, cct))
        self.gm = max(0, min(200, gm))
        self.gmFlag = gmFlag
        self.sleepMode = sleepMode
        self.autoPatchFlag = autoPatchFlag
    }

    /// Convenience initializer with percentage and Kelvin values
    init(intensityPercent: Double, cctKelvin: Int, gm: Int = 100) {
        self.intensity = Int(intensityPercent * 10)
        self.cct = cctKelvin / 10
        self.gm = gm
        self.gmFlag = 0
        self.sleepMode = 1
        self.autoPatchFlag = 0
    }

    func getSendData() -> Data {
        var bits = [String]()

        // Build bit string (reversed order, LSB first per BinaryKit)
        bits.append(toBinary(0, width: 8))                                           // Reserved
        bits.append(toBinary(sleepMode, width: 1))                                   // Sleep mode
        bits.append(toBinary(0, width: 20))                                          // Reserved
        bits.append(toBinary(0, width: 12))                                          // Reserved
        bits.append(toBinary(autoPatchFlag, width: 1))                               // Auto patch
        bits.append(toBinary((cct * 10 <= 10000) ? 0 : 1, width: 1))                 // CCT high flag

        bits.append(toBinary(gmFlag, width: 1))                                      // GM flag

        var gmHigh = 0
        var gmValue = gm
        if gmFlag == 0 {
            gmHigh = 0
            gmValue = Int(round(Double(gm) / 10.0))
        } else {
            if gmValue > 100 {
                gmHigh = 1
                gmValue -= 100
            } else {
                gmHigh = 0
            }
        }

        bits.append(toBinary(gmHigh, width: 1))                                      // GM high
        bits.append(toBinary(gmValue, width: 7))                                     // GM value

        // CCT value (handle high range)
        var cctValue = cct * 10
        if cctValue > 10000 {
            cctValue -= 10000
        }
        cctValue = cctValue / 10

        bits.append(toBinary(cctValue, width: 10))                                   // CCT
        bits.append(toBinary(intensity, width: 10))                                  // Intensity
        bits.append(toBinary(Int(commandType), width: 7))                            // Command type
        bits.append(toBinary(1, width: 1))                                           // Always 1

        // Reverse each segment and concatenate
        var bitString = ""
        for bit in bits {
            bitString += String(bit.reversed())
        }

        return to10ByteArray(bitString)
    }
}

// MARK: - HSI Protocol (Command Type = 1)

/// Controls RGB/HSI lights
/// Ported from HSIProtocol.java
struct HSIProtocol: SidusProtocol {
    let commandType: UInt8 = 1

    /// Intensity 0-1000 (represents 0-100% * 10)
    var intensity: Int

    /// Hue: 0-360 degrees
    var hue: Int

    /// Saturation: 0-100%
    var sat: Int

    /// Color temperature offset
    var cct: Int

    /// Green-Magenta adjustment
    var gm: Int

    /// GM interpretation mode
    var gmFlag: Int

    /// Sleep mode
    var sleepMode: Int

    /// Auto-patch flag
    var autoPatchFlag: Int

    init(intensity: Int = 500, hue: Int = 0, sat: Int = 100, cct: Int = 200, gm: Int = 100,
         gmFlag: Int = 0, sleepMode: Int = 1, autoPatchFlag: Int = 0) {
        self.intensity = max(0, min(1000, intensity))
        self.hue = max(0, min(360, hue))
        self.sat = max(0, min(100, sat))
        self.cct = cct
        self.gm = gm
        self.gmFlag = gmFlag
        self.sleepMode = sleepMode
        self.autoPatchFlag = autoPatchFlag
    }

    /// Convenience initializer with percentage values
    init(intensityPercent: Double, hue: Int, saturationPercent: Double) {
        self.intensity = Int(intensityPercent * 10)
        self.hue = hue
        self.sat = Int(saturationPercent)
        self.cct = 200  // Default CCT offset
        self.gm = 100   // Neutral GM
        self.gmFlag = 0
        self.sleepMode = 1
        self.autoPatchFlag = 0
    }

    func getSendData() -> Data {
        var bits = [String]()

        bits.append(toBinary(0, width: 8))                                           // Reserved
        bits.append(toBinary(sleepMode, width: 1))                                   // Sleep mode
        bits.append(toBinary(0, width: 18))                                          // Reserved
        bits.append(toBinary(autoPatchFlag, width: 1))                               // Auto patch
        bits.append(toBinary((cct * 50 <= 10000) ? 0 : 1, width: 1))                 // CCT high flag
        bits.append(toBinary(gmFlag, width: 1))                                      // GM flag

        var gmHigh = 0
        var gmValue = gm
        if gmFlag == 0 {
            gmHigh = 0
            gmValue = Int(round(Double(gm) / 10.0))
        } else {
            if gmValue > 100 {
                gmHigh = 1
                gmValue -= 100
            } else {
                gmHigh = 0
            }
        }

        bits.append(toBinary(gmHigh, width: 1))                                      // GM high
        bits.append(toBinary(gmValue, width: 7))                                     // GM value

        // CCT value
        var cctValue = cct * 50
        if cctValue > 10000 {
            cctValue -= 10000
        }
        cctValue = cctValue / 50

        bits.append(toBinary(cctValue, width: 8))                                    // CCT
        bits.append(toBinary(sat, width: 7))                                         // Saturation
        bits.append(toBinary(hue, width: 9))                                         // Hue
        bits.append(toBinary(intensity, width: 10))                                  // Intensity
        bits.append(toBinary(Int(commandType), width: 7))                            // Command type
        bits.append(toBinary(1, width: 1))                                           // Always 1

        var bitString = ""
        for bit in bits {
            bitString += String(bit.reversed())
        }

        return to10ByteArray(bitString)
    }
}

// MARK: - Sleep Protocol (Command Type = 12) — Power On/Off

/// Power on/off via sleep mode command, matching Sidus Link's SleepProtocol
/// commandType=12: sleepMode=1 → ON (awake), sleepMode=0 → OFF (sleep)
struct SleepProtocol: SidusProtocol {
    let commandType: UInt8 = 12

    var sleepMode: Int  // 0 = off/sleep, 1 = on/awake

    init(on: Bool) {
        self.sleepMode = on ? 1 : 0
    }

    func getSendData() -> Data {
        var bits = [String]()

        bits.append(toBinary(0, width: 8))                // Reserved
        bits.append(toBinary(sleepMode, width: 1))         // Sleep mode (0=off, 1=on)
        bits.append(toBinary(0, width: 20))                // Reserved
        bits.append(toBinary(0, width: 12))                // Reserved
        bits.append(toBinary(0, width: 1))                 // autoPatchFlag
        bits.append(toBinary(0, width: 1))                 // CCT high flag
        bits.append(toBinary(0, width: 1))                 // GM flag
        bits.append(toBinary(0, width: 1))                 // GM high
        bits.append(toBinary(0, width: 7))                 // GM value
        bits.append(toBinary(0, width: 10))                // CCT
        bits.append(toBinary(0, width: 10))                // Intensity
        bits.append(toBinary(Int(commandType), width: 7))  // Command type = 12
        bits.append(toBinary(1, width: 1))                 // operaType = 1 (write)

        var bitString = ""
        for bit in bits {
            bitString += String(bit.reversed())
        }

        return to10ByteArray(bitString)
    }
}

// MARK: - Bit Packing Utilities (ported from BinaryKit.java)

/// Convert integer to binary string with specified width
private func toBinary(_ value: Int, width: Int) -> String {
    let masked = value | (1 << width)
    let binary = String(masked, radix: 2)
    return String(binary.suffix(width))
}

/// Convert bit string to 10-byte array with checksum
private func to10ByteArray(_ bitString: String) -> Data {
    var bytes = Data(count: 10)

    for i in 0..<10 {
        let startIndex = bitString.index(bitString.startIndex, offsetBy: i * 8)
        let endIndex = bitString.index(startIndex, offsetBy: 8)
        let byteString = String(String(bitString[startIndex..<endIndex]).reversed())
        bytes[i] = UInt8(byteString, radix: 2) ?? 0
    }

    // Byte 0 = checksum (sum of bytes 1-9)
    var checksum: UInt8 = 0
    for i in 1..<10 {
        checksum = checksum &+ bytes[i]
    }
    bytes[0] = checksum

    return bytes
}

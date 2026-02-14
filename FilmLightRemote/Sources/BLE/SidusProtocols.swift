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
        self.intensity = Int(round(intensityPercent * 10))
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
    init(intensityPercent: Double, hue: Int, saturationPercent: Double, cctKelvin: Int = 5600) {
        self.intensity = Int(round(intensityPercent * 10))
        self.hue = hue
        self.sat = Int(saturationPercent)
        self.cct = cctKelvin / 50  // Protocol field = Kelvin / 50
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

// MARK: - Effect Protocol (Command Type = 7)

/// Controls all light effects via the Sidus vendor protocol.
/// Handles simple effects (Candle, Fire, TV, CopCar, Party, Fireworks, Paparazzi, Lightning)
/// and multi-mode effects (Strobe, Explosion, FaultyBulb, Pulsing, Welding) in CCT mode.
struct SidusEffectProtocol: SidusProtocol {
    let commandType: UInt8 = 7

    var effectType: Int
    var intensity: Int = 500  // 0-1000
    var frq: Int = 8          // 0-15
    var sleepMode: Int = 1

    // CCT-related (for effects that use color temperature)
    var cct: Int = 560        // cctKelvin / 10 (default 5600K)
    var gm: Int = 100         // 0-200 (100 = neutral)
    var gmFlag: Int = 0

    // Simple effect params
    var color: Int = 0        // CopCar (0-15)
    var sat: Int = 100        // Party (0-100)
    var type: Int = 0         // Fireworks type (0-255)

    // Lightning params
    var speed: Int = 8        // 0-15 for Lightning, 0-15 for Pulsing/FaultyBulb
    var trigger: Int = 2      // 0-3

    // Welding min field (0-127)
    var min: Int = 0

    // Multi-mode (always 0 = CCT for our purposes)
    var effectMode: Int = 0

    /// Convenience initializer for simple effect activation
    init(effectType: Int, intensityPercent: Double = 50, frq: Int = 8, cctKelvin: Int = 5600) {
        self.effectType = effectType
        self.intensity = Int(round(intensityPercent * 10))
        self.frq = frq
        self.cct = cctKelvin / 10
    }

    func getSendData() -> Data {
        var bits = [String]()

        switch effectType {
        case 3, 4, 5: // TV, Candle, Fire — simple with cct/cctType(10)
            bits.append(toBinary(0, width: 8))
            bits.append(toBinary(sleepMode, width: 1))
            bits.append(toBinary(0, width: 20))
            bits.append(toBinary(0, width: 11))
            bits.append(toBinary(cct, width: 10))
            bits.append(toBinary(frq, width: 4))
            bits.append(toBinary(intensity, width: 10))
            bits.append(toBinary(effectType, width: 8))
            bits.append(toBinary(7, width: 7))
            bits.append(toBinary(1, width: 1))

        case 1: // Paparazzi — cct + gm fields
            bits.append(toBinary(0, width: 8))
            bits.append(toBinary(sleepMode, width: 1))
            bits.append(toBinary(0, width: 20))
            bits.append(toBinary(0, width: 1))
            let cctHigh = (cct * 10 > 10000) ? 1 : 0
            bits.append(toBinary(cctHigh, width: 1))
            bits.append(toBinary(gmFlag, width: 1))
            let (gmHighVal, gmVal) = computeGM()
            bits.append(toBinary(gmHighVal, width: 1))
            bits.append(toBinary(gmVal, width: 7))
            bits.append(toBinary(computeCCTValue(), width: 10))
            bits.append(toBinary(frq, width: 4))
            bits.append(toBinary(intensity, width: 10))
            bits.append(toBinary(effectType, width: 8))
            bits.append(toBinary(7, width: 7))
            bits.append(toBinary(1, width: 1))

        case 2: // Lightning — cct + gm + speed + trigger
            bits.append(toBinary(0, width: 8))
            bits.append(toBinary(sleepMode, width: 1))
            bits.append(toBinary(0, width: 15))
            let cctHigh = (cct * 10 > 10000) ? 1 : 0
            bits.append(toBinary(cctHigh, width: 1))
            bits.append(toBinary(gmFlag, width: 1))
            let (gmHighVal, gmVal) = computeGM()
            bits.append(toBinary(gmHighVal, width: 1))
            bits.append(toBinary(speed, width: 4))
            bits.append(toBinary(trigger, width: 2))
            bits.append(toBinary(gmVal, width: 7))
            bits.append(toBinary(computeCCTValue(), width: 10))
            bits.append(toBinary(frq, width: 4))
            bits.append(toBinary(intensity, width: 10))
            bits.append(toBinary(effectType, width: 8))
            bits.append(toBinary(7, width: 7))
            bits.append(toBinary(1, width: 1))

        case 11: // CopCar — color(4)
            bits.append(toBinary(0, width: 8))
            bits.append(toBinary(sleepMode, width: 1))
            bits.append(toBinary(0, width: 20))
            bits.append(toBinary(0, width: 17))
            bits.append(toBinary(color, width: 4))
            bits.append(toBinary(frq, width: 4))
            bits.append(toBinary(intensity, width: 10))
            bits.append(toBinary(effectType, width: 8))
            bits.append(toBinary(7, width: 7))
            bits.append(toBinary(1, width: 1))

        case 13: // Party — sat(7)
            bits.append(toBinary(0, width: 8))
            bits.append(toBinary(sleepMode, width: 1))
            bits.append(toBinary(0, width: 20))
            bits.append(toBinary(0, width: 14))
            bits.append(toBinary(sat, width: 7))
            bits.append(toBinary(frq, width: 4))
            bits.append(toBinary(intensity, width: 10))
            bits.append(toBinary(effectType, width: 8))
            bits.append(toBinary(7, width: 7))
            bits.append(toBinary(1, width: 1))

        case 14: // Fireworks — type(8)
            bits.append(toBinary(0, width: 8))
            bits.append(toBinary(sleepMode, width: 1))
            bits.append(toBinary(0, width: 20))
            bits.append(toBinary(0, width: 13))
            bits.append(toBinary(type, width: 8))
            bits.append(toBinary(frq, width: 4))
            bits.append(toBinary(intensity, width: 10))
            bits.append(toBinary(effectType, width: 8))
            bits.append(toBinary(7, width: 7))
            bits.append(toBinary(1, width: 1))

        case 6, 7: // Strobe, Explosion — multi-mode (CCT, no speed)
            bits.append(toBinary(0, width: 8))
            bits.append(toBinary(sleepMode, width: 1))
            bits.append(toBinary(0, width: 15))
            let cctHigh = (cct * 10 > 10000) ? 1 : 0
            bits.append(toBinary(cctHigh, width: 1))
            bits.append(toBinary(gmFlag, width: 1))
            let (gmHighVal, gmVal) = computeGM()
            bits.append(toBinary(gmHighVal, width: 1))
            bits.append(toBinary(trigger, width: 2))
            bits.append(toBinary(gmVal, width: 7))
            bits.append(toBinary(computeCCTValue(), width: 10))
            bits.append(toBinary(intensity, width: 10))
            bits.append(toBinary(frq, width: 4))
            bits.append(toBinary(effectMode, width: 4))
            bits.append(toBinary(effectType, width: 8))
            bits.append(toBinary(7, width: 7))
            bits.append(toBinary(1, width: 1))

        case 8, 9: // FaultyBulb, Pulsing — multi-mode (CCT, speed 4-bit)
            bits.append(toBinary(0, width: 8))
            bits.append(toBinary(sleepMode, width: 1))
            bits.append(toBinary(0, width: 11))
            let cctHigh = (cct * 10 > 10000) ? 1 : 0
            bits.append(toBinary(cctHigh, width: 1))
            bits.append(toBinary(gmFlag, width: 1))
            let (gmHighVal, gmVal) = computeGM()
            bits.append(toBinary(gmHighVal, width: 1))
            bits.append(toBinary(speed, width: 4))
            bits.append(toBinary(trigger, width: 2))
            bits.append(toBinary(gmVal, width: 7))
            bits.append(toBinary(computeCCTValue(), width: 10))
            bits.append(toBinary(intensity, width: 10))
            bits.append(toBinary(frq, width: 4))
            bits.append(toBinary(effectMode, width: 4))
            bits.append(toBinary(effectType, width: 8))
            bits.append(toBinary(7, width: 7))
            bits.append(toBinary(1, width: 1))

        case 10: // Welding — multi-mode (CCT, min 7-bit)
            bits.append(toBinary(0, width: 8))
            bits.append(toBinary(sleepMode, width: 1))
            bits.append(toBinary(0, width: 8))
            let cctHigh = (cct * 10 > 10000) ? 1 : 0
            bits.append(toBinary(cctHigh, width: 1))
            bits.append(toBinary(gmFlag, width: 1))
            let (gmHighVal, gmVal) = computeGM()
            bits.append(toBinary(gmHighVal, width: 1))
            bits.append(toBinary(min, width: 7))
            bits.append(toBinary(trigger, width: 2))
            bits.append(toBinary(gmVal, width: 7))
            bits.append(toBinary(computeCCTValue(), width: 10))
            bits.append(toBinary(intensity, width: 10))
            bits.append(toBinary(frq, width: 4))
            bits.append(toBinary(effectMode, width: 4))
            bits.append(toBinary(effectType, width: 8))
            bits.append(toBinary(7, width: 7))
            bits.append(toBinary(1, width: 1))

        case 15: // Effect Off
            bits.append(toBinary(0, width: 8))
            bits.append(toBinary(0, width: 1))
            bits.append(toBinary(0, width: 20))
            bits.append(toBinary(0, width: 20))
            bits.append(toBinary(0, width: 15))
            bits.append(toBinary(15, width: 8))
            bits.append(toBinary(7, width: 7))
            bits.append(toBinary(1, width: 1))

        default:
            // Unknown effect — send effect off
            return SidusEffectProtocol(effectType: 15).getSendData()
        }

        var bitString = ""
        for bit in bits {
            bitString += String(bit.reversed())
        }
        return to10ByteArray(bitString)
    }

    // MARK: - Helpers

    private func computeGM() -> (gmHigh: Int, gmValue: Int) {
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
        return (gmHigh, gmValue)
    }

    private func computeCCTValue() -> Int {
        var cctValue = cct * 10
        if cctValue > 10000 { cctValue -= 10000 }
        return cctValue / 10
    }
}

// MARK: - Sidus Status Parser (reverse of bit-packing)

struct SidusLightStatus {
    var commandType: Int  // 1=HSI, 2=CCT, 12=Sleep
    var intensity: Double // 0-100%
    var isOn: Bool
    // CCT fields
    var cctKelvin: Int?
    // HSI fields
    var hue: Int?
    var saturation: Int?
}

struct SidusStatusParser {
    /// Parse a 10-byte Sidus payload into a SidusLightStatus
    /// Reverses the bit-packing done by CCTProtocol/HSIProtocol/SleepProtocol
    static func parse(_ data: Data) -> SidusLightStatus? {
        guard data.count >= 10 else { return nil }

        // Verify checksum: byte 0 == sum of bytes 1-9
        var checksum: UInt8 = 0
        for i in 1..<10 { checksum = checksum &+ data[i] }
        guard data[0] == checksum else { return nil }

        // Convert bytes to bit string (reverse of to10ByteArray)
        // Each byte is stored LSB-first, so reverse each byte's bits
        var bitString = ""
        for i in 0..<10 {
            let byte = data[i]
            var byteBits = ""
            for bit in 0..<8 {
                byteBits.append((byte >> bit) & 1 == 1 ? "1" : "0")
            }
            // The encoding reverses each segment then writes it,
            // so each byte's bits are stored reversed (LSB first).
            // To recover, reverse each byte's bits back.
            bitString += String(byteBits.reversed())
        }

        // Now extract fields from the bit string.
        // The fields were appended in a specific order and each segment reversed,
        // so we read from the END of the bit string (the last-appended fields).
        // Layout (reading from bit 0 of byte 0 as MSB):
        //   Byte 0 = checksum (8 bits) — skip
        //   Then the data bits start at bit 8 (byte 1 onward):
        //
        // The bit-packing appends segments and reverses each, then puts them
        // in a flat string. The fields from the bottom of getSendData() are at
        // the END of the 80-bit payload (bytes 1-9 = 72 bits, but byte 0 is
        // checksum so the actual data bits are bytes 1-9).
        //
        // We need to work with bytes 1-9 (72 data bits).
        // Rebuild the bit string from just bytes 1-9.

        var dataBits = ""
        for i in 1..<10 {
            let byte = data[i]
            var byteBits = ""
            for bit in 0..<8 {
                byteBits.append((byte >> bit) & 1 == 1 ? "1" : "0")
            }
            dataBits += String(byteBits.reversed())
        }

        // dataBits is 72 bits. Read from the end (rightmost = last appended).
        // The fields were appended in this order (CCT example):
        //   reserved(8), sleepMode(1), reserved(20), reserved(12), autoPatch(1),
        //   cctHighFlag(1), gmFlag(1), gmHigh(1), gmValue(7), cctValue(10),
        //   intensity(10), commandType(7), operaType(1)
        //
        // Each segment was individually reversed before concatenation.
        // Total = 8+1+20+12+1+1+1+1+7+10+10+7+1 = 80 bits = 10 bytes (including checksum byte)
        // But byte 0 is checksum, so 72 data bits in bytes 1-9.
        // Actually the full 80-bit string includes the checksum byte.
        // Let me re-read the encoding...

        // Actually, to10ByteArray takes the full 80-bit string and writes 10 bytes,
        // then overwrites byte 0 with checksum. So the first 8 bits of bitString
        // are thrown away (overwritten by checksum).
        // The data bits in bytes 1-9 correspond to bits 8-79 of the original string.
        //
        // Let me just read the bits directly from the raw bytes, matching how
        // the encoder packs them.

        // More direct approach: read the 72 data bits (bytes 1-9) and extract fields
        // from the end, since the last-appended fields end up at the highest bit positions.

        // The bit layout for the 72 data bits (reading from end = last appended first):
        // operaType: 1 bit (rightmost)
        // commandType: 7 bits
        // intensity: 10 bits
        // Then mode-specific fields...

        // Extract bits from the rightmost side of dataBits
        let bits = Array(dataBits)
        var pos = bits.count  // Start from end

        func readBitsFromEnd(_ count: Int) -> Int {
            pos -= count
            var val = 0
            for i in 0..<count {
                if bits[pos + i] == "1" {
                    val |= (1 << (count - 1 - i))
                }
            }
            return val
        }

        _ = readBitsFromEnd(1) // operaType
        let commandType = readBitsFromEnd(7)
        let intensityRaw = readBitsFromEnd(10) // 0-1000

        let intensity = Double(intensityRaw) / 10.0

        switch commandType {
        case 2: // CCT
            let cctValue = readBitsFromEnd(10)
            let gmValue = readBitsFromEnd(7)
            _ = gmValue // not needed for status
            let gmHigh = readBitsFromEnd(1)
            _ = gmHigh
            let gmFlag = readBitsFromEnd(1)
            _ = gmFlag
            let cctHighFlag = readBitsFromEnd(1)
            let autoPatchFlag = readBitsFromEnd(1)
            _ = autoPatchFlag
            // Skip remaining reserved bits to get sleepMode
            _ = readBitsFromEnd(12)
            _ = readBitsFromEnd(20)
            let sleepMode = readBitsFromEnd(1)

            var cctKelvin = cctValue * 10
            if cctHighFlag == 1 { cctKelvin += 10000 }

            return SidusLightStatus(
                commandType: commandType,
                intensity: intensity,
                isOn: sleepMode == 1,
                cctKelvin: cctKelvin,
                hue: nil,
                saturation: nil
            )

        case 1: // HSI
            let hue = readBitsFromEnd(9)
            let sat = readBitsFromEnd(7)
            let cctValue = readBitsFromEnd(8)
            _ = cctValue
            let gmValue = readBitsFromEnd(7)
            _ = gmValue
            let gmHigh = readBitsFromEnd(1)
            _ = gmHigh
            let gmFlag = readBitsFromEnd(1)
            _ = gmFlag
            let cctHighFlag = readBitsFromEnd(1)
            _ = cctHighFlag
            let autoPatchFlag = readBitsFromEnd(1)
            _ = autoPatchFlag
            // Skip reserved bits
            _ = readBitsFromEnd(18)
            let sleepMode = readBitsFromEnd(1)

            return SidusLightStatus(
                commandType: commandType,
                intensity: intensity,
                isOn: sleepMode == 1,
                cctKelvin: nil,
                hue: hue,
                saturation: sat
            )

        case 12: // Sleep
            // Skip all fields to get sleepMode
            // After intensity: cctValue(10), gmValue(7), gmHigh(1), gmFlag(1),
            // cctHighFlag(1), autoPatch(1), reserved(12), reserved(20), sleepMode(1)
            _ = readBitsFromEnd(10)
            _ = readBitsFromEnd(7)
            _ = readBitsFromEnd(1)
            _ = readBitsFromEnd(1)
            _ = readBitsFromEnd(1)
            _ = readBitsFromEnd(1)
            _ = readBitsFromEnd(12)
            _ = readBitsFromEnd(20)
            let sleepMode = readBitsFromEnd(1)

            return SidusLightStatus(
                commandType: commandType,
                intensity: intensity,
                isOn: sleepMode == 1,
                cctKelvin: nil,
                hue: nil,
                saturation: nil
            )

        default:
            return nil
        }
    }
}

// MARK: - Bit Packing Utilities (ported from BinaryKit.java)

/// Internal-access versions for use by BLEManager query
func toBinaryPublic(_ value: Int, width: Int) -> String {
    return toBinary(value, width: width)
}

func to10ByteArrayPublic(_ bitString: String) -> Data {
    return to10ByteArray(bitString)
}

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

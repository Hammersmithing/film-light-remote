# Film Light Remote - Development Procedure

## Overview

This document outlines the step-by-step procedure for reverse engineering the Aputure BLE protocol and implementing light control in the iOS app.

---

## Phase 1: Setup & Tools

### 1.1 Install Wireshark on Mac
```bash
brew install --cask wireshark
```
Wireshark is used to analyze BLE packet captures.

### 1.2 Prepare Capture Device

**Option A: Android Phone (Recommended)**
- Any Android phone with Bluetooth
- Enable Developer Options: Settings → About Phone → Tap "Build Number" 7 times
- Install ADB on Mac: `brew install android-platform-tools`

**Option B: nRF52840 Dongle (Better quality, costs ~$10)**
- Purchase: Nordic nRF52840 USB Dongle
- Install nRF Sniffer firmware
- More complex but captures all traffic passively

**Option C: Use Film Light Remote app itself**
- Once Apple signing works, use the Debug Log feature
- Connect to light and observe service/characteristic discovery
- Limited: only sees what our app does, not Sidus Link commands

### 1.3 Install Sidus Link
- Download "Sidus Link" from App Store (iOS) or Play Store (Android)
- Create account if required
- Verify it can connect to your STORM 80c

### 1.4 Complete Apple Developer Signing
- Status: **WAITING**
- Once verified, configure in Xcode → Signing & Capabilities

---

## Phase 2: BLE Packet Capture

### 2.1 Enable Android HCI Snoop Log
```
Settings → Developer Options → Enable Bluetooth HCI snoop log
```
Note: Location varies by Android version/manufacturer

### 2.2 Capture Session Plan

Perform each action slowly with 5-second pauses between changes:

| # | Action | Notes |
|---|--------|-------|
| 1 | Open Sidus Link, connect to light | Captures connection handshake |
| 2 | Power OFF | Capture off command |
| 3 | Power ON | Capture on command |
| 4 | Set intensity 0% | |
| 5 | Set intensity 25% | |
| 6 | Set intensity 50% | |
| 7 | Set intensity 75% | |
| 8 | Set intensity 100% | |
| 9 | Set CCT 2700K | Warmest |
| 10 | Set CCT 4000K | |
| 11 | Set CCT 5600K | Daylight |
| 12 | Set CCT 6500K | Coolest |
| 13 | Switch to HSI mode | |
| 14 | Set Hue 0° (Red) | |
| 15 | Set Hue 120° (Green) | |
| 16 | Set Hue 240° (Blue) | |
| 17 | Set Saturation 0% | |
| 18 | Set Saturation 100% | |
| 19 | Switch to Effects | |
| 20 | Select Lightning effect | |
| 21 | Select Fire effect | |
| 22 | Change effect speed | |
| 23 | Disconnect | |

### 2.3 Extract HCI Log
```bash
# Connect Android via USB
adb devices  # Verify connection

# Pull the log file (location varies)
adb pull /sdcard/btsnoop_hci.log ./captures/
# or
adb pull /data/misc/bluetooth/logs/btsnoop_hci.log ./captures/

# Disable snoop log after capture
```

---

## Phase 3: Protocol Analysis

### 3.1 Open in Wireshark
```bash
wireshark captures/btsnoop_hci.log
```

### 3.2 Apply BLE Filter
```
btatt or btle
```

### 3.3 Identify Key Information

**Find Service UUIDs:**
- Look for "Read By Group Type Response" packets
- Note all service UUIDs advertised by the light

**Find Characteristic UUIDs:**
- Look for "Read By Type Response" packets
- Note characteristics with Write or WriteNoResponse properties

**Find Command Patterns:**
- Filter: `btatt.opcode == 0x12` (Write Request) or `btatt.opcode == 0x52` (Write Command)
- Correlate timestamps with your action log
- Document byte patterns for each command

### 3.4 Document Protocol

Create `/docs/protocol.md` with findings:

```markdown
# Aputure STORM 80c BLE Protocol

## Service UUIDs
- Primary Service: `XXXX-XXXX-XXXX-XXXX`

## Characteristic UUIDs
- Control: `XXXX-XXXX-XXXX-XXXX` (Write)
- Status: `XXXX-XXXX-XXXX-XXXX` (Notify)

## Command Format
| Byte | Description |
|------|-------------|
| 0 | Command type |
| 1 | Sub-command |
| 2-N | Value |
| N+1 | Checksum (if any) |

## Commands

### Power
- ON: `XX XX XX`
- OFF: `XX XX XX`

### Intensity
- Format: `XX XX [0-100]`

### CCT
- Format: `XX XX [temp_high] [temp_low]`

... etc
```

---

## Phase 4: Implementation

### 4.1 Update BLEManager.swift

Update `AputureUUIDs` struct with discovered values:
```swift
struct AputureUUIDs {
    static let primaryService = CBUUID(string: "DISCOVERED-UUID")
    static let controlCharacteristic = CBUUID(string: "DISCOVERED-UUID")
    static let statusCharacteristic = CBUUID(string: "DISCOVERED-UUID")
}
```

### 4.2 Implement Commands

For each command type, implement the method:

```swift
func setIntensity(_ percent: Int) {
    let command = Data([0xXX, 0xXX, UInt8(percent)])
    sendCommand(command)
}
```

### 4.3 Implementation Order
1. Power on/off (simplest, verifies connection works)
2. Intensity (single value, easy to test)
3. CCT (two-byte value)
4. HSI (three values)
5. Effects (effect ID + speed)

---

## Phase 5: Testing

### 5.1 Prerequisites
- Apple signing complete
- iPhone connected to Mac
- STORM 80c powered on and nearby

### 5.2 Test Procedure
1. Build and run app on iPhone
2. Grant Bluetooth permissions
3. Scan and connect to light
4. Open Debug Log to monitor traffic
5. Test each control:
   - [ ] Power toggle
   - [ ] Intensity slider
   - [ ] CCT slider
   - [ ] HSI controls
   - [ ] Effects
6. Verify light responds correctly

### 5.3 Troubleshooting
- **No response:** Check characteristic UUID, verify write type (with/without response)
- **Wrong behavior:** Re-check byte order, value scaling
- **Disconnects:** May need to handle keep-alive packets

---

## Current Status

| Phase | Status | Notes |
|-------|--------|-------|
| Phase 1 | **IN PROGRESS** | Waiting on Apple signing |
| Phase 2 | Not started | Need capture device ready |
| Phase 3 | Not started | |
| Phase 4 | Not started | |
| Phase 5 | Not started | |

---

## Questions to Resolve

1. Do you have an Android phone available for packet capture?
2. Do you have the STORM 80c light available for testing?
3. Is Sidus Link currently working with your light?

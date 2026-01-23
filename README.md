# Film Light Remote

An iOS app to control Aputure/Amaran film lights via Bluetooth Low Energy, providing a streamlined alternative to the official Sidus Link app.

## Project Status

| Phase | Status |
|-------|--------|
| App UI Structure | Complete |
| BLE Connection | Complete |
| Protocol Discovery | Complete |
| Encryption Keys Extracted | Complete |
| Mesh Encryption Implementation | Complete |
| BLE Traffic Capture & Analysis | Complete |
| Light Control Commands | **Blocked** - See [Provisioning Issue](#critical-discovery-provisioning-issue) |

## Critical Discovery: Provisioning Issue

**Lights previously paired with Sidus Link use custom provisioned keys**, not the default "fast provisioning" keys extracted from the APK.

### The Problem

| Source | NID (Network ID) |
|--------|------------------|
| Our k2 calculation (fast provisioning keys) | `0x70` |
| Sidus Link captured traffic | `0x12` |
| Expected if keys matched | Same value |

When Sidus Link first connects to a light, it performs **full Bluetooth Mesh provisioning**, which:
1. Generates a new random network key
2. Encrypts and sends it to the light
3. Stores it in the app's encrypted preferences

This means **the default keys only work on unprovisioned (factory fresh) lights**.

### Solution: Factory Reset Required

To use this app, you must **factory reset your light** to remove Sidus Link's provisioning:

**Amaran 120C Reset:**
- Hold power button for 10-15 seconds until light blinks/resets
- Or check manual for specific reset procedure

**After reset:**
1. Do NOT re-add the light in Sidus Link
2. Test with this app first
3. The default fast provisioning keys should work

---

## Key Discovery: Bluetooth Mesh Encryption

**The lights use full Bluetooth Mesh encryption**, not simple BLE writes. Through APK decompilation and packet capture analysis, we've extracted the encryption keys and implemented the complete mesh protocol.

### Extracted Keys (from Sidus Link APK)

These are the **default "fast provisioning" keys** - they work on unprovisioned lights only:

| Key | Value | Notes |
|-----|-------|-------|
| Network Key | `7DD7364CD842AD18C17C74656C696E6B` | Last 6 bytes = "telink" |
| App Key | `63964771734FBD76E3B474656C696E6B` | Last 6 bytes = "telink" |
| IV Index | `0x12345678` | Default initialization vector |

### Derived Values (from k2/k4 functions)

| Parameter | Value | Description |
|-----------|-------|-------------|
| NID | `0x70` | Network ID (7 bits from k2) |
| AID | `0x37` | Application ID (6 bits from k4) |
| Encryption Key | `F6 1D 87 4A 6D DC B7 32 CC CD CF 93 0F 88 E9 8E` | From k2 |

See [docs/protocol.md](docs/protocol.md) for complete technical documentation.

---

## BLE Traffic Analysis

### Captured Sidus Link Behavior

Using Android's Bluetooth HCI snoop log, we captured and analyzed Sidus Link's communication:

**Provisioning Flow (first connection):**
```
Handle 0x0017 (Mesh Provisioning Data In - 0x2ADB):
  03 00 00           - Provisioning Invite
  03 02 00 00 00 00  - Provisioning Start
  03 03 [64 bytes]   - Public Key Exchange
  03 05 [16 bytes]   - Confirmation
  03 06 [16 bytes]   - Random
  03 07 [encrypted]  - Provisioning Data (contains network key)
```

**Control Commands (after provisioning):**
```
Handle 0x0020 (Mesh Proxy Data In - 0x2ADD):
  00 12 [encrypted network PDU]  - Type=0 (Network PDU), NID=0x12
  02 12 [encrypted config PDU]   - Type=2 (Proxy Configuration)
```

### BLE Characteristics Discovered

| Service | Characteristic | UUID | Purpose | Notes |
|---------|---------------|------|---------|-------|
| Mesh Proxy (0x1828) | Mesh Proxy Data In | 0x2ADD | Write mesh commands | Primary control path |
| Mesh Proxy (0x1828) | Mesh Proxy Data Out | 0x2ADE | Receive responses | Subscribe for notifications |
| Mesh Provisioning (0x7FDD) | Provisioning Data In | 0x2ADB | Provisioning writes | Used during setup |
| Mesh Provisioning (0x7FDD) | Provisioning Data Out | 0x2ADC | Provisioning responses | Subscribe for notifications |
| Sidus Control | Control | 0x2B12 | Direct Sidus commands | In service `00010203-...-1912` |
| Unknown (0xFF01) | Control | 0xFF02 | Legacy/simple control | **Causes disconnect on 0x00** |
| Unknown (0x7FD3) | Control | 0x7FCB | Alternative control | **Causes disconnect on 0x00** |

### Critical: Disconnect Triggers

**DO NOT send these bytes to FF02 or 7FCB:**
- `0x00` - Causes immediate BLE disconnect
- Telink vendor commands (`0xD0`, `0xD2`, etc.) - Also cause disconnect

The light expects **mesh-encrypted commands only** on the proper mesh proxy characteristics.

---

## Architecture

```
Application Layer (10-byte Sidus command)
         ↓
    [0x26 Sidus Opcode Prefix]
         ↓
Access Layer Encryption (AES-CCM with App Key)
         ↓
Lower Transport PDU (SEG=0, AKF=1, AID=0x37)
         ↓
Network Layer Encryption (AES-CCM with Encryption Key)
         ↓
Privacy Obfuscation (XOR with PECB using Privacy Key)
         ↓
Mesh Proxy PDU (Type=0x00 for Network PDU)
         ↓
Write to characteristic 0x2ADD
```

---

## Target Devices

| Device | Status | Notes |
|--------|--------|-------|
| Amaran 120C | Primary test device | Requires factory reset if previously paired |
| Aputure STORM series | Should work | Same protocol |
| Aputure LS C series | Should work | Same protocol |
| Amaran 100/200 series | Should work | Same protocol |

Devices advertise as:
- **"SLCK Light"** - With service 0x1828 (Mesh Proxy)
- **"ALAM"** - Amaran lights at distance

---

## Features

### Implemented
- BLE scanner with signal strength sorting
- Connection management with status feedback
- Debug log viewer for BLE traffic analysis
- Full Bluetooth Mesh encryption (k2, k4, AES-CCM)
- CCT Protocol (color temperature control)
- HSI Protocol (hue/saturation/intensity)
- Power on/off commands
- Control UI for CCT, HSI, RGBW, Effects modes
- Lighting presets (Daylight, Tungsten, etc.)
- Mesh beacon parsing (extracts NID from light responses)

### In Progress
- Factory reset detection
- Automatic provisioning with default keys
- Key storage for provisioned lights

### Blocked
- Light control on Sidus-provisioned devices (need factory reset)

---

## Project Structure

```
film-light-remote/
├── FilmLightRemote/
│   ├── Sources/
│   │   ├── App/
│   │   │   └── FilmLightRemoteApp.swift
│   │   ├── BLE/
│   │   │   ├── BLEManager.swift          # Core Bluetooth manager
│   │   │   ├── MeshCrypto.swift          # Bluetooth Mesh encryption
│   │   │   ├── SidusMeshConfig.swift     # Extracted keys & UUIDs
│   │   │   ├── SidusMeshManager.swift    # Alternative mesh manager
│   │   │   └── SidusProtocols.swift      # CCT/HSI command encoding
│   │   ├── Models/
│   │   │   └── LightState.swift
│   │   └── Views/
│   │       ├── ContentView.swift
│   │       ├── ScannerView.swift
│   │       ├── LightControlView.swift
│   │       └── DebugLogView.swift
│   └── Resources/
│       ├── Info.plist
│       └── FilmLightRemote.entitlements
├── docs/
│   └── protocol.md                       # Complete protocol documentation
├── analysis/
│   ├── sidus_link.apk                    # Original APK for reference
│   └── decompiled/                       # Decompiled source files
├── project.yml                           # XcodeGen configuration
└── README.md
```

---

## Getting Started

### Prerequisites
- macOS with Xcode 15.0+
- iOS 16.0+ device (BLE does not work in simulator)
- [Homebrew](https://brew.sh) (for XcodeGen)
- Apple Developer account (for device deployment)
- **Factory-reset Aputure/Amaran light** (not paired with Sidus Link)

### Build Instructions

1. Clone the repository:
   ```bash
   git clone https://github.com/Hammersmithing/film-light-remote.git
   cd film-light-remote
   ```

2. Generate Xcode project:
   ```bash
   brew install xcodegen  # if not already installed
   xcodegen generate
   ```

3. Open in Xcode:
   ```bash
   open FilmLightRemote.xcodeproj
   ```

4. Configure signing:
   - Select the FilmLightRemote target
   - Go to Signing & Capabilities
   - Select your Development Team

5. Build and run on a physical iOS device (Cmd+R)

### Dependencies

- **CryptoSwift** - For AES-CCM and AES-CMAC mesh encryption

---

## Protocol Documentation

See [docs/protocol.md](docs/protocol.md) for:
- Complete encryption key details
- Key derivation functions (k2, k4)
- Message encryption flow (9 steps)
- CCT/HSI command bit layouts
- BLE service/characteristic UUIDs
- Implementation notes

---

## Technical Details

### Bluetooth Mesh Implementation

The `MeshCrypto` class implements:
- **k2 function**: Derives NID, encryption key, privacy key from network key
- **k4 function**: Derives AID from application key
- **AES-CCM encryption**: For both access and network layers
- **Privacy obfuscation**: XOR with PECB for header protection
- **Mesh Proxy PDU construction**: Complete packet assembly
- **Beacon parsing**: Extracts NID from incoming mesh traffic

### Command Protocols

Commands are 10 bytes with checksum in byte 0:

**CCT Protocol (type=2):**
- Intensity: 0-1000 (0-100%)
- CCT: 320-560 (3200K-5600K)
- GM: 0-200 (green-magenta adjustment)

**HSI Protocol (type=1):**
- Intensity: 0-1000
- Hue: 0-360 degrees
- Saturation: 0-100%

**On/Off Protocol (type=0):**
- Byte 9: 0x01 = ON, 0x00 = OFF

### Mesh Proxy PDU Format

```
Byte 0: [SAR (2 bits)][Type (6 bits)]
  - SAR = 0x00 (complete message)
  - Type = 0x00 (Network PDU) or 0x02 (Proxy Config)

Byte 1: [IVI (1 bit)][NID (7 bits)]
  - IVI = IV Index bit 31
  - NID = Network ID from k2

Bytes 2-7: Obfuscated header (CTL/TTL, SEQ, SRC)
Bytes 8+: Encrypted network payload + 4-byte MIC
```

---

## Reverse Engineering Process

1. **APK Decompilation**: Used jadx to decompile Sidus Link APK
2. **Key Extraction**: Found default mesh keys in `FastProvisioningConfiguration.java`
3. **Protocol Analysis**: Decoded CCT/HSI commands from `CCTProtocol.java`, `HSIProtocol.java`
4. **Packet Capture**: Captured BLE traffic using Android btsnoop_hci.log
5. **Traffic Analysis**: Used tshark/Wireshark to decode mesh proxy PDUs
6. **NID Discovery**: Found provisioned lights use different NID (0x12) than default keys (0x70)
7. **Implementation**: Ported encryption to Swift using CryptoSwift

### Packet Capture Method

```bash
# On Android (Developer Options):
# 1. Enable "Bluetooth HCI snoop log"
# 2. Toggle Bluetooth off/on
# 3. Use Sidus Link app
# 4. Extract log:

adb bugreport bugreport.zip
unzip bugreport.zip -d bugreport_extract
# Find: bugreport_extract/FS/data/log/bt/btsnoop_hci.log

# Analyze with tshark:
tshark -r btsnoop_hci.log -Y "btatt.opcode == 0x52" -V
```

---

## Requirements

| Requirement | Version |
|-------------|---------|
| iOS | 16.0+ |
| Xcode | 15.0+ |
| Swift | 5.9+ |
| macOS | Sonoma 14.0+ |

---

## Troubleshooting

### Light doesn't respond to commands
1. **Check if light was paired with Sidus Link** - Factory reset required
2. **Verify NID matches** - Console should show `NID = 0x70` for default keys
3. **Check mesh proxy characteristic** - Must write to 0x2ADD, not FF02/7FCB

### BLE disconnects immediately
- Don't send `0x00` to FF02 or 7FCB
- Don't send Telink vendor commands to these characteristics
- Only use mesh-encrypted PDUs on 0x2ADD

### Light shows in scan but won't connect
- Move closer (signal strength should be > -70 dBm)
- Power cycle the light
- Check iOS Bluetooth settings

---

## Contributing

Contributions welcome! Especially:
- Testing with different Aputure/Amaran models
- Implementing mesh provisioning
- Protocol improvements
- Additional effect support

---

## License

MIT License - See [LICENSE](LICENSE) for details.

---

## Acknowledgments

- Telink Semiconductor for mesh SDK documentation
- Nordic Semiconductor for BLE tools
- The BLE reverse engineering community

---

**Disclaimer:** This project is not affiliated with or endorsed by Aputure, Sidus Link, or Telink. Use at your own risk. The extracted keys are default "fast provisioning" keys embedded in the official app - they only work on unprovisioned devices.

---

## Changelog

- **2026-01-24**: Discovered provisioning issue - lights paired with Sidus Link use custom keys (NID=0x12 vs expected 0x70). Factory reset required.
- **2026-01-24**: Captured and analyzed Sidus Link BLE traffic using Android HCI snoop log
- **2026-01-24**: Fixed disconnect issues with FF02/7FCB characteristics
- **2026-01-23**: Implemented full Bluetooth Mesh encryption (k2, k4, AES-CCM)
- **2026-01-23**: Added complete protocol documentation
- **2026-01-22**: Initial protocol discovery, extracted keys from APK

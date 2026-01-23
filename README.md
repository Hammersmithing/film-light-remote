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
| Light Control Commands | Testing |

## Key Discovery: Bluetooth Mesh Encryption

**The lights use full Bluetooth Mesh encryption**, not simple BLE writes. Through APK decompilation and packet capture analysis, we've extracted the encryption keys and implemented the complete mesh protocol.

### Extracted Keys (from Sidus Link APK)

| Key | Value | Notes |
|-----|-------|-------|
| Network Key | `7DD7364CD842AD18C17C74656C696E6B` | Last 6 bytes = "telink" |
| App Key | `63964771734FBD76E3B474656C696E6B` | Last 6 bytes = "telink" |
| IV Index | `0x12345678` | Default initialization vector |

See [docs/protocol.md](docs/protocol.md) for complete technical documentation.

## Architecture

```
Application Layer (10-byte Sidus command)
         ↓
Access Layer Encryption (AES-CCM with App Key)
         ↓
Lower Transport PDU (SEG=0, AKF=1, AID)
         ↓
Network Layer Encryption (AES-CCM with derived keys)
         ↓
Privacy Obfuscation (XOR with PECB)
         ↓
Mesh Proxy PDU (written to characteristic 0x2ADD)
```

## Target Devices

| Device | Status |
|--------|--------|
| Amaran 120C | Primary test device |
| Aputure STORM series | Should work (same protocol) |
| Aputure LS C series | Should work |
| Amaran 100/200 series | Should work |

Devices appear as "SLCK Light" or "ALAM" in BLE scans.

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

### In Testing
- Mesh-encrypted command delivery
- Device response handling

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

## Getting Started

### Prerequisites
- macOS with Xcode 15.0+
- iOS 16.0+ device (BLE does not work in simulator)
- [Homebrew](https://brew.sh) (for XcodeGen)
- Apple Developer account (for device deployment)

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

## Protocol Documentation

See [docs/protocol.md](docs/protocol.md) for:
- Complete encryption key details
- Key derivation functions (k2, k4)
- Message encryption flow (9 steps)
- CCT/HSI command bit layouts
- BLE service/characteristic UUIDs
- Implementation notes

## Technical Details

### Bluetooth Mesh Implementation

The `MeshCrypto` class implements:
- **k2 function**: Derives NID, encryption key, privacy key from network key
- **k4 function**: Derives AID from application key
- **AES-CCM encryption**: For both access and network layers
- **Privacy obfuscation**: XOR with PECB for header protection
- **Mesh Proxy PDU construction**: Complete packet assembly

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

### Key BLE Characteristics

| UUID | Description |
|------|-------------|
| 0x2ADD | Mesh Proxy Data In (write commands here) |
| 0x2ADE | Mesh Proxy Data Out (receive responses) |
| 0xFF02 | Alternative control characteristic |

## Reverse Engineering Process

1. **APK Decompilation**: Used jadx to decompile Sidus Link APK
2. **Key Extraction**: Found default mesh keys in `FastProvisioningConfiguration.java`
3. **Protocol Analysis**: Decoded CCT/HSI commands from `CCTProtocol.java`, `HSIProtocol.java`
4. **Packet Capture**: Captured BLE traffic using Android btsnoop_hci.log
5. **Mesh Analysis**: Confirmed full Bluetooth Mesh encryption in captured packets
6. **Implementation**: Ported encryption to Swift using CryptoSwift

## Requirements

| Requirement | Version |
|-------------|---------|
| iOS | 16.0+ |
| Xcode | 15.0+ |
| Swift | 5.9+ |
| macOS | Sonoma 14.0+ |

## Contributing

Contributions welcome! Especially:
- Testing with different Aputure/Amaran models
- Protocol improvements
- Additional effect support

## License

MIT License - See [LICENSE](LICENSE) for details.

## Acknowledgments

- Telink Semiconductor for mesh SDK documentation
- Nordic Semiconductor for BLE tools
- The BLE reverse engineering community

---

**Disclaimer:** This project is not affiliated with or endorsed by Aputure, Sidus Link, or Telink. Use at your own risk. The extracted keys are default "fast provisioning" keys embedded in the official app.

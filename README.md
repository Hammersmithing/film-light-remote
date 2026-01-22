# Film Light Remote

An iOS app to control Aputure film lights (STORM 80c, LS C series, MC, Amaran) via Bluetooth Low Energy, providing a streamlined alternative to the official Sidus Link app.

## Motivation

The official **Sidus Link** app for controlling Aputure lights has several limitations:
- Requires account creation and cloud connectivity
- Cluttered interface with features many users don't need
- Can be slow to connect and respond
- Limited customization options

**Film Light Remote** aims to provide:
- Direct BLE control with no cloud dependency
- Fast, responsive interface optimized for on-set use
- Simple controls focused on the essentials (intensity, color temperature, effects)
- Open protocol documentation for the community

## Project Status

| Phase | Status |
|-------|--------|
| App UI Structure | Complete |
| BLE Connection | Complete |
| Debug/Analysis Tools | Complete |
| Protocol Discovery | **In Progress** |
| Light Control Commands | Pending |

The app is fully functional for BLE scanning and connection. The next step is reverse engineering the Aputure BLE protocol by capturing traffic from the Sidus Link app.

## Target Devices

| Device | Priority | Status |
|--------|----------|--------|
| Aputure STORM 80c | Primary | Protocol TBD |
| Aputure LS C120d II | Secondary | Protocol TBD |
| Aputure LS C300d II | Secondary | Protocol TBD |
| Aputure MC | Secondary | Protocol TBD |
| Amaran 100/200 series | Tertiary | Protocol TBD |

Most Aputure/Amaran lights likely share a similar or identical BLE protocol.

## Features

### Implemented
- **BLE Scanner** - Discover nearby Bluetooth devices with signal strength indicators
- **Connection Management** - Connect/disconnect with status feedback
- **Debug Log** - Real-time view of all BLE traffic (services, characteristics, data)
- **Raw Command Input** - Send arbitrary hex commands for protocol testing
- **Control UI** - Full interface ready for CCT, HSI, RGBW, and Effects modes
- **Presets** - Quick access to common lighting setups (Daylight, Tungsten, etc.)

### Planned (after protocol discovery)
- [ ] Power on/off control
- [ ] Intensity adjustment (0-100%)
- [ ] CCT control (2700K-6500K)
- [ ] HSI mode (Hue 0-360, Saturation 0-100%)
- [ ] RGBW direct control
- [ ] Built-in effects (Lightning, Fire, TV Flicker, etc.)
- [ ] Custom preset saving
- [ ] Multi-light grouping
- [ ] Widget for quick access

## Project Structure

```
film-light-remote/
├── FilmLightRemote/
│   ├── Sources/
│   │   ├── App/
│   │   │   └── FilmLightRemoteApp.swift      # SwiftUI app entry point
│   │   ├── BLE/
│   │   │   └── BLEManager.swift              # Core Bluetooth manager
│   │   ├── Models/
│   │   │   └── LightState.swift              # Light state, modes, presets
│   │   └── Views/
│   │       ├── ContentView.swift             # Main navigation
│   │       ├── ScannerView.swift             # BLE device discovery
│   │       ├── LightControlView.swift        # CCT/HSI/RGB/Effects controls
│   │       └── DebugLogView.swift            # BLE traffic analyzer
│   └── Resources/
│       ├── Info.plist                        # Bluetooth permissions
│       └── FilmLightRemote.entitlements
├── project.yml                               # XcodeGen configuration
└── README.md
```

## Getting Started

### Prerequisites
- macOS with Xcode 15.0+
- iOS 16.0+ device (BLE does not work in simulator)
- [Homebrew](https://brew.sh) (for XcodeGen)

### Build Instructions

1. Clone the repository:
   ```bash
   git clone https://github.com/jahammersmith/film-light-remote.git
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

5. Build and run on a physical iOS device

### First Run

1. Launch the app and grant Bluetooth permissions when prompted
2. Tap the antenna icon to scan for devices
3. Your Aputure light should appear in the list (make sure it's powered on)
4. Tap to connect
5. Use the Debug Log (terminal icon) to observe BLE communication

## BLE Protocol Reverse Engineering

### Why Reverse Engineering?

Aputure does not publish their BLE protocol. To control the lights directly, we need to:
1. Capture BLE traffic between Sidus Link and the light
2. Analyze the packet structure
3. Identify commands for each function
4. Implement the protocol in our app

### Capture Methods

#### Method 1: Android HCI Snoop Log (Recommended)

1. On an Android device, enable Developer Options
2. Go to Developer Options → Enable Bluetooth HCI snoop log
3. Install Sidus Link, connect to your light
4. Perform various operations (change intensity, color temp, effects)
5. Disable the snoop log
6. Extract the log:
   ```bash
   adb pull /sdcard/btsnoop_hci.log
   ```
7. Open in Wireshark

#### Method 2: nRF Sniffer (Best Quality)

- Use Nordic nRF52840 dongle with nRF Sniffer firmware
- Captures all BLE traffic passively
- Better for analyzing connection setup

#### Method 3: Ubertooth One

- Open-source Bluetooth sniffer
- More complex setup but very capable

### Wireshark Analysis

Filter BLE traffic:
```
btatt or btle
```

Key things to identify:
1. **Service UUIDs** - Found during GATT discovery
2. **Characteristic UUIDs** - Control and status characteristics
3. **Write patterns** - Commands sent when changing settings
4. **Notification data** - Status updates from the light

### Protocol Documentation

Once discovered, protocol details will be documented in `/docs/protocol.md`:

```
Expected format (hypothetical):
┌──────┬──────────┬─────────┬──────────┐
│ CMD  │ SUBCMD   │ VALUE   │ CHECKSUM │
│ 1B   │ 1B       │ 1-4B    │ 1B       │
└──────┴──────────┴─────────┴──────────┘

Commands to discover:
- Power: ON/OFF
- Intensity: 0-100%
- CCT: 2700K-6500K
- HSI: H(0-360), S(0-100), I(0-100)
- Effects: ID + Speed
```

## Contributing

### Protocol Contributions Welcome!

If you have:
- Packet captures from Sidus Link
- Protocol documentation for any Aputure/Amaran light
- Working command sequences

Please open an issue or PR!

### Development

1. Fork the repository
2. Create a feature branch
3. Make changes
4. Run `xcodegen generate` if you modified project.yml
5. Test on a physical device
6. Submit a PR

## Technical Details

### Core Bluetooth Implementation

The `BLEManager` class handles:
- Central manager state monitoring
- Peripheral scanning with filtering
- Connection lifecycle
- Service/characteristic discovery
- Read/write/notify operations
- Debug logging

### Light State Model

`LightState` supports four modes:
- **CCT** - Color temperature (Kelvin)
- **HSI** - Hue, Saturation, Intensity
- **RGBW** - Direct color channel control
- **Effects** - Built-in lighting effects

### SwiftUI Architecture

- `@StateObject` for BLEManager (app-wide singleton)
- `@ObservedObject` for LightState (per-connection)
- `@EnvironmentObject` for dependency injection

## Requirements

| Requirement | Version |
|-------------|---------|
| iOS | 16.0+ |
| Xcode | 15.0+ |
| Swift | 5.9+ |
| macOS | Sonoma 14.0+ (for development) |

## License

MIT License - See [LICENSE](LICENSE) for details.

## Acknowledgments

- Aputure for making excellent film lights
- The BLE reverse engineering community
- Nordic Semiconductor for nRF tools

---

**Note:** This project is not affiliated with or endorsed by Aputure or Sidus Link. Use at your own risk.

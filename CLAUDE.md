# Film Light Remote - Development Rules

## Locked Effects (DO NOT MODIFY)

The following effect engines are **locked** and must NOT be edited without explicit user permission:

### FaultyBulbEngine
- **File:** `FilmLightRemote/Sources/Effects/FaultyBulbEngine.swift` (entire file is locked)
- **UI:** `FaultyBulbDetail` struct in `FilmLightRemote/Sources/Views/LightControlView.swift`
- **Status:** LOCKED
- **Reason:** Extensively tested and tuned. All parameters (flicker range, fault bias, recovery, warmth, transition, points, frequency, inverse) are finalized.

If a task requires changes to the faulty bulb engine or its UI, you MUST:
1. Tell the user that faulty bulb is locked
2. Ask the user to explicitly unlock it for editing
3. Only proceed after receiving explicit confirmation

This applies to:
- `FaultyBulbEngine.swift` (the entire file)
- The `FaultyBulbDetail` struct in LightControlView.swift
- The `startFaultyBulb()` and `stopFaultyBulb()` methods in BLEManager
- The `syncEngineParams()` and `sendColorNow()` methods in FaultyBulbDetail
- Any LightState properties prefixed with `faultyBulb`

## Isolated Feature Folders

Feature code is separated into dedicated folders so changes to BLEManager or Views can't accidentally modify them:

### Effects (`FilmLightRemote/Sources/Effects/`)
- `FaultyBulbEngine.swift` - LOCKED (see above)
- `PaparazziEngine.swift`
- `SoftwareEffectEngine.swift`

### Cues & Timelines (`FilmLightRemote/Sources/Cues/`)
- `CueModels.swift` — Cue, CueList, Timeline structs
- `CueEngine.swift` — cue execution logic
- `TimelineEngine.swift` — timeline execution logic
- `CuesView.swift` — cue list management UI
- `CueListDetailView.swift` — cue runner (GO button)
- `CueEditorView.swift` — single cue editor
- `CueLightEditorView.swift` — light state editor within a cue
- `TimelineView.swift` — timeline UI

### Groups (`FilmLightRemote/Sources/Groups/`)
- `GroupsView.swift` — group management UI
- `GroupSessionView.swift` — group control session

## Effect Engine Documentation

See `docs/effects-reference.md` for complete documentation of all effect engines including parameters, algorithms, and architecture.

## Build & Deploy

- **Build:** `xcodebuild -scheme FilmLightRemote -destination 'generic/platform=iOS' -derivedDataPath /tmp/flr-build -quiet build`
- **If running `xcodegen generate`**, you MUST backup and restore `Info.plist` — xcodegen overwrites it and strips custom keys (`UILaunchScreen`, `NSBonjourServices`, etc.). Use: `cp Info.plist /tmp/backup.plist && xcodegen generate && cp /tmp/backup.plist Info.plist`
- After building, always install AND launch on device
- Device ID: `1512439D-C8ED-4E37-B227-7EB5D6BBC4FF`
- Bundle ID: `com.aldenhammersmith.FilmLightRemote`

## ESP32 Firmware

- Source: `esp32-ble-bridge/`
- Flash: `source ~/esp/esp-idf/export.sh && cd esp32-ble-bridge && idf.py -p /dev/cu.usbserial-0001 flash` (must be in single shell command)

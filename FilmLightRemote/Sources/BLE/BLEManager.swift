import Foundation
import CoreBluetooth
import Combine

// MARK: - Mesh Service UUIDs (from Bluetooth Mesh spec + Sidus Link decompile)
struct MeshUUIDs {
    // Standard Bluetooth Mesh service UUIDs
    static let provisioningService = CBUUID(string: "1827")   // Unprovisioned devices
    static let proxyService        = CBUUID(string: "1828")   // Provisioned devices

    // Provisioning characteristics
    static let provisioningDataIn  = CBUUID(string: "2ADB")
    static let provisioningDataOut = CBUUID(string: "2ADC")

    // Proxy characteristics
    static let proxyDataIn         = CBUUID(string: "2ADD")
    static let proxyDataOut        = CBUUID(string: "2ADE")

    // Sidus/Aputure custom service & characteristic
    static let aputureControlService = CBUUID(string: "00010203-0405-0607-0809-0A0B0C0D1912")
    static let aputureControlChar    = CBUUID(string: "00010203-0405-0607-0809-0A0B0C0D2B12")

    // Sidus fast provisioning
    static let fastProvService     = CBUUID(string: "FF01")
    static let fastProvChar        = CBUUID(string: "FF02")

    // Accessories OTA
    static let accessoriesService  = CBUUID(string: "7FD3")
    static let accessoriesChar     = CBUUID(string: "7FCB")

    // Aputure manufacturer company ID
    static let aputureCompanyID: UInt16 = 529  // 0x0211
}

// MARK: - Connection State
enum BLEConnectionState: Equatable {
    case disconnected
    case scanning
    case connecting
    case discoveringServices
    case connected
    case ready
    case failed(String)
}

// MARK: - Light Provisioning State
enum LightMeshState: String {
    case unprovisioned  // Advertising 0x1827 — factory reset, ready to add
    case provisioned    // Advertising 0x1828 — already in a mesh network
}

// MARK: - Discovered Light
struct DiscoveredLight: Identifiable, Equatable {
    let id: UUID
    let peripheral: CBPeripheral
    let name: String
    var rssi: Int
    let meshState: LightMeshState
    let deviceUUID: UUID?        // Mesh device UUID (from unprovisioned beacon)
    let serviceData: Data?       // Raw service data from advertisement

    static func == (lhs: DiscoveredLight, rhs: DiscoveredLight) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - BLE Manager
class BLEManager: NSObject, ObservableObject {
    /// Bridge manager for WiFi-based ESP32 bridge. When connected, commands route through bridge.
    let bridgeManager = BridgeManager.shared

    // Published state
    @Published var connectionState: BLEConnectionState = .disconnected
    @Published var discoveredLights: [DiscoveredLight] = []
    @Published var connectedLight: DiscoveredLight?
    @Published var lastReceivedData: Data?
    @Published var isBluetoothAvailable = false
    @Published var lastLightStatus: SidusLightStatus?

    /// When true, incoming light status notifications are ignored.
    /// Used during cue light editing to prevent the proxy's own state from
    /// overwriting the user's slider values.
    var suppressStatusUpdates = false

    // Debug/Analysis mode - logs all BLE traffic
    @Published var debugMode = true
    @Published var debugLog: [String] = []

    // Post-provisioning configuration manager
    let configManager = MeshConfigManager()

    /// Unicast address of the currently targeted light (set when opening a saved light)
    var targetUnicastAddress: UInt16 = 0x0002

    /// Transaction ID counter for mesh model commands
    private var meshTID: UInt8 = 0
    private func nextTID() -> UInt8 {
        meshTID &+= 1
        return meshTID
    }

    // Core Bluetooth
    private(set) var centralManager: CBCentralManager!
    private(set) var connectedPeripheral: CBPeripheral?
    private var controlCharacteristic: CBCharacteristic?
    private var statusCharacteristic: CBCharacteristic?
    private var meshProxyIn: CBCharacteristic?  // 2ADD
    private var char7FCB: CBCharacteristic?     // Alternative control
    private var sidusControl: CBCharacteristic? // 2B12 - Direct Sidus control
    private var provisioningDataIn: CBCharacteristic?  // 2ADB
    private var provisioningDataOut: CBCharacteristic? // 2ADC

    // MARK: - Multi-Peripheral Connection Registry

    /// A snapshot of a peripheral + its mesh proxy characteristic, for concurrent writes.
    struct PeripheralConnection {
        let peripheral: CBPeripheral
        let meshProxyIn: CBCharacteristic
    }

    /// All active peripheral connections — keyed by peripheral identifier.
    private(set) var peripheralConnections: [UUID: PeripheralConnection] = [:]

    /// Whether the connected device has provisioning service available
    var isProvisioningAvailable: Bool {
        return provisioningDataIn != nil && provisioningDataOut != nil
    }

    // Scanning
    private var scanTimer: Timer?

    // (state polling removed — bridge handles state)

    override init() {
        super.init()
        // Clear old debug log file
        if let fileURL = Self.debugLogFileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        centralManager = CBCentralManager(delegate: self, queue: .main)
        MeshCrypto.logCallback = { [weak self] msg in
            self?.log(msg)
        }
    }

    // MARK: - Public Methods

    /// Scan mode: true = show all BLE devices (debug), false = mesh lights only
    @Published var scanAllDevices = false

    func startScanning() {
        guard centralManager.state == .poweredOn else {
            log("Cannot scan - Bluetooth not powered on")
            return
        }

        discoveredLights.removeAll()
        connectionState = .scanning

        if scanAllDevices {
            log("Starting BLE scan (ALL DEVICES - debug mode)...")
            centralManager.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
        } else {
            // Scan for ONLY Bluetooth Mesh devices:
            // 0x1827 = unprovisioned (factory reset lights ready to add)
            // 0x1828 = provisioned (lights already in a mesh network)
            log("Scanning for Mesh lights (0x1827 unprovisioned + 0x1828 provisioned)...")
            centralManager.scanForPeripherals(
                withServices: [MeshUUIDs.provisioningService, MeshUUIDs.proxyService],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
        }

        // Stop scanning after 15 seconds
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: false) { [weak self] _ in
            self?.stopScanning()
        }
    }

    func stopScanning() {
        centralManager.stopScan()
        scanTimer?.invalidate()
        scanTimer = nil

        if connectionState == .scanning {
            connectionState = .disconnected
        }
        log("Stopped scanning")
    }

    func connect(to light: DiscoveredLight) {
        stopScanning()
        connectionState = .connecting
        log("Connecting to \(light.name)...")
        centralManager.connect(light.peripheral, options: nil)
    }

    /// Reconnect to a previously known peripheral by its CoreBluetooth identifier.
    /// Uses retrievePeripherals first; falls back to scanning if not cached.
    /// When `keepExisting` is true, existing connections are preserved (for multi-light cues).
    func connectToKnownPeripheral(identifier: UUID, keepExisting: Bool = false) {
        guard centralManager.state == .poweredOn else {
            log("Cannot reconnect - Bluetooth not powered on")
            connectionState = .failed("Bluetooth not available")
            return
        }

        // If already connected to this peripheral (e.g. effect running in background), reuse
        if let existing = connectedPeripheral, existing.identifier == identifier,
           meshProxyIn != nil {
            log("Already connected to \(existing.name ?? identifier.uuidString) — reusing")
            connectionState = .ready
            return
        }

        // Also check the multi-peripheral registry
        if let registered = peripheralConnections[identifier] {
            log("Already in peripheral registry \(registered.peripheral.name ?? identifier.uuidString) — promoting to primary")
            connectedPeripheral = registered.peripheral
            meshProxyIn = registered.meshProxyIn
            connectionState = .ready
            return
        }

        // If connecting to a different peripheral in single-light mode, clean up the old one
        // (keepExisting = true preserves connections for multi-light cues)
        if !keepExisting, connectedPeripheral?.identifier != identifier {
            // Explicitly disconnect the old peripheral and remove from registry
            if let old = connectedPeripheral {
                peripheralConnections.removeValue(forKey: old.identifier)
                centralManager.cancelPeripheralConnection(old)
            }
        }

        let peripherals = centralManager.retrievePeripherals(withIdentifiers: [identifier])
        if let peripheral = peripherals.first {
            log("Retrieved known peripheral \(peripheral.name ?? identifier.uuidString)")
            connectionState = .connecting
            peripheral.delegate = self
            connectedPeripheral = peripheral
            centralManager.connect(peripheral, options: nil)
        } else {
            // Peripheral not cached — try retrieving connected peripherals with proxy service
            let connected = centralManager.retrieveConnectedPeripherals(withServices: [MeshUUIDs.proxyService])
            if let match = connected.first(where: { $0.identifier == identifier }) {
                log("Found already-connected peripheral \(match.name ?? identifier.uuidString)")
                connectionState = .connecting
                match.delegate = self
                connectedPeripheral = match
                centralManager.connect(match, options: nil)
            } else {
                // Fall back to scanning for proxy service
                log("Peripheral not cached — scanning for proxy devices...")
                pendingReconnectIdentifier = identifier
                connectionState = .scanning
                centralManager.scanForPeripherals(
                    withServices: [MeshUUIDs.proxyService],
                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
                )
                scanTimer?.invalidate()
                scanTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: false) { [weak self] _ in
                    self?.stopScanning()
                    if self?.connectionState == .scanning {
                        self?.connectionState = .failed("Light not found")
                    }
                    self?.pendingReconnectIdentifier = nil
                }
            }
        }
    }

    /// Identifier of a peripheral we're trying to reconnect to via scan fallback
    private(set) var pendingReconnectIdentifier: UUID?

    /// Update the lastConnected timestamp for a saved light
    func updateLastConnected(for peripheralIdentifier: UUID) {
        var lights = KeyStorage.shared.savedLights
        if let idx = lights.firstIndex(where: { $0.peripheralIdentifier == peripheralIdentifier }) {
            lights[idx].lastConnected = Date()
            KeyStorage.shared.savedLights = lights
        }
    }

    func disconnect() {
        if let peripheral = connectedPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        cleanup()
    }

    // MARK: - Light Control Commands (dual-path: bridge when available, direct BLE otherwise)

    /// Current light state (stored for combined commands like power on/off)
    private(set) var currentIntensity: Int = 50
    private(set) var currentMode: String = "cct"
    private(set) var currentHue: Int = 0
    private(set) var currentSaturation: Int = 100
    private(set) var currentHSICCT: Int = 5600

    /// Whether commands should go through the bridge (true) or direct BLE (false).
    var useBridge: Bool { bridgeManager.isConnected }

    /// Sync BLEManager state from a loaded LightState (call when opening a light session)
    func syncState(from lightState: LightState) {
        currentIntensity = Int(lightState.intensity)
        currentCCT = Int(lightState.cctKelvin)
        currentMode = lightState.mode == .hsi ? "hsi" : "cct"
        currentHue = Int(lightState.hue)
        currentSaturation = Int(lightState.saturation)
    }

    // MARK: - Direct BLE Send Helper

    /// Send a Sidus protocol payload directly via BLE mesh proxy (no bridge).
    private func sendViaBLE(_ protocol: SidusProtocol, dst: UInt16) {
        guard let peripheral = connectedPeripheral, let char = meshProxyIn else {
            log("sendViaBLE: no peripheral/proxy char — cannot send")
            return
        }
        let payload = `protocol`.getSendData()
        var accessMessage: [UInt8] = [0x26]
        accessMessage.append(contentsOf: payload)
        if let pdu = MeshCrypto.createStandardMeshPDU(accessMessage: accessMessage, dst: dst) {
            peripheral.writeValue(pdu, for: char, type: .withoutResponse)
        }
    }

    func setIntensity(_ percent: Double) {
        currentIntensity = Int(percent)
        currentMode = "cct"
        if useBridge {
            bridgeManager.setCCT(unicast: targetUnicastAddress, intensity: percent, cctKelvin: currentCCT, sleepMode: 1)
        } else {
            let proto = CCTProtocol(intensityPercent: percent, cctKelvin: currentCCT)
            sendViaBLE(proto, dst: targetUnicastAddress)
        }
    }

    /// Set CCT with explicit values and sleepMode control for instant on/off transitions.
    func setCCTWithSleep(intensity percent: Double, cctKelvin: Int, sleepMode: Int, targetAddress: UInt16? = nil) {
        let dst = targetAddress ?? targetUnicastAddress
        if useBridge {
            bridgeManager.setCCT(unicast: dst, intensity: percent, cctKelvin: cctKelvin, sleepMode: sleepMode)
        } else {
            var proto = CCTProtocol(intensityPercent: percent, cctKelvin: cctKelvin)
            proto.sleepMode = sleepMode
            sendViaBLE(proto, dst: dst)
        }
    }

    /// Set HSI with explicit values and sleepMode control for instant on/off transitions.
    func setHSIWithSleep(intensity percent: Double, hue: Int, saturation: Int, cctKelvin: Int = 5600, sleepMode: Int, targetAddress: UInt16? = nil) {
        let dst = targetAddress ?? targetUnicastAddress
        if useBridge {
            bridgeManager.setHSI(unicast: dst, intensity: percent, hue: hue, saturation: saturation, cctKelvin: cctKelvin, sleepMode: sleepMode)
        } else {
            var proto = HSIProtocol(intensityPercent: percent, hue: hue, saturationPercent: Double(saturation), cctKelvin: cctKelvin)
            proto.sleepMode = sleepMode
            sendViaBLE(proto, dst: dst)
        }
    }

    /// Current CCT value for combined commands
    private var currentCCT: Int = 5600

    func setCCT(_ kelvin: Int) {
        currentCCT = kelvin
        currentMode = "cct"
        if useBridge {
            bridgeManager.setCCT(unicast: targetUnicastAddress, intensity: Double(currentIntensity), cctKelvin: kelvin, sleepMode: 1)
        } else {
            let proto = CCTProtocol(intensityPercent: Double(currentIntensity), cctKelvin: kelvin)
            sendViaBLE(proto, dst: targetUnicastAddress)
        }
    }

    func setRGB(red: Int, green: Int, blue: Int) {
        // Convert RGB to HSI and send
        let (h, s, i) = rgbToHSI(red: red, green: green, blue: blue)
        setHSI(hue: h, saturation: s, intensity: i)
    }

    func setHSI(hue: Int, saturation: Int, intensity: Int, cctKelvin: Int = 5600) {
        currentMode = "hsi"
        currentHue = hue
        currentSaturation = saturation
        currentIntensity = intensity
        currentHSICCT = cctKelvin
        if useBridge {
            bridgeManager.setHSI(unicast: targetUnicastAddress, intensity: Double(intensity), hue: hue, saturation: saturation, cctKelvin: cctKelvin, sleepMode: 1)
        } else {
            let proto = HSIProtocol(intensityPercent: Double(intensity), hue: hue, saturationPercent: Double(saturation), cctKelvin: cctKelvin)
            sendViaBLE(proto, dst: targetUnicastAddress)
        }
    }

    func setPowerOn(_ on: Bool) {
        let sleepMode = on ? 1 : 0
        let intensity = on ? max(currentIntensity, 10) : 0
        if useBridge {
            if currentMode == "hsi" {
                bridgeManager.setHSI(unicast: targetUnicastAddress, intensity: Double(intensity), hue: currentHue, saturation: currentSaturation, cctKelvin: currentHSICCT, sleepMode: sleepMode)
            } else {
                bridgeManager.setCCT(unicast: targetUnicastAddress, intensity: Double(intensity), cctKelvin: currentCCT, sleepMode: sleepMode)
            }
        } else {
            if currentMode == "hsi" {
                var proto = HSIProtocol(intensityPercent: Double(intensity), hue: currentHue, saturationPercent: Double(currentSaturation), cctKelvin: currentHSICCT)
                proto.sleepMode = sleepMode
                sendViaBLE(proto, dst: targetUnicastAddress)
            } else {
                var proto = CCTProtocol(intensityPercent: Double(intensity), cctKelvin: currentCCT)
                proto.sleepMode = sleepMode
                sendViaBLE(proto, dst: targetUnicastAddress)
            }
        }
    }

    func setEffect(effectType: Int, intensityPercent: Double, frq: Int, cctKelvin: Int = 5600, copCarColor: Int = 0, effectMode: Int = 0, hue: Int = 0, saturation: Int = 100, targetAddress: UInt16? = nil) {
        currentMode = "effects"
        let dst = targetAddress ?? targetUnicastAddress
        if useBridge {
            bridgeManager.setEffect(unicast: dst, effectType: effectType, intensity: intensityPercent, frq: frq, cctKelvin: cctKelvin, copCarColor: copCarColor, effectMode: effectMode, hue: hue, saturation: saturation)
        } else {
            // Direct BLE: send the hardware effect protocol
            var proto = SidusEffectProtocol(effectType: effectType, intensityPercent: intensityPercent, frq: frq, cctKelvin: cctKelvin)
            proto.color = copCarColor
            proto.effectMode = effectMode
            proto.hue = hue
            proto.sat = saturation
            sendViaBLE(proto, dst: dst)
        }
    }

    /// Send sleep command for instant on/off.
    func sendSleep(_ on: Bool, targetAddress: UInt16? = nil) {
        let dst = targetAddress ?? targetUnicastAddress
        if useBridge {
            bridgeManager.sendSleep(unicast: dst, on: on)
        } else {
            let proto = SleepProtocol(on: on)
            sendViaBLE(proto, dst: dst)
        }
    }

    func stopEffect() {
        if useBridge {
            bridgeManager.stopEffect(unicast: targetUnicastAddress)
            log("stopEffect() via bridge for 0x\(String(format: "%04X", targetUnicastAddress))")
        } else {
            // Send effect-off (effectType 15) via direct BLE
            let proto = SidusEffectProtocol(effectType: 15)
            sendViaBLE(proto, dst: targetUnicastAddress)
            log("stopEffect() via direct BLE for 0x\(String(format: "%04X", targetUnicastAddress))")
        }
    }

    // MARK: - Software Effect Commands (bridge-only; direct BLE sends base color instead)

    /// Start a faulty bulb effect on the bridge. In direct BLE mode, no-op (base color already set).
    func startFaultyBulb(lightState: LightState) {
        guard useBridge else {
            log("startFaultyBulb: software effects require bridge — sending base color only")
            return
        }
        let params = BridgeManager.effectParams(from: lightState, effect: .faultyBulb)
        bridgeManager.startSoftwareEffect(unicast: targetUnicastAddress, engine: "faultyBulb", params: params)
        log("Faulty bulb engine started on bridge for 0x\(String(format: "%04X", targetUnicastAddress))")
    }

    /// Stop faulty bulb effect for a specific light, or current target.
    func stopFaultyBulb(forAddress address: UInt16? = nil) {
        guard useBridge else { return }
        bridgeManager.stopEffect(unicast: address ?? targetUnicastAddress)
    }

    /// Start a paparazzi effect on the bridge. In direct BLE mode, sends hardware effect instead.
    func startPaparazzi(lightState: LightState) {
        if useBridge {
            let params = BridgeManager.effectParams(from: lightState, effect: .paparazzi)
            bridgeManager.startSoftwareEffect(unicast: targetUnicastAddress, engine: "paparazzi", params: params)
            log("Paparazzi engine started on bridge for 0x\(String(format: "%04X", targetUnicastAddress))")
        } else {
            // Fall back to hardware paparazzi effect
            setEffect(effectType: LightEffect.paparazzi.rawValue, intensityPercent: lightState.intensity, frq: Int(lightState.effectFrequency), cctKelvin: Int(lightState.cctKelvin))
            log("Paparazzi via hardware effect (no bridge) for 0x\(String(format: "%04X", targetUnicastAddress))")
        }
    }

    /// Start a software effect on the bridge. In direct BLE mode, sends hardware effect if possible.
    func startSoftwareEffect(lightState: LightState) {
        let effect = lightState.selectedEffect
        if useBridge {
            let params = BridgeManager.effectParams(from: lightState, effect: effect)
            bridgeManager.startSoftwareEffect(unicast: targetUnicastAddress, engine: BridgeManager.engineName(for: effect), params: params)
            log("Software effect engine started on bridge: \(effect) for 0x\(String(format: "%04X", targetUnicastAddress))")
        } else {
            // Fall back to hardware effect via direct BLE
            setEffect(effectType: effect.rawValue, intensityPercent: lightState.intensity, frq: Int(lightState.effectFrequency), cctKelvin: Int(lightState.cctKelvin), hue: Int(lightState.hue), saturation: Int(lightState.saturation))
            log("Software effect \(effect) sent as hardware effect (no bridge) for 0x\(String(format: "%04X", targetUnicastAddress))")
        }
    }

    /// Convert RGB to HSI
    private func rgbToHSI(red: Int, green: Int, blue: Int) -> (hue: Int, saturation: Int, intensity: Int) {
        let r = Double(red) / 255.0
        let g = Double(green) / 255.0
        let b = Double(blue) / 255.0

        let minVal = min(r, g, b)
        let maxVal = max(r, g, b)
        let delta = maxVal - minVal

        // Intensity
        let i = (r + g + b) / 3.0

        // Saturation
        let s: Double
        if i == 0 {
            s = 0
        } else {
            s = 1 - (minVal / i)
        }

        // Hue
        var h: Double = 0
        if delta != 0 {
            if maxVal == r {
                h = 60 * fmod((g - b) / delta, 6)
            } else if maxVal == g {
                h = 60 * ((b - r) / delta + 2)
            } else {
                h = 60 * ((r - g) / delta + 4)
            }
        }
        if h < 0 { h += 360 }

        return (Int(h), Int(s * 100), Int(i * 100))
    }

    // (State polling removed — bridge handles state)

    // MARK: - Proxy Filter Setup

    /// Send Set Filter Type (blacklist) to the proxy so it accepts all mesh PDUs.
    /// Without this, the proxy's default empty whitelist drops everything.
    private func sendProxyFilterSetup(proxyIn: CBCharacteristic) {
        guard let peripheral = connectedPeripheral else { return }

        guard let filterPDU = MeshCrypto.createProxyFilterSetup() else {
            log("Failed to create proxy filter setup PDU")
            return
        }

        peripheral.writeValue(filterPDU, for: proxyIn, type: .withoutResponse)
        log("Sent proxy filter setup (Set Filter Type = blacklist/accept all)")
    }

    // MARK: - Post-Provisioning Configuration

    private func runPostProvisioningConfig(proxyIn: CBCharacteristic) {
        let storage = KeyStorage.shared
        let deviceAddress = targetUnicastAddress

        guard let deviceKey = storage.getDeviceKey(forAddress: deviceAddress) else {
            log("No device key for address 0x\(String(format: "%04X", deviceAddress)) — skipping config, marking ready")
            connectionState = .ready
            return
        }

        guard let peripheral = connectedPeripheral else { return }

        log("Running post-provisioning config for device 0x\(String(format: "%04X", deviceAddress))...")

        configManager.configure(
            peripheral: peripheral,
            proxyDataIn: proxyIn,
            deviceAddress: deviceAddress,
            deviceKey: deviceKey
        ) { [weak self] success in
            if success {
                self?.log("Config complete — light should now respond to commands!")
            } else {
                self?.log("Config failed — commands may not work")
            }
            self?.connectionState = .ready
        }
    }

    // MARK: - Private Methods

    private func cleanup() {
        connectedPeripheral = nil
        connectedLight = nil
        controlCharacteristic = nil
        statusCharacteristic = nil
        meshProxyIn = nil
        char7FCB = nil
        sidusControl = nil
        provisioningDataIn = nil
        provisioningDataOut = nil
        connectionState = .disconnected
    }

    /// URL of the debug log file in the app's Documents directory
    static var debugLogFileURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("debug_log.txt")
    }

    func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let entry = "[\(timestamp)] \(message)"
        print(entry)

        // Write to file for remote retrieval
        if let fileURL = Self.debugLogFileURL {
            let line = entry + "\n"
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    if let handle = try? FileHandle(forWritingTo: fileURL) {
                        handle.seekToEndOfFile()
                        handle.write(data)
                        handle.closeFile()
                    }
                } else {
                    try? data.write(to: fileURL)
                }
            }
        }

        if debugMode {
            DispatchQueue.main.async {
                self.debugLog.append(entry)
                // Keep log size manageable
                if self.debugLog.count > 500 {
                    self.debugLog.removeFirst(100)
                }
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate
extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            isBluetoothAvailable = true
            log("Bluetooth powered on")
        case .poweredOff:
            isBluetoothAvailable = false
            log("Bluetooth powered off")
            cleanup()
        case .unauthorized:
            isBluetoothAvailable = false
            log("Bluetooth unauthorized - check permissions")
        case .unsupported:
            isBluetoothAvailable = false
            log("Bluetooth unsupported on this device")
        case .resetting:
            log("Bluetooth resetting...")
        case .unknown:
            log("Bluetooth state unknown")
        @unknown default:
            log("Unknown Bluetooth state")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                       advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "Unknown"
        let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let serviceDataMap = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]
        let mfgData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data

        // Determine mesh state from advertised service UUIDs
        let isUnprovisioned = serviceUUIDs.contains(MeshUUIDs.provisioningService)
        let isProvisioned = serviceUUIDs.contains(MeshUUIDs.proxyService)
        let isMeshDevice = isUnprovisioned || isProvisioned

        // In debug mode, log everything
        if debugMode {
            var adData = ""
            if !serviceUUIDs.isEmpty { adData += "Services: \(serviceUUIDs) " }
            if !serviceDataMap.isEmpty {
                for (uuid, data) in serviceDataMap {
                    adData += "SvcData[\(uuid)]: \(data.hexString) "
                }
            }
            if let mfg = mfgData {
                adData += "MfgData: \(mfg.hexString) "
                // Check for Aputure company ID (529 = 0x0211, little-endian in BLE)
                if mfg.count >= 2 {
                    let companyID = UInt16(mfg[0]) | (UInt16(mfg[1]) << 8)
                    if companyID == MeshUUIDs.aputureCompanyID {
                        adData += "(Aputure!) "
                    }
                }
            }
            if isMeshDevice {
                adData += isUnprovisioned ? "[UNPROVISIONED] " : "[PROVISIONED] "
            }
            log("Discovered: \(name) (RSSI: \(RSSI)) \(adData)")
        }

        // If scanning all devices in debug mode, show everything
        // Otherwise only show mesh devices
        guard isMeshDevice || scanAllDevices else { return }

        let meshState: LightMeshState = isUnprovisioned ? .unprovisioned : .provisioned

        // Parse device UUID from unprovisioned beacon service data
        // Service data for 0x1827 contains: [16-byte device UUID] [2-byte OOB info]
        var deviceUUID: UUID? = nil
        var svcData: Data? = nil

        if isUnprovisioned, let provData = serviceDataMap[MeshUUIDs.provisioningService] {
            svcData = provData
            if provData.count >= 16 {
                let uuidBytes = provData.prefix(16)
                // Convert 16 bytes to UUID
                let uuidString = uuidBytes.map { String(format: "%02x", $0) }.joined()
                let formatted = "\(uuidString.prefix(8))-\(uuidString.dropFirst(8).prefix(4))-\(uuidString.dropFirst(12).prefix(4))-\(uuidString.dropFirst(16).prefix(4))-\(uuidString.dropFirst(20))"
                deviceUUID = UUID(uuidString: formatted)
                log("  Mesh Device UUID: \(formatted)")
            }
        }

        if isProvisioned, let proxyData = serviceDataMap[MeshUUIDs.proxyService] {
            svcData = proxyData
            if proxyData.count >= 1 {
                let advType = proxyData[0]
                let typeDesc: String
                switch advType {
                case 0: typeDesc = "Network ID"
                case 1: typeDesc = "Node Identity"
                case 2: typeDesc = "Private Network ID"
                case 3: typeDesc = "Private Node Identity"
                default: typeDesc = "Unknown (\(advType))"
                }
                log("  Proxy advertisement type: \(typeDesc)")
                if proxyData.count >= 9 {
                    let networkID = proxyData[1..<9]
                    log("  Network ID: \(Data(networkID).hexString)")
                }
            }
        }

        // Build the discovered light
        let displayName: String
        if name == "Unknown" {
            // Try to build a name from mesh state
            displayName = meshState == .unprovisioned ? "Mesh Light (new)" : "Mesh Light (provisioned)"
        } else {
            displayName = name
        }

        let light = DiscoveredLight(
            id: peripheral.identifier,
            peripheral: peripheral,
            name: displayName,
            rssi: RSSI.intValue,
            meshState: meshState,
            deviceUUID: deviceUUID,
            serviceData: svcData
        )

        if let existingIndex = discoveredLights.firstIndex(where: { $0.id == light.id }) {
            // Update RSSI for already-discovered device
            discoveredLights[existingIndex] = light
        } else {
            discoveredLights.append(light)
            log("Found \(meshState.rawValue) light: \(displayName)")
        }

        // Auto-connect if this is the peripheral we're trying to reconnect to
        if let pendingID = pendingReconnectIdentifier, peripheral.identifier == pendingID {
            pendingReconnectIdentifier = nil
            connect(to: light)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("Connected to \(peripheral.name ?? "Unknown")")
        connectedPeripheral = peripheral
        peripheral.delegate = self
        connectionState = .discoveringServices
        updateLastConnected(for: peripheral.identifier)

        // Discover all services initially for analysis
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("Failed to connect: \(error?.localizedDescription ?? "Unknown error")")
        connectionState = .failed(error?.localizedDescription ?? "Connection failed")
        cleanup()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("Disconnected from \(peripheral.name ?? "Unknown")")

        // Remove from the multi-peripheral registry
        peripheralConnections.removeValue(forKey: peripheral.identifier)

        // Only full cleanup if the disconnected peripheral was the primary one
        if peripheral.identifier == connectedPeripheral?.identifier {
            cleanup()
        }
    }
}

// MARK: - CBPeripheralDelegate
extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            log("Service discovery error: \(error.localizedDescription)")
            return
        }

        guard let services = peripheral.services else {
            log("No services found")
            return
        }

        log("Discovered \(services.count) services:")
        for service in services {
            log("  Service: \(service.uuid)")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            log("Characteristic discovery error: \(error.localizedDescription)")
            return
        }

        guard let characteristics = service.characteristics else {
            log("No characteristics found for service \(service.uuid)")
            return
        }

        log("Service \(service.uuid) characteristics:")
        for characteristic in characteristics {
            var properties: [String] = []
            if characteristic.properties.contains(.read) { properties.append("read") }
            if characteristic.properties.contains(.write) { properties.append("write") }
            if characteristic.properties.contains(.writeWithoutResponse) { properties.append("writeNoResp") }
            if characteristic.properties.contains(.notify) { properties.append("notify") }
            if characteristic.properties.contains(.indicate) { properties.append("indicate") }

            log("  Char: \(characteristic.uuid) [\(properties.joined(separator: ", "))]")

            // Subscribe to notifications for analysis
            if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: characteristic)
                log("    Subscribed to notifications")
            }

            // Read initial value if readable
            if characteristic.properties.contains(.read) {
                peripheral.readValue(for: characteristic)
            }

            // Store known characteristics
            // Check for various Aputure/Sidus characteristic patterns
            let uuidString = characteristic.uuid.uuidString.uppercased()
            let isWritable = characteristic.properties.contains(.write) || characteristic.properties.contains(.writeWithoutResponse)

            // Log all writable characteristics for debugging
            if isWritable {
                log("    Writable: \(characteristic.uuid)")
            }

            // Priority 1: FF02 in service FF01 - simple control characteristic for SLCK devices
            if uuidString == "FF02" && isWritable {
                controlCharacteristic = characteristic
                log("    >>> Using FF02 as control characteristic!")
            }

            // Priority 2: 7FCB characteristic
            if uuidString == "7FCB" && isWritable && controlCharacteristic == nil {
                controlCharacteristic = characteristic
                log("    >>> Using 7FCB as control characteristic!")
            }

            // Priority 3: Sidus/Aputure custom control characteristic
            if characteristic.uuid == MeshUUIDs.aputureControlChar && isWritable {
                sidusControl = characteristic
                log("    >>> Found Sidus control characteristic (2B12)!")
            }

            // Priority 4: Mesh Proxy Data In (2ADD) - this is the PRIMARY for mesh commands
            if uuidString == "2ADD" {
                meshProxyIn = characteristic
                log("    >>> Found Mesh Proxy Data In (2ADD)! Properties: \(characteristic.properties.rawValue)")
                // 2ADD may only support writeWithoutResponse
                // Store in multi-peripheral registry
                peripheralConnections[peripheral.identifier] = PeripheralConnection(
                    peripheral: peripheral,
                    meshProxyIn: characteristic
                )
            }

            // Store 7FCB for alternative testing
            if uuidString == "7FCB" && isWritable {
                char7FCB = characteristic
                log("    >>> Found 7FCB characteristic!")
            }

            // Provisioning Data In (2ADB)
            if uuidString == "2ADB" || uuidString.contains("2ADB") {
                provisioningDataIn = characteristic
                log("    >>> Found Provisioning Data In (2ADB)!")
            }

            // Provisioning Data Out (2ADC)
            if uuidString == "2ADC" || uuidString.contains("2ADC") {
                provisioningDataOut = characteristic
                log("    >>> Found Provisioning Data Out (2ADC)!")
            }

            // Proxy Data Out (2ADE) - subscribe for mesh responses
            if uuidString == "2ADE" {
                log("    >>> Found Mesh Proxy Data Out (2ADE)!")
            }
        }

        // Mark as connected once we've discovered characteristics
        if connectionState == .discoveringServices {
            connectionState = .connected
            if let light = discoveredLights.first(where: { $0.peripheral.identifier == peripheral.identifier }) {
                connectedLight = light
            }

            log("Connected and ready")

            // Configure proxy filter and run post-provisioning config if needed
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self else { return }
                self.log("=== Control Characteristics Found ===")
                self.log("  meshProxyIn (2ADD): \(self.meshProxyIn != nil ? "YES" : "NO")")
                self.log("  sidusControl (2B12): \(self.sidusControl != nil ? "YES" : "NO")")
                self.log("  provisioningDataIn (2ADB): \(self.provisioningDataIn != nil ? "YES" : "NO")")
                self.log("=====================================")

                // Configure proxy filter (set to blacklist = accept all) before any mesh commands
                if let proxyIn = self.meshProxyIn {
                    self.sendProxyFilterSetup(proxyIn: proxyIn)

                    // For saved lights, config was already done during provisioning — go straight to ready
                    let isSavedLight = KeyStorage.shared.savedLights.contains(where: { $0.unicastAddress == self.targetUnicastAddress })
                    if isSavedLight {
                        self.log("Saved light — skipping post-provisioning config")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            self.connectionState = .ready
                        }
                    } else {
                        // Run post-provisioning config after short delay for filter to take effect
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            self.runPostProvisioningConfig(proxyIn: proxyIn)
                        }
                    }
                }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            log("Read error for \(characteristic.uuid): \(error.localizedDescription)")
            return
        }

        if let data = characteristic.value {
            log("Received from \(characteristic.uuid) (\(data.count) bytes): \(data.hexString)")
            lastReceivedData = data

            // Try parsing data from Sidus characteristics as light state
            let uuidStr = characteristic.uuid.uuidString.uppercased()
            if uuidStr.contains("2B12") || uuidStr == "7FCB" || uuidStr == "FF02" {
                if data.count >= 10 {
                    if let status = SidusStatusParser.parse(data) {
                        log("Parsed Sidus status from \(characteristic.uuid): type=\(status.commandType) intensity=\(status.intensity)% on=\(status.isOn)")
                        if !self.suppressStatusUpdates {
                            DispatchQueue.main.async {
                                self.lastLightStatus = status
                            }
                        }
                    } else {
                        log("  (Not a valid Sidus status payload)")
                    }
                }
            }

            // Parse mesh proxy data from 2ADE to extract network parameters
            // Note: 16-bit UUIDs may expand to full 128-bit format, so check both
            let uuidString = characteristic.uuid.uuidString.uppercased()
            if uuidString.contains("2ADE") || uuidString.contains("2ADC") {
                MeshCrypto.parseIncomingPDU(data)

                // Try to decrypt incoming mesh PDU
                if let parsed = MeshCrypto.decryptIncomingProxyPDU(data) {
                    let payloadHex = parsed.accessPayload.map { String(format: "%02X", $0) }.joined(separator: " ")
                    log("Decrypted mesh msg from 0x\(String(format: "%04X", parsed.src)) → 0x\(String(format: "%04X", parsed.dst)): \(payloadHex)")

                    let payload = parsed.accessPayload

                    // Check for Sidus vendor opcode 0x26 (1-byte) or 0xC0 0x11 0x02 0x26 (3-byte vendor + sub)
                    var sidusPayloadStart: Int? = nil

                    if payload.count >= 14 && payload[0] == 0xC0 && payload[1] == 0x11 && payload[2] == 0x02 && payload[3] == 0x26 {
                        sidusPayloadStart = 4
                    } else if payload.count >= 11 && payload[0] == 0x26 {
                        sidusPayloadStart = 1
                    }

                    if let start = sidusPayloadStart, payload.count >= start + 10 {
                        let sidusData = Data(payload[start..<(start + 10)])
                        log("Sidus payload (10 bytes): \(sidusData.hexString)")
                        if let status = SidusStatusParser.parse(sidusData) {
                            log("*** LIGHT STATUS: type=\(status.commandType) intensity=\(status.intensity)% on=\(status.isOn) cct=\(status.cctKelvin ?? 0) hue=\(status.hue ?? 0) sat=\(status.saturation ?? 0) ***")
                            if !self.suppressStatusUpdates {
                                DispatchQueue.main.async {
                                    self.lastLightStatus = status
                                }
                            }
                        } else {
                            log("Sidus payload checksum/parse failed — may be version or other response")
                        }
                    } else if payload.count >= 1 {
                        // Log opcode for any non-Sidus message
                        let opcode: String
                        if payload[0] >= 0xC0 && payload.count >= 3 {
                            opcode = "vendor 0x\(payload[0...2].map { String(format: "%02X", $0) }.joined())"
                        } else if payload[0] >= 0x80 && payload.count >= 2 {
                            opcode = "SIG 0x\(String(format: "%02X%02X", payload[0], payload[1]))"
                        } else {
                            opcode = "0x\(String(format: "%02X", payload[0]))"
                        }
                        log("Non-Sidus mesh msg opcode=\(opcode) len=\(payload.count)")
                    }
                }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            log("Write error for \(characteristic.uuid): \(error.localizedDescription)")
        } else {
            log("Write successful to \(characteristic.uuid)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            log("Notification state error for \(characteristic.uuid): \(error.localizedDescription)")
        } else {
            log("Notifications \(characteristic.isNotifying ? "enabled" : "disabled") for \(characteristic.uuid)")
        }
    }
}

// MARK: - Data Extension for Hex String
extension Data {
    var hexString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    init?(hexString: String) {
        let hex = hexString.replacingOccurrences(of: " ", with: "")
        var data = Data(capacity: hex.count / 2)

        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            if let byte = UInt8(hex[index..<nextIndex], radix: 16) {
                data.append(byte)
            } else {
                return nil
            }
            index = nextIndex
        }

        self = data
    }
}


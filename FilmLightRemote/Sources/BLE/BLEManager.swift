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
    // Published state
    @Published var connectionState: BLEConnectionState = .disconnected
    @Published var discoveredLights: [DiscoveredLight] = []
    @Published var connectedLight: DiscoveredLight?
    @Published var lastReceivedData: Data?
    @Published var isBluetoothAvailable = false
    @Published var lastLightStatus: SidusLightStatus?

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

    /// Whether the connected device has provisioning service available
    var isProvisioningAvailable: Bool {
        return provisioningDataIn != nil && provisioningDataOut != nil
    }

    // Scanning
    private var scanTimer: Timer?

    // Periodic state polling
    private var statePollingTimer: Timer?

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
    func connectToKnownPeripheral(identifier: UUID) {
        guard centralManager.state == .poweredOn else {
            log("Cannot reconnect - Bluetooth not powered on")
            connectionState = .failed("Bluetooth not available")
            return
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

    // MARK: - Command Methods (Placeholders - implement after protocol analysis)

    func sendCommand(_ data: Data) {
        guard let characteristic = controlCharacteristic else {
            log("Error: Control characteristic not available")
            return
        }

        guard let peripheral = connectedPeripheral else {
            log("Error: Not connected to peripheral")
            return
        }

        log("Sending to \(characteristic.uuid): \(data.hexString)")

        // Use writeWithoutResponse if supported, otherwise use withResponse
        let writeType: CBCharacteristicWriteType
        if characteristic.properties.contains(.writeWithoutResponse) {
            writeType = .withoutResponse
            log("  Using writeWithoutResponse")
        } else {
            writeType = .withResponse
            log("  Using writeWithResponse")
        }

        peripheral.writeValue(data, for: characteristic, type: writeType)
    }

    /// Try sending to all writable characteristics (for debugging)
    func sendToAllWritable(_ data: Data) {
        guard let peripheral = connectedPeripheral,
              let services = peripheral.services else {
            log("Error: No services available")
            return
        }

        log("Sending to ALL writable characteristics: \(data.hexString)")

        for service in services {
            guard let characteristics = service.characteristics else { continue }
            for char in characteristics {
                if char.properties.contains(.writeWithoutResponse) {
                    peripheral.writeValue(data, for: char, type: .withoutResponse)
                    log("  Sent to \(char.uuid) (writeWithoutResponse)")
                } else if char.properties.contains(.write) {
                    peripheral.writeValue(data, for: char, type: .withResponse)
                    log("  Sent to \(char.uuid) (write)")
                }
            }
        }
    }

    // MARK: - Light Control Commands (using Sidus Protocol)

    /// Current light state (stored for combined commands like power on/off)
    private(set) var currentIntensity: Int = 50
    private(set) var currentMode: String = "cct"
    private(set) var currentHue: Int = 0
    private(set) var currentSaturation: Int = 100
    private(set) var currentHSICCT: Int = 5600

    /// Sync BLEManager state from a loaded LightState (call when opening a light session)
    func syncState(from lightState: LightState) {
        currentIntensity = Int(lightState.intensity)
        currentCCT = Int(lightState.cctKelvin)
        currentMode = lightState.mode == .hsi ? "hsi" : "cct"
        currentHue = Int(lightState.hue)
        currentSaturation = Int(lightState.saturation)
    }

    func setIntensity(_ percent: Double) {
        currentIntensity = Int(percent)
        currentMode = "cct"
        guard let peripheral = connectedPeripheral else { return }

        log("setIntensity(\(percent)%) target=0x\(String(format: "%04X", targetUnicastAddress))")

        // Sidus opcode 0x26 + CCTProtocol — controls intensity via CCT mode
        let cctCmd = CCTProtocol(intensityPercent: percent, cctKelvin: currentCCT)
        let payload = cctCmd.getSendData()
        var accessMessage: [UInt8] = [0x26]
        accessMessage.append(contentsOf: payload)

        if let char = meshProxyIn {
            if let meshPDU = MeshCrypto.createStandardMeshPDU(
                accessMessage: accessMessage,
                dst: targetUnicastAddress
            ) {
                peripheral.writeValue(meshPDU, for: char, type: .withoutResponse)
                log("  Sent CCT intensity(\(percent)%) to 0x\(String(format: "%04X", targetUnicastAddress))")
            }
        }
    }

    /// Set CCT with explicit values and sleepMode control for instant on/off transitions.
    /// sleepMode=0 puts the light to sleep (instant off), sleepMode=1 wakes it (on).
    func setCCTWithSleep(intensity percent: Double, cctKelvin: Int, sleepMode: Int) {
        guard let peripheral = connectedPeripheral else { return }

        let cmd = CCTProtocol(
            intensity: Int(round(percent * 10)),
            cct: cctKelvin / 10,
            gm: 100,
            gmFlag: 0,
            sleepMode: sleepMode,
            autoPatchFlag: 0
        )
        let payload = cmd.getSendData()
        var accessMessage: [UInt8] = [0x26]
        accessMessage.append(contentsOf: payload)

        if let char = meshProxyIn {
            if let meshPDU = MeshCrypto.createStandardMeshPDU(
                accessMessage: accessMessage,
                dst: targetUnicastAddress
            ) {
                peripheral.writeValue(meshPDU, for: char, type: .withoutResponse)
            }
        }
    }

    /// Set HSI with explicit values and sleepMode control for instant on/off transitions.
    func setHSIWithSleep(intensity percent: Double, hue: Int, saturation: Int, cctKelvin: Int = 5600, sleepMode: Int) {
        guard let peripheral = connectedPeripheral else { return }

        let cmd = HSIProtocol(
            intensity: Int(round(percent * 10)),
            hue: hue,
            sat: saturation,
            cct: cctKelvin / 50,
            gm: 100,
            gmFlag: 0,
            sleepMode: sleepMode,
            autoPatchFlag: 0
        )
        let payload = cmd.getSendData()
        var accessMessage: [UInt8] = [0x26]
        accessMessage.append(contentsOf: payload)

        if let char = meshProxyIn {
            if let meshPDU = MeshCrypto.createStandardMeshPDU(
                accessMessage: accessMessage,
                dst: targetUnicastAddress
            ) {
                peripheral.writeValue(meshPDU, for: char, type: .withoutResponse)
            }
        }
    }

    /// Current CCT value for combined commands
    private var currentCCT: Int = 5600

    func setCCT(_ kelvin: Int) {
        currentCCT = kelvin
        currentMode = "cct"
        guard let peripheral = connectedPeripheral else { return }

        log("setCCT(\(kelvin)K) target=0x\(String(format: "%04X", targetUnicastAddress))")

        // Sidus opcode 0x26 + CCTProtocol — sets both intensity and CCT
        let cctCmd = CCTProtocol(intensityPercent: Double(currentIntensity), cctKelvin: kelvin)
        let payload = cctCmd.getSendData()
        var accessMessage: [UInt8] = [0x26]
        accessMessage.append(contentsOf: payload)

        if let char = meshProxyIn {
            if let meshPDU = MeshCrypto.createStandardMeshPDU(
                accessMessage: accessMessage,
                dst: targetUnicastAddress
            ) {
                peripheral.writeValue(meshPDU, for: char, type: .withoutResponse)
                log("  Sent CCT(\(kelvin)K, \(currentIntensity)%) to 0x\(String(format: "%04X", targetUnicastAddress))")
            }
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
        guard let peripheral = connectedPeripheral else { return }

        log("setHSI(h:\(hue), s:\(saturation), i:\(intensity), cct:\(cctKelvin)K) target=0x\(String(format: "%04X", targetUnicastAddress))")

        // Sidus opcode 0x26 + HSIProtocol — sets hue, saturation, intensity, white balance
        let cmd = HSIProtocol(intensityPercent: Double(intensity), hue: hue, saturationPercent: Double(saturation), cctKelvin: cctKelvin)
        let payload = cmd.getSendData()
        var accessMessage: [UInt8] = [0x26]
        accessMessage.append(contentsOf: payload)

        if let char = meshProxyIn {
            if let meshPDU = MeshCrypto.createStandardMeshPDU(
                accessMessage: accessMessage,
                dst: targetUnicastAddress
            ) {
                peripheral.writeValue(meshPDU, for: char, type: .withoutResponse)
                log("  Sent HSI(h:\(hue), s:\(saturation), i:\(intensity)) to 0x\(String(format: "%04X", targetUnicastAddress))")
            }
        }
    }

    func setPowerOn(_ on: Bool) {
        guard let peripheral = connectedPeripheral else { return }

        log("setPower(\(on)) mode=\(currentMode) target=0x\(String(format: "%04X", targetUnicastAddress))")

        // If turning off during effects mode, stop the effect first
        if !on && currentMode == "effects" {
            stopEffect()
        }

        let intensity = on ? max(currentIntensity, 10) : 0
        let payload: Data

        if currentMode == "hsi" {
            let cmd = HSIProtocol(
                intensity: intensity * 10,
                hue: currentHue,
                sat: currentSaturation,
                cct: currentHSICCT / 50,
                gm: 100,
                gmFlag: 0,
                sleepMode: on ? 1 : 0,
                autoPatchFlag: 0
            )
            payload = cmd.getSendData()
        } else {
            let cmd = CCTProtocol(
                intensity: intensity * 10,
                cct: currentCCT / 10,
                gm: 100,
                gmFlag: 0,
                sleepMode: on ? 1 : 0,
                autoPatchFlag: 0
            )
            payload = cmd.getSendData()
        }

        var accessMessage: [UInt8] = [0x26]
        accessMessage.append(contentsOf: payload)

        if let char = meshProxyIn {
            if let meshPDU = MeshCrypto.createStandardMeshPDU(
                accessMessage: accessMessage,
                dst: targetUnicastAddress
            ) {
                peripheral.writeValue(meshPDU, for: char, type: .withoutResponse)
                log("  Sent \(currentMode) power \(on ? "ON" : "OFF") (intensity=\(intensity)%) to 0x\(String(format: "%04X", targetUnicastAddress))")
            }
        }
    }

    func setEffect(effectType: Int, intensityPercent: Double, frq: Int, cctKelvin: Int = 5600, copCarColor: Int = 0) {
        currentMode = "effects"
        guard let peripheral = connectedPeripheral else { return }

        log("setEffect(type:\(effectType), intensity:\(intensityPercent)%, frq:\(frq), color:\(copCarColor)) target=0x\(String(format: "%04X", targetUnicastAddress))")

        var cmd = SidusEffectProtocol(effectType: effectType, intensityPercent: intensityPercent, frq: frq, cctKelvin: cctKelvin)
        cmd.color = copCarColor
        let payload = cmd.getSendData()
        var accessMessage: [UInt8] = [0x26]
        accessMessage.append(contentsOf: payload)

        if let char = meshProxyIn {
            if let meshPDU = MeshCrypto.createStandardMeshPDU(
                accessMessage: accessMessage,
                dst: targetUnicastAddress
            ) {
                peripheral.writeValue(meshPDU, for: char, type: .withoutResponse)
                log("  Sent effect type=\(effectType) to 0x\(String(format: "%04X", targetUnicastAddress))")
            }
        }
    }

    func stopEffect() {
        stopFaultyBulb()
        guard let peripheral = connectedPeripheral else { return }

        log("stopEffect() target=0x\(String(format: "%04X", targetUnicastAddress))")

        let cmd = SidusEffectProtocol(effectType: 15) // Effect Off
        let payload = cmd.getSendData()
        var accessMessage: [UInt8] = [0x26]
        accessMessage.append(contentsOf: payload)

        if let char = meshProxyIn {
            if let meshPDU = MeshCrypto.createStandardMeshPDU(
                accessMessage: accessMessage,
                dst: targetUnicastAddress
            ) {
                peripheral.writeValue(meshPDU, for: char, type: .withoutResponse)
                log("  Sent effect OFF to 0x\(String(format: "%04X", targetUnicastAddress))")
            }
        }
    }

    // MARK: - Faulty Bulb Software Engine

    private var faultyBulbEngine: FaultyBulbEngine?

    /// Start the software-driven faulty bulb effect. Survives view lifecycle changes.
    func startFaultyBulb(lightState: LightState) {
        stopFaultyBulb()
        let engine = FaultyBulbEngine()
        faultyBulbEngine = engine
        engine.start(bleManager: self, lightState: lightState)
        log("Faulty bulb engine started")
    }

    /// Stop the software-driven faulty bulb effect.
    func stopFaultyBulb() {
        if faultyBulbEngine != nil {
            faultyBulbEngine?.stop()
            faultyBulbEngine = nil
            log("Faulty bulb engine stopped")
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

    // MARK: - State Polling

    /// Start polling the light for its current state every few seconds
    func startStatePolling(interval: TimeInterval = 3.0) {
        stopStatePolling()
        log("Starting state polling (every \(interval)s)")
        statePollingTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.queryLightState()
        }
    }

    /// Stop polling
    func stopStatePolling() {
        statePollingTimer?.invalidate()
        statePollingTimer = nil
    }

    // MARK: - State Query

    /// Query the light's current state by re-sending the current CCT/HSI state via mesh.
    /// After model publication is configured, the light responds with its ACTUAL state
    /// (which may differ from what we sent if physical controls were used).
    func queryLightState() {
        guard let peripheral = connectedPeripheral, let char = meshProxyIn else {
            log("queryLightState: no mesh proxy connection")
            return
        }

        // Re-send current state as a normal SET command — the light will respond
        // with its actual state via the configured publication address
        let payload: Data
        if currentMode == "hsi" {
            let cmd = HSIProtocol(intensityPercent: Double(currentIntensity), hue: currentHue, saturationPercent: Double(currentSaturation), cctKelvin: currentHSICCT)
            payload = cmd.getSendData()
        } else {
            let cmd = CCTProtocol(intensityPercent: Double(currentIntensity), cctKelvin: currentCCT)
            payload = cmd.getSendData()
        }

        var accessMessage: [UInt8] = [0x26]
        accessMessage.append(contentsOf: payload)

        log("queryLightState: re-sending current state (\(currentMode), \(currentIntensity)%) via mesh")

        if let meshPDU = MeshCrypto.createStandardMeshPDU(
            accessMessage: accessMessage,
            dst: targetUnicastAddress
        ) {
            peripheral.writeValue(meshPDU, for: char, type: .withoutResponse)
        }
    }

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
            log("No device key for address 0x\(String(format: "%04X", deviceAddress)) — skipping config")
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
                self?.connectionState = .ready
            } else {
                self?.log("Config failed — commands may not work")
            }
        }
    }

    // MARK: - Private Methods

    private func cleanup() {
        stopFaultyBulb()
        stopStatePolling()
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

    private func log(_ message: String) {
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
        cleanup()
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

            // Log characteristics summary after a short delay to let all services complete
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { return }
                self.log("=== Control Characteristics Found ===")
                self.log("  meshProxyIn (2ADD): \(self.meshProxyIn != nil ? "YES" : "NO")")
                self.log("  sidusControl (2B12): \(self.sidusControl != nil ? "YES" : "NO")")
                self.log("  provisioningDataIn (2ADB): \(self.provisioningDataIn != nil ? "YES" : "NO")")
                self.log("=====================================")

                // Configure proxy filter (set to blacklist = accept all) before any mesh commands
                if let proxyIn = self.meshProxyIn {
                    self.sendProxyFilterSetup(proxyIn: proxyIn)

                    // Run post-provisioning config after short delay for filter to take effect
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.runPostProvisioningConfig(proxyIn: proxyIn)
                    }
                }
            }
        }
    }

    /// Send initialization sequence from captured Sidus Link traffic
    private func sendInitSequence() {
        guard let peripheral = connectedPeripheral else { return }

        log("Sending init sequence (from Sidus capture)...")

        // From packet capture - these are the exact init commands Sidus sends
        let initCommands: [Data] = [
            Data([0x01]),                    // ON
            Data([0x00]),                    // OFF
            Data([0xFF]),                    // Full brightness
            Data([0x01, 0x00]),              // Status?
            Data([0x01, 0xFF]),              // On + full?
            Data([0xF0, 0x01, 0x00, 0x00]),  // Init command from capture
            Data([0xF0, 0x00, 0x00, 0x00]),  // Another init command
        ]

        // Send to FF02
        if let char = controlCharacteristic {
            for cmd in initCommands {
                peripheral.writeValue(cmd, for: char, type: .withoutResponse)
                log("  FF02 init <- \(cmd.hexString)")
            }
        }

        // Send to 7FCB
        if let char = char7FCB {
            for cmd in initCommands {
                peripheral.writeValue(cmd, for: char, type: .withoutResponse)
                log("  7FCB init <- \(cmd.hexString)")
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
                        DispatchQueue.main.async {
                            self.lastLightStatus = status
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
                            DispatchQueue.main.async {
                                self.lastLightStatus = status
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

// MARK: - Faulty Bulb Software Engine
/// Sends random intensity values within a range at irregular intervals,
/// simulating a realistic faulty/flickering bulb effect.
/// Lives on BLEManager so it survives view lifecycle changes.
class FaultyBulbEngine {
    private var workItem: DispatchWorkItem?
    private weak var bleManager: BLEManager?
    private weak var lightState: LightState?
    private var currentIntensity: Double = 50.0

    func start(bleManager: BLEManager, lightState: LightState) {
        stop()
        self.bleManager = bleManager
        self.lightState = lightState
        self.currentIntensity = lightState.intensity
        fireEvent()
    }

    func stop() {
        workItem?.cancel()
        workItem = nil
        bleManager = nil
        lightState = nil
    }

    /// Send intensity via CCT or HSI depending on faulty bulb color mode.
    /// Reads all color values directly from lightState so they're always current.
    private func sendIntensity(_ percent: Double, sleepMode: Int) {
        guard let ls = lightState, let mgr = bleManager else { return }
        if ls.faultyBulbColorMode == .hsi {
            mgr.setHSIWithSleep(
                intensity: percent,
                hue: Int(ls.hue),
                saturation: Int(ls.saturation),
                cctKelvin: Int(ls.hsiCCT),
                sleepMode: sleepMode
            )
        } else {
            mgr.setCCTWithSleep(
                intensity: percent,
                cctKelvin: Int(ls.cctKelvin),
                sleepMode: sleepMode
            )
        }
    }

    /// Build the discrete intensity levels from the range and point count
    private func discretePoints() -> [Double] {
        guard let ls = lightState else { return [50] }
        let lo = min(ls.faultyBulbMin, ls.faultyBulbMax)
        let hi = max(ls.faultyBulbMin, ls.faultyBulbMax)
        let n = max(2, Int(ls.faultyBulbPoints))
        if n <= 1 || lo == hi { return [lo] }
        return (0..<n).map { i in
            lo + (hi - lo) * Double(i) / Double(n - 1)
        }
    }

    /// The main loop: wait for the frequency interval, then fire an event
    private func scheduleNextEvent() {
        guard let ls = lightState else { return }

        let freq = Int(ls.faultyBulbFrequency)
        let interval: Double

        if freq >= 10 {
            // R = random wait each time
            interval = Double.random(in: 0.08...2.0)
        } else {
            // 1-9: exponential curve, 1 = slow ~1.5s, 9 = fast ~0.08s
            let base = 1.5 * pow(0.65, Double(freq - 1))
            interval = base * Double.random(in: 0.85...1.15)
        }

        let work = DispatchWorkItem { [weak self] in
            self?.fireEvent()
        }
        workItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: work)
    }

    /// Fire one flicker event: pick a new point and go there (snap or fade).
    /// The fault bias slider is the primary control — it decides whether the
    /// bulb dips at all and overrides all other point-selection rules.
    private func fireEvent() {
        guard let ls = lightState else { return }

        let points = discretePoints()
        let hi = points.last ?? 50.0
        let bias = ls.faultyBulbBias / 10.0 // 0.0 – 1.0

        // Bias 0 = not faulty at all → always stay at the highest point
        if bias <= 0 {
            if abs(currentIntensity - hi) > 0.5 {
                currentIntensity = hi
                sendIntensity(hi, sleepMode: 1)
            }
            scheduleNextEvent()
            return
        }

        let target: Double

        // Are we currently on the high point?
        let onHigh = abs(currentIntensity - hi) < 0.5

        if onHigh {
            // Decide whether to dip. Bias controls the probability of dipping.
            // bias=0.1 → 10% chance to dip, bias=1.0 → 100% chance to dip
            if Double.random(in: 0...1) < bias {
                // Dip to a lower point
                let lowerPoints = points.filter { $0 < hi - 0.5 }
                target = lowerPoints.randomElement() ?? hi
            } else {
                // Stay high — no flicker this cycle
                scheduleNextEvent()
                return
            }
        } else {
            // We're on a low point — always return to high
            target = hi
        }

        let transition = ls.faultyBulbTransition
        let lo = min(ls.faultyBulbMin, ls.faultyBulbMax)

        if transition < 0.5 {
            // Instant snap — use sleepMode toggling for hard cut.
            // Going to the lowest point: sleep=0 (instant off).
            // Going to any higher point: sleep=1 (on) with that intensity.
            currentIntensity = target
            if target <= lo && lo < 1.0 {
                sendIntensity(0, sleepMode: 0)
            } else {
                sendIntensity(target, sleepMode: 1)
            }
            scheduleNextEvent()
        } else {
            // Fade to target over transition duration, then schedule next
            let fadeDuration = transition * 0.13 // 1 → 0.13s, 15 → 1.95s
            let stepInterval: Double = 0.08
            let totalSteps = max(1, Int(fadeDuration / stepInterval))
            fadeToTarget(target: target, stepsRemaining: totalSteps, stepInterval: stepInterval)
        }
    }

    /// Incrementally step toward the target intensity, then schedule next event
    private func fadeToTarget(target: Double, stepsRemaining: Int, stepInterval: Double) {
        guard stepsRemaining > 0 else {
            currentIntensity = target
            sendIntensity(target, sleepMode: 1)
            scheduleNextEvent()
            return
        }

        let interpolated = currentIntensity + (target - currentIntensity) / Double(stepsRemaining)
        currentIntensity = interpolated
        sendIntensity(interpolated, sleepMode: 1)

        let work = DispatchWorkItem { [weak self] in
            self?.fadeToTarget(target: target, stepsRemaining: stepsRemaining - 1, stepInterval: stepInterval)
        }
        workItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + stepInterval, execute: work)
    }
}

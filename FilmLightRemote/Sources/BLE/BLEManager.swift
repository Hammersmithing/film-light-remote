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

    // Debug/Analysis mode - logs all BLE traffic
    @Published var debugMode = true
    @Published var debugLog: [String] = []

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

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
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

    /// Current intensity for CCT mode (stored for combined commands)
    private var currentIntensity: Int = 50

    func setIntensity(_ percent: Int) {
        currentIntensity = percent
        guard let peripheral = connectedPeripheral else { return }

        log("setIntensity(\(percent)%)")

        // Create Sidus CCT protocol command (10-byte format)
        let cctCmd = CCTProtocol(intensityPercent: Double(percent), cctKelvin: currentCCT)
        let payload = cctCmd.getSendData()

        log("  Sidus payload: \(payload.hexString)")

        // Method 1: Try direct Sidus control characteristic (2B12) with opcode prefix
        if let char = sidusControl {
            // Try with Sidus opcode 0x26 prepended
            var prefixedPayload = Data([0x26])
            prefixedPayload.append(payload)
            peripheral.writeValue(prefixedPayload, for: char, type: .withoutResponse)
            log("  Sent [0x26 + payload] to Sidus control (2B12)")

            // Also try raw payload without prefix
            peripheral.writeValue(payload, for: char, type: .withoutResponse)
            log("  Sent RAW to Sidus control (2B12)")
        }

        // Method 2: Try mesh proxy with encryption (includes opcode in MeshCrypto)
        if let meshPDU = MeshCrypto.createMeshProxyPDU(accessPayload: payload) {
            if let char = meshProxyIn {
                peripheral.writeValue(meshPDU, for: char, type: .withoutResponse)
                log("  Sent ENCRYPTED to Mesh Proxy (2ADD)")
            }
        }

        // NOTE: Telink commands to FF02 cause disconnects - disabled
        // The light expects mesh-encrypted commands only
    }

    /// Current CCT value for combined commands
    private var currentCCT: Int = 5600

    func setCCT(_ kelvin: Int) {
        currentCCT = kelvin

        // Try simple format: [0x02] [cct_high] [cct_low]
        let cctValue = UInt16(kelvin)
        let simpleCmd = Data([0x02, UInt8(cctValue >> 8), UInt8(cctValue & 0xFF)])
        log("setCCT(\(kelvin)K) simple -> \(simpleCmd.hexString)")
        sendCommand(simpleCmd)
    }

    func setRGB(red: Int, green: Int, blue: Int) {
        // Convert RGB to HSI and send
        let (h, s, i) = rgbToHSI(red: red, green: green, blue: blue)
        setHSI(hue: h, saturation: s, intensity: i)
    }

    func setHSI(hue: Int, saturation: Int, intensity: Int) {
        let cmd = HSIProtocol(intensityPercent: Double(intensity), hue: hue, saturationPercent: Double(saturation))
        let data = cmd.getSendData()
        log("setHSI(h:\(hue), s:\(saturation), i:\(intensity)) -> \(data.hexString)")
        sendCommand(data)
    }

    func setPowerOn(_ on: Bool) {
        guard let peripheral = connectedPeripheral else { return }

        log("setPower(\(on))")

        // Use OnOffProtocol format (10-byte Sidus command)
        let powerCmd = OnOffProtocol(on: on)
        let payload = powerCmd.getSendData()
        log("  Sidus power payload: \(payload.hexString)")

        // Method 1: Send to Sidus control (2B12) with opcode prefix
        if let char = sidusControl {
            // Try with Sidus opcode 0x26 prepended
            var prefixedPayload = Data([0x26])
            prefixedPayload.append(payload)
            peripheral.writeValue(prefixedPayload, for: char, type: .withoutResponse)
            log("  Sent [0x26 + payload] to Sidus control (2B12)")

            // Also try raw payload
            peripheral.writeValue(payload, for: char, type: .withoutResponse)
            log("  Sent RAW to Sidus control (2B12)")
        }

        // Method 2: Send via mesh proxy (includes opcode in MeshCrypto)
        if let meshPDU = MeshCrypto.createMeshProxyPDU(accessPayload: payload) {
            if let char = meshProxyIn {
                peripheral.writeValue(meshPDU, for: char, type: .withoutResponse)
                log("  Sent ENCRYPTED to Mesh Proxy (2ADD)")
            }
        }

        // NOTE: Telink commands to FF02/7FCB cause disconnects - disabled
        // The light expects mesh-encrypted commands only
    }

    func setEffect(_ effectId: Int, speed: Int = 50) {
        // Effects not yet implemented - requires effect protocol analysis
        log("setEffect(\(effectId), speed: \(speed)) - Not yet implemented")
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

    private func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let entry = "[\(timestamp)] \(message)"
        print(entry)

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
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("Connected to \(peripheral.name ?? "Unknown")")
        connectedPeripheral = peripheral
        peripheral.delegate = self
        connectionState = .discoveringServices

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

            // Don't send init sequence - it was causing disconnects
            log("Connected and ready - waiting for user commands")
            // sendInitSequence()

            // Log characteristics summary after a short delay to let all services complete
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { return }
                self.log("=== Control Characteristics Found ===")
                self.log("  sidusControl (2B12): \(self.sidusControl != nil ? "YES" : "NO")")
                self.log("  meshProxyIn (2ADD): \(self.meshProxyIn != nil ? "YES" : "NO")")
                self.log("  controlCharacteristic (FF02): \(self.controlCharacteristic != nil ? "YES" : "NO")")
                self.log("  char7FCB: \(self.char7FCB != nil ? "YES" : "NO")")
                self.log("  provisioningDataIn (2ADB): \(self.provisioningDataIn != nil ? "YES" : "NO")")
                self.log("  provisioningDataOut (2ADC): \(self.provisioningDataOut != nil ? "YES" : "NO")")
                self.log("  Provisioning Available: \(self.isProvisioningAvailable ? "YES" : "NO")")
                self.log("=====================================")
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
            log("Received from \(characteristic.uuid): \(data.hexString)")
            lastReceivedData = data

            // Parse mesh proxy data from 2ADE to extract network parameters
            // Note: 16-bit UUIDs may expand to full 128-bit format, so check both
            let uuidString = characteristic.uuid.uuidString.uppercased()
            if uuidString.contains("2ADE") || uuidString.contains("2ADC") {
                MeshCrypto.parseIncomingPDU(data)
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

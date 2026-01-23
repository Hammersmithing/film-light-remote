import Foundation
import CoreBluetooth
import Combine

// MARK: - BLE UUIDs (To be determined from packet capture analysis)
// These are placeholders - update after analyzing BLE traffic
struct AputureUUIDs {
    // Service UUIDs - discover these from packet capture
    static let primaryService = CBUUID(string: "0000FFE0-0000-1000-8000-00805F9B34FB") // Placeholder

    // Characteristic UUIDs - discover these from packet capture
    static let controlCharacteristic = CBUUID(string: "0000FFE1-0000-1000-8000-00805F9B34FB") // Placeholder
    static let statusCharacteristic = CBUUID(string: "0000FFE2-0000-1000-8000-00805F9B34FB") // Placeholder
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

// MARK: - Discovered Light
struct DiscoveredLight: Identifiable, Equatable {
    let id: UUID
    let peripheral: CBPeripheral
    let name: String
    let rssi: Int

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
    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var controlCharacteristic: CBCharacteristic?
    private var statusCharacteristic: CBCharacteristic?
    private var meshProxyIn: CBCharacteristic?  // 2ADD
    private var char7FCB: CBCharacteristic?     // Alternative control
    private var sidusControl: CBCharacteristic? // 2B12 - Direct Sidus control

    // Scanning
    private var scanTimer: Timer?

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - Public Methods

    func startScanning() {
        guard centralManager.state == .poweredOn else {
            log("Cannot scan - Bluetooth not powered on")
            return
        }

        discoveredLights.removeAll()
        connectionState = .scanning
        log("Starting BLE scan for Aputure lights...")

        // Scan for all devices initially to discover service UUIDs
        // Later can filter by specific service UUID once discovered
        centralManager.scanForPeripherals(
            withServices: nil, // Scan all - change to [AputureUUIDs.primaryService] once known
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )

        // Stop scanning after 10 seconds
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
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

        // Log all discovered devices in debug mode for initial discovery
        if debugMode {
            var adData = "Advertisement: "
            if let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
                adData += "Services: \(serviceUUIDs) "
            }
            if let mfgData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data {
                adData += "MfgData: \(mfgData.hexString)"
            }
            log("Discovered: \(name) (RSSI: \(RSSI)) \(adData)")
        }

        // Filter for Aputure devices - adjust filter criteria based on discovery
        // Common patterns: name contains "Aputure", "Storm", "Amaran", "AL-", "MC", etc.
        let aputureKeywords = ["aputure", "storm", "amaran", "sidus", "al-", "mc", "ls c"]
        let isAputure = aputureKeywords.contains { name.lowercased().contains($0) }

        if isAputure || debugMode { // In debug mode, show all devices
            let light = DiscoveredLight(
                id: peripheral.identifier,
                peripheral: peripheral,
                name: name,
                rssi: RSSI.intValue
            )

            if !discoveredLights.contains(where: { $0.id == light.id }) {
                discoveredLights.append(light)
                log("Added light: \(name)")
            }
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
            let aputureControlUUID = CBUUID(string: "00010203-0405-0607-0809-0a0b0c0d2b12")
            if characteristic.uuid == aputureControlUUID && isWritable {
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

            // Standard Aputure UUIDs
            if characteristic.uuid == AputureUUIDs.controlCharacteristic {
                controlCharacteristic = characteristic
                log("    >>> Found standard Aputure control characteristic")
            } else if characteristic.uuid == AputureUUIDs.statusCharacteristic {
                statusCharacteristic = characteristic
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

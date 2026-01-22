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

        log("Sending: \(data.hexString)")
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
    }

    // Placeholder command builders - implement after analyzing packet captures
    func setIntensity(_ percent: Int) {
        // TODO: Implement after protocol analysis
        // Example: let command = buildIntensityCommand(percent)
        // sendCommand(command)
        log("setIntensity(\(percent)) - Not yet implemented")
    }

    func setCCT(_ kelvin: Int) {
        // TODO: Implement after protocol analysis
        log("setCCT(\(kelvin)) - Not yet implemented")
    }

    func setRGB(red: Int, green: Int, blue: Int) {
        // TODO: Implement after protocol analysis
        log("setRGB(\(red), \(green), \(blue)) - Not yet implemented")
    }

    func setHSI(hue: Int, saturation: Int, intensity: Int) {
        // TODO: Implement after protocol analysis
        log("setHSI(\(hue), \(saturation), \(intensity)) - Not yet implemented")
    }

    func setPowerOn(_ on: Bool) {
        // TODO: Implement after protocol analysis
        log("setPower(\(on)) - Not yet implemented")
    }

    func setEffect(_ effectId: Int, speed: Int = 50) {
        // TODO: Implement after protocol analysis
        log("setEffect(\(effectId), speed: \(speed)) - Not yet implemented")
    }

    // MARK: - Private Methods

    private func cleanup() {
        connectedPeripheral = nil
        connectedLight = nil
        controlCharacteristic = nil
        statusCharacteristic = nil
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

            // Store known characteristics (update UUIDs after analysis)
            if characteristic.uuid == AputureUUIDs.controlCharacteristic {
                controlCharacteristic = characteristic
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

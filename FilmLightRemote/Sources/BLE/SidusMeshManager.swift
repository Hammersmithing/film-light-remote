import Foundation
import CoreBluetooth
import Combine

/// Simplified manager for Sidus Mesh communication with Aputure/Amaran lights
/// Uses CoreBluetooth directly with extracted Sidus protocol
class SidusMeshManager: NSObject, ObservableObject {

    // MARK: - Published State

    @Published var connectionState: BLEConnectionState = .disconnected
    @Published var discoveredLights: [DiscoveredLight] = []
    @Published var connectedLight: DiscoveredLight?
    @Published var debugLog: [String] = []
    @Published var isBluetoothReady = false

    // MARK: - Core Bluetooth

    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var meshProxyDataIn: CBCharacteristic?
    private var meshProxyDataOut: CBCharacteristic?
    private var aputureControl: CBCharacteristic?

    // MARK: - UUIDs

    private let meshProxyServiceUUID = CBUUID(string: "1828")
    private let meshProxyDataInUUID = CBUUID(string: "2ADD")
    private let meshProxyDataOutUUID = CBUUID(string: "2ADE")
    private let aputureControlServiceUUID = CBUUID(string: "00010203-0405-0607-0809-0a0b0c0d1912")
    private let aputureControlCharacteristicUUID = CBUUID(string: "00010203-0405-0607-0809-0a0b0c0d2b12")

    // MARK: - Initialization

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
        log("SidusMeshManager initialized")
        log("Network Key: \(SidusMeshConfig.defaultNetworkKey.hexEncodedString)")
        log("App Key: \(SidusMeshConfig.defaultAppKey.hexEncodedString)")
    }

    // MARK: - Public API

    func startScanning() {
        guard centralManager.state == .poweredOn else {
            log("Bluetooth not ready")
            return
        }

        discoveredLights.removeAll()
        connectionState = .scanning
        log("Scanning for Aputure/Amaran lights...")

        // Scan for all devices to find Aputure lights
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )

        // Auto-stop after 15 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            if self?.connectionState == .scanning {
                self?.stopScanning()
            }
        }
    }

    func stopScanning() {
        centralManager.stopScan()
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

    // MARK: - Light Control Commands

    /// Set CCT (Color Temperature) mode
    /// - Parameters:
    ///   - intensity: 0-100 percent
    ///   - cctKelvin: Color temperature in Kelvin (3200-5600K typical)
    ///   - gm: Green-Magenta adjustment (0-200, 100 = neutral)
    func setCCT(intensity: Int, cctKelvin: Int, gm: Int = 100) {
        let cmd = CCTProtocol(intensityPercent: Double(intensity), cctKelvin: cctKelvin, gm: gm)
        let data = cmd.getSendData()
        log("CCT Command: intensity=\(intensity)%, cct=\(cctKelvin)K, gm=\(gm)")
        sendCommand(data)
    }

    /// Set HSI (Hue-Saturation-Intensity) mode
    /// - Parameters:
    ///   - intensity: 0-100 percent
    ///   - hue: 0-360 degrees
    ///   - saturation: 0-100 percent
    func setHSI(intensity: Int, hue: Int, saturation: Int) {
        let cmd = HSIProtocol(intensityPercent: Double(intensity), hue: hue, saturationPercent: Double(saturation))
        let data = cmd.getSendData()
        log("HSI Command: intensity=\(intensity)%, hue=\(hue), sat=\(saturation)%")
        sendCommand(data)
    }

    /// Send raw command data
    /// If connected via Mesh Proxy (provisioned device), wraps in encrypted mesh PDU
    func sendCommand(_ data: Data) {
        guard connectionState == .ready else {
            log("Error: Not connected/ready")
            return
        }

        log("Sending: \(data.hexEncodedString)")

        // Try Aputure control characteristic first (unprovisioned/direct control)
        if let char = aputureControl, let peripheral = connectedPeripheral {
            peripheral.writeValue(data, for: char, type: .withoutResponse)
            log("Sent via Aputure control characteristic")
        }
        // Use mesh proxy with encrypted PDU (provisioned device)
        else if let char = meshProxyDataIn, let peripheral = connectedPeripheral {
            // Reinitialize MeshCrypto to ensure it has the latest keys
            MeshCrypto.reinitialize()

            // Get the first provisioned device address, or use broadcast
            let keyStorage = KeyStorage.shared
            let dstAddress: UInt16 = keyStorage.provisionedAddresses.first ?? 0xFFFF

            log("Wrapping in mesh PDU for address 0x\(String(format: "%04X", dstAddress))")

            // Create encrypted mesh proxy PDU
            if let meshPDU = MeshCrypto.createMeshProxyPDU(
                accessPayload: data,
                dst: dstAddress,
                src: 0x0001,  // Provisioner address
                ttl: 7
            ) {
                peripheral.writeValue(meshPDU, for: char, type: .withoutResponse)
                log("Sent via Mesh Proxy (encrypted): \(meshPDU.hexEncodedString)")
            } else {
                log("Error: Failed to create mesh PDU")
            }
        }
        else {
            log("Error: No writable characteristic available")
        }
    }

    /// Send command to a specific unicast address
    func sendCommand(_ data: Data, toAddress address: UInt16) {
        guard connectionState == .ready else {
            log("Error: Not connected/ready")
            return
        }

        guard let char = meshProxyDataIn, let peripheral = connectedPeripheral else {
            log("Error: Mesh proxy not available")
            return
        }

        MeshCrypto.reinitialize()

        log("Sending to address 0x\(String(format: "%04X", address)): \(data.hexEncodedString)")

        if let meshPDU = MeshCrypto.createMeshProxyPDU(
            accessPayload: data,
            dst: address,
            src: 0x0001,
            ttl: 7
        ) {
            peripheral.writeValue(meshPDU, for: char, type: .withoutResponse)
            log("Sent via Mesh Proxy: \(meshPDU.hexEncodedString)")
        } else {
            log("Error: Failed to create mesh PDU")
        }
    }

    /// Test command - generates a CCT command and logs it without sending
    func testCCTCommand(intensity: Int, cctKelvin: Int) {
        let cmd = CCTProtocol(intensityPercent: Double(intensity), cctKelvin: cctKelvin)
        let data = cmd.getSendData()
        log("Test CCT Command: intensity=\(intensity)%, cct=\(cctKelvin)K")
        log("  Hex: \(data.hexEncodedString)")
        log("  Bytes: \(data.map { String(format: "%d", $0) }.joined(separator: ", "))")
    }

    // MARK: - Private Methods

    private func cleanup() {
        connectedPeripheral = nil
        connectedLight = nil
        meshProxyDataIn = nil
        meshProxyDataOut = nil
        aputureControl = nil
        connectionState = .disconnected
    }

    private func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let entry = "[\(timestamp)] \(message)"
        print("SidusMesh: \(entry)")
        DispatchQueue.main.async {
            self.debugLog.append(entry)
            if self.debugLog.count > 500 {
                self.debugLog.removeFirst(100)
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension SidusMeshManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            isBluetoothReady = true
            log("Bluetooth ready")
        case .poweredOff:
            isBluetoothReady = false
            log("Bluetooth off")
            cleanup()
        case .unauthorized:
            log("Bluetooth unauthorized")
        default:
            log("Bluetooth state: \(central.state.rawValue)")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                       advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "Unknown"
        let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []

        // Only accept Bluetooth Mesh devices
        let isUnprovisioned = serviceUUIDs.contains(MeshUUIDs.provisioningService)
        let isProvisioned = serviceUUIDs.contains(MeshUUIDs.proxyService)

        guard isUnprovisioned || isProvisioned else { return }

        let meshState: LightMeshState = isUnprovisioned ? .unprovisioned : .provisioned
        let light = DiscoveredLight(
            id: peripheral.identifier,
            peripheral: peripheral,
            name: name,
            rssi: RSSI.intValue,
            meshState: meshState,
            deviceUUID: nil,
            serviceData: nil
        )

        if !discoveredLights.contains(where: { $0.id == light.id }) {
            discoveredLights.append(light)
            log("Found \(meshState.rawValue): \(name) (RSSI: \(RSSI))")
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("Connected to \(peripheral.name ?? "Unknown")")
        connectedPeripheral = peripheral
        peripheral.delegate = self
        connectionState = .connected

        // Discover all services
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("Connection failed: \(error?.localizedDescription ?? "Unknown")")
        connectionState = .failed(error?.localizedDescription ?? "Connection failed")
        cleanup()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("Disconnected")
        cleanup()
    }
}

// MARK: - CBPeripheralDelegate

extension SidusMeshManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            log("Service discovery error: \(error.localizedDescription)")
            return
        }

        guard let services = peripheral.services else { return }

        log("Found \(services.count) services:")
        for service in services {
            log("  Service: \(service.uuid)")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            log("Characteristic error: \(error.localizedDescription)")
            return
        }

        guard let characteristics = service.characteristics else { return }

        for char in characteristics {
            var props: [String] = []
            if char.properties.contains(.read) { props.append("R") }
            if char.properties.contains(.write) { props.append("W") }
            if char.properties.contains(.writeWithoutResponse) { props.append("WNR") }
            if char.properties.contains(.notify) { props.append("N") }
            if char.properties.contains(.indicate) { props.append("I") }

            log("    Char: \(char.uuid) [\(props.joined(separator: ","))]")

            // Store relevant characteristics
            if char.uuid == meshProxyDataInUUID {
                meshProxyDataIn = char
                log("      -> Mesh Proxy Data In")
            } else if char.uuid == meshProxyDataOutUUID {
                meshProxyDataOut = char
                peripheral.setNotifyValue(true, for: char)
                log("      -> Mesh Proxy Data Out (subscribed)")
            } else if char.uuid == aputureControlCharacteristicUUID {
                aputureControl = char
                log("      -> Aputure Control")
            }

            // Subscribe to notifications
            if char.properties.contains(.notify) || char.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: char)
            }
        }

        // Mark ready once we have at least one writable characteristic
        if (aputureControl != nil || meshProxyDataIn != nil) && connectionState == .connected {
            connectionState = .ready
            if let light = discoveredLights.first(where: { $0.peripheral.identifier == peripheral.identifier }) {
                connectedLight = light
            }
            log("Ready to send commands")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            log("Read error: \(error.localizedDescription)")
            return
        }

        if let data = characteristic.value {
            log("Received from \(characteristic.uuid): \(data.hexEncodedString)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            log("Write error: \(error.localizedDescription)")
        } else {
            log("Write successful")
        }
    }
}

// Data.hexEncodedString is defined in SidusMeshConfig.swift

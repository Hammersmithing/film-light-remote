import Foundation
import CoreBluetooth
import Combine

/// Provisioning state machine states
enum ProvisioningState: Equatable {
    case idle
    case connecting
    case discoveringServices
    case ready
    case inviteSent
    case capabilitiesReceived
    case startSent
    case publicKeySent
    case publicKeyReceived
    case confirmationSent
    case confirmationReceived
    case randomSent
    case randomReceived
    case dataSent
    case complete
    case failed(String)

    var isTerminal: Bool {
        switch self {
        case .complete, .failed: return true
        default: return false
        }
    }

    var description: String {
        switch self {
        case .idle: return "Idle"
        case .connecting: return "Connecting..."
        case .discoveringServices: return "Discovering services..."
        case .ready: return "Ready to provision"
        case .inviteSent: return "Invite sent"
        case .capabilitiesReceived: return "Capabilities received"
        case .startSent: return "Start sent"
        case .publicKeySent: return "Public key sent"
        case .publicKeyReceived: return "Public key received"
        case .confirmationSent: return "Confirmation sent"
        case .confirmationReceived: return "Confirmation received"
        case .randomSent: return "Random sent"
        case .randomReceived: return "Random received"
        case .dataSent: return "Provisioning data sent"
        case .complete: return "Complete"
        case .failed(let msg): return "Failed: \(msg)"
        }
    }

    var progress: Double {
        switch self {
        case .idle: return 0.0
        case .connecting: return 0.05
        case .discoveringServices: return 0.1
        case .ready: return 0.15
        case .inviteSent: return 0.2
        case .capabilitiesReceived: return 0.3
        case .startSent: return 0.35
        case .publicKeySent: return 0.45
        case .publicKeyReceived: return 0.55
        case .confirmationSent: return 0.65
        case .confirmationReceived: return 0.7
        case .randomSent: return 0.8
        case .randomReceived: return 0.85
        case .dataSent: return 0.95
        case .complete: return 1.0
        case .failed: return 0.0
        }
    }
}

/// Manages Bluetooth Mesh provisioning for Aputure/Amaran lights
class ProvisioningManager: NSObject, ObservableObject {

    // MARK: - Published State

    @Published var state: ProvisioningState = .idle
    @Published var statusMessage: String = ""

    // MARK: - Provisioning Configuration

    /// Network key to provision the device with
    var networkKey: [UInt8] = Array(SidusMeshConfig.defaultNetworkKey)

    /// Application key to use after provisioning
    var appKey: [UInt8] = Array(SidusMeshConfig.defaultAppKey)

    /// Key index for the network key
    var keyIndex: UInt16 = 0

    /// IV Index for the mesh network
    var ivIndex: UInt32 = SidusMeshConfig.defaultIVIndex

    /// Unicast address to assign to the device
    var unicastAddress: UInt16 = 0x0002

    /// Auth value (16 bytes of zeros for No OOB)
    private let authValue: [UInt8] = [UInt8](repeating: 0, count: 16)

    // MARK: - Core Bluetooth

    private var centralManager: CBCentralManager?
    private var originalCentralManagerDelegate: CBCentralManagerDelegate?
    private var peripheral: CBPeripheral?
    private var provisioningDataIn: CBCharacteristic?  // 2ADB - write
    private var provisioningDataOut: CBCharacteristic? // 2ADC - notify

    // MARK: - Cryptography

    private let crypto = ProvisioningCrypto()

    // MARK: - PDU State

    private var invitePDU: [UInt8]?
    private var capabilitiesPDU: [UInt8]?
    private var startPDU: [UInt8]?
    private var deviceConfirmation: [UInt8]?

    // MARK: - Timeout

    private var timeoutTimer: Timer?
    private let pduTimeout: TimeInterval = 30.0

    // MARK: - Completion Handler

    private var completionHandler: ((Result<[UInt8], ProvisioningError>) -> Void)?

    // MARK: - UUIDs

    private let provisioningServiceUUID = CBUUID(string: "1827")
    private let provisioningDataInUUID = CBUUID(string: "2ADB")
    private let provisioningDataOutUUID = CBUUID(string: "2ADC")

    // MARK: - Initialization

    override init() {
        super.init()
    }

    // MARK: - Public API

    /// Start provisioning a peripheral
    /// - Parameters:
    ///   - peripheral: The CBPeripheral to provision (must be in unprovisioned state)
    ///   - centralManager: The CBCentralManager managing the connection
    ///   - completion: Called with device key on success, or error on failure
    func startProvisioning(
        peripheral: CBPeripheral,
        centralManager: CBCentralManager,
        completion: @escaping (Result<[UInt8], ProvisioningError>) -> Void
    ) {
        reset()

        self.peripheral = peripheral
        self.centralManager = centralManager
        self.completionHandler = completion

        // Set ourselves as delegates
        peripheral.delegate = self

        log("Starting provisioning for \(peripheral.name ?? "Unknown")")

        // Check if already connected
        if peripheral.state == .connected {
            state = .discoveringServices
            log("Already connected, discovering services...")
            peripheral.discoverServices([provisioningServiceUUID])
        } else {
            state = .connecting
            log("Connecting to peripheral...")
            // Save original delegate and take over temporarily
            originalCentralManagerDelegate = centralManager.delegate
            centralManager.delegate = self
            centralManager.connect(peripheral, options: nil)
        }

        startTimeout()
    }

    /// Cancel ongoing provisioning
    func cancel() {
        log("Provisioning cancelled")
        timeoutTimer?.invalidate()
        restoreDelegate()

        if let peripheral = peripheral, let cm = centralManager {
            cm.cancelPeripheralConnection(peripheral)
        }

        state = .failed("Cancelled")
        completionHandler?(.failure(.unexpectedState))
        completionHandler = nil
    }

    // MARK: - Private Methods

    private func reset() {
        crypto.reset()
        invitePDU = nil
        capabilitiesPDU = nil
        startPDU = nil
        deviceConfirmation = nil
        provisioningDataIn = nil
        provisioningDataOut = nil
        originalCentralManagerDelegate = nil
        state = .idle
        statusMessage = ""
        timeoutTimer?.invalidate()
    }

    private func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        print("[\(timestamp)] ProvisioningManager: \(message)")
        DispatchQueue.main.async {
            self.statusMessage = message
        }
    }

    private func startTimeout() {
        timeoutTimer?.invalidate()
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: pduTimeout, repeats: false) { [weak self] _ in
            self?.handleTimeout()
        }
    }

    private func handleTimeout() {
        log("Provisioning timeout in state: \(state.description)")
        fail(with: .timeout)
    }

    private func restoreDelegate() {
        if let original = originalCentralManagerDelegate {
            centralManager?.delegate = original
            originalCentralManagerDelegate = nil
        }
    }

    private func fail(with error: ProvisioningError) {
        timeoutTimer?.invalidate()
        restoreDelegate()
        state = .failed(error.localizedDescription)
        completionHandler?(.failure(error))
        completionHandler = nil
    }

    private func succeed(deviceKey: [UInt8]) {
        timeoutTimer?.invalidate()
        restoreDelegate()
        state = .complete
        log("Provisioning complete! Device key: \(deviceKey.map { String(format: "%02X", $0) }.joined())")
        completionHandler?(.success(deviceKey))
        completionHandler = nil
    }

    // MARK: - Provisioning Flow

    private func sendInvite() {
        guard let char = provisioningDataIn else {
            fail(with: .bleError("Provisioning characteristic not found"))
            return
        }

        let invite = ProvisioningInvite(attentionDuration: 0)
        invitePDU = invite.toBytes()

        log("Sending Invite PDU")
        peripheral?.writeValue(invite.toGATTPDU(), for: char, type: .withoutResponse)
        state = .inviteSent
        startTimeout()
    }

    private func handleCapabilities(_ caps: ProvisioningCapabilities) {
        guard state == .inviteSent else {
            log("Unexpected capabilities in state \(state)")
            return
        }

        capabilitiesPDU = caps.rawBytes
        state = .capabilitiesReceived

        log("Device capabilities: \(caps.numberOfElements) element(s)")

        // Check algorithm support
        guard caps.supportsFIPSP256 else {
            fail(with: .invalidPDU("Device doesn't support FIPS P-256"))
            return
        }

        // Send Start PDU (No OOB)
        sendStart()
    }

    private func sendStart() {
        guard let char = provisioningDataIn else {
            fail(with: .bleError("Provisioning characteristic not found"))
            return
        }

        let start = ProvisioningStart(
            algorithm: 0x00,      // FIPS P-256
            publicKeyType: 0x00,  // No OOB public key
            authMethod: 0x00,     // No OOB authentication
            authAction: 0x00,
            authSize: 0x00
        )
        startPDU = start.toBytes()

        log("Sending Start PDU")
        peripheral?.writeValue(start.toGATTPDU(), for: char, type: .withoutResponse)
        state = .startSent
        startTimeout()

        // Generate and send our public key immediately after Start
        sendPublicKey()
    }

    private func sendPublicKey() {
        guard let char = provisioningDataIn else {
            fail(with: .bleError("Provisioning characteristic not found"))
            return
        }

        do {
            let pubKey = try crypto.generateKeyPair()
            let pdu = ProvisioningPublicKey(publicKey: pubKey)

            log("Sending Public Key PDU (\(pubKey.count) bytes)")
            peripheral?.writeValue(pdu.toGATTPDU(), for: char, type: .withoutResponse)
            state = .publicKeySent
            startTimeout()
        } catch {
            fail(with: .keyGenerationFailed(error.localizedDescription))
        }
    }

    private func handleDevicePublicKey(_ pubKey: [UInt8]) {
        guard state == .publicKeySent else {
            log("Unexpected public key in state \(state)")
            return
        }

        state = .publicKeyReceived
        log("Received device public key")

        do {
            // Compute shared secret
            _ = try crypto.computeSharedSecret(devicePublicKey: pubKey)

            // Build confirmation inputs
            guard let invite = invitePDU,
                  let caps = capabilitiesPDU,
                  let start = startPDU else {
                fail(with: .confirmationInputsMissing)
                return
            }

            try crypto.buildConfirmationInputs(
                invitePDU: invite,
                capabilitiesPDU: caps,
                startPDU: start
            )

            // Derive confirmation key
            try crypto.deriveConfirmationKey()

            // Send our confirmation
            sendConfirmation()

        } catch let error as ProvisioningError {
            fail(with: error)
        } catch {
            fail(with: .sharedSecretFailed(error.localizedDescription))
        }
    }

    private func sendConfirmation() {
        guard let char = provisioningDataIn else {
            fail(with: .bleError("Provisioning characteristic not found"))
            return
        }

        do {
            let random = crypto.generateProvisionerRandom()
            let confirmation = try crypto.calculateConfirmation(random: random, authValue: authValue)

            let pdu = ProvisioningConfirmation(confirmation: confirmation)

            log("Sending Confirmation PDU")
            peripheral?.writeValue(pdu.toGATTPDU(), for: char, type: .withoutResponse)
            state = .confirmationSent
            startTimeout()
        } catch let error as ProvisioningError {
            fail(with: error)
        } catch {
            fail(with: .encryptionFailed(error.localizedDescription))
        }
    }

    private func handleDeviceConfirmation(_ confirmation: [UInt8]) {
        guard state == .confirmationSent else {
            log("Unexpected confirmation in state \(state)")
            return
        }

        state = .confirmationReceived
        log("Received device confirmation: \(confirmation.map { String(format: "%02X", $0) }.joined())")

        // Store for verification after receiving device random
        deviceConfirmation = confirmation

        // Send our random to get device's random for verification
        sendRandom()
    }

    private func sendRandom() {
        guard let char = provisioningDataIn else {
            fail(with: .bleError("Provisioning characteristic not found"))
            return
        }

        guard let random = crypto.provisionerRandom else {
            fail(with: .randomMissing)
            return
        }

        let pdu = ProvisioningRandom(random: random)

        log("Sending Random PDU")
        peripheral?.writeValue(pdu.toGATTPDU(), for: char, type: .withoutResponse)
        state = .randomSent
        startTimeout()
    }

    private func handleDeviceRandom(_ random: [UInt8]) {
        guard state == .randomSent else {
            log("Unexpected random in state \(state)")
            return
        }

        state = .randomReceived
        log("Received device random: \(random.map { String(format: "%02X", $0) }.joined())")

        crypto.setDeviceRandom(random)

        // Verify device confirmation to detect key derivation issues early
        do {
            let expectedConfirmation = try crypto.calculateConfirmation(
                random: random,
                authValue: authValue
            )

            if let storedConfirmation = deviceConfirmation {
                if storedConfirmation == expectedConfirmation {
                    log("Device confirmation verified successfully!")
                } else {
                    log("WARNING: Device confirmation mismatch!")
                    log("  Expected: \(expectedConfirmation.map { String(format: "%02X", $0) }.joined())")
                    log("  Received: \(storedConfirmation.map { String(format: "%02X", $0) }.joined())")
                    log("  This indicates ECDH shared secret or auth value mismatch")
                    // Continue anyway to see the decryption failure for debugging
                }
            } else {
                log("WARNING: No stored device confirmation to verify")
            }
        } catch {
            log("WARNING: Failed to calculate expected confirmation: \(error)")
        }

        do {
            // Derive session keys
            try crypto.deriveSessionKeys()

            // Send provisioning data
            sendProvisioningData()
        } catch let error as ProvisioningError {
            fail(with: error)
        } catch {
            fail(with: .sessionKeyMissing)
        }
    }

    private func sendProvisioningData() {
        guard let char = provisioningDataIn else {
            fail(with: .bleError("Provisioning characteristic not found"))
            return
        }

        do {
            // Encrypt provisioning data
            // Flags: bit 0 = Key Refresh, bit 1 = IV Update (both 0)
            let encryptedData = try crypto.encryptProvisioningData(
                networkKey: networkKey,
                keyIndex: keyIndex,
                flags: 0x00,
                ivIndex: ivIndex,
                unicastAddress: unicastAddress
            )

            let pdu = ProvisioningData(encryptedData: encryptedData)

            log("Sending Provisioning Data PDU")
            peripheral?.writeValue(pdu.toGATTPDU(), for: char, type: .withoutResponse)
            state = .dataSent
            startTimeout()
        } catch let error as ProvisioningError {
            fail(with: error)
        } catch {
            fail(with: .encryptionFailed(error.localizedDescription))
        }
    }

    private func handleComplete() {
        guard state == .dataSent else {
            log("Unexpected complete in state \(state)")
            return
        }

        log("Device confirmed provisioning complete!")

        guard let deviceKey = crypto.deviceKey else {
            fail(with: .sessionKeyMissing)
            return
        }

        succeed(deviceKey: deviceKey)
    }

    private func handleFailed(_ errorCode: ProvisioningFailureCode) {
        log("Device reported failure: \(errorCode.description)")
        fail(with: .provisioningFailed(errorCode.rawValue))
    }

    // MARK: - PDU Reception

    private func handleReceivedPDU(_ data: Data) {
        guard let parsed = ProvisioningPDUParser.parse(data) else {
            log("Failed to parse PDU: \(data.map { String(format: "%02X", $0) }.joined())")
            return
        }

        switch parsed {
        case .capabilities(let caps):
            handleCapabilities(caps)

        case .publicKey(let pubKey):
            handleDevicePublicKey(pubKey)

        case .confirmation(let conf):
            handleDeviceConfirmation(conf)

        case .random(let random):
            handleDeviceRandom(random)

        case .complete:
            handleComplete()

        case .failed(let code):
            handleFailed(code)

        case .unknown(let type):
            log("Unknown PDU type: \(type)")
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension ProvisioningManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // State updates handled by main BLEManager
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("Connected to \(peripheral.name ?? "Unknown")")
        // Restore delegate now that we're connected - we only need peripheral callbacks from here
        restoreDelegate()
        state = .discoveringServices
        peripheral.discoverServices([provisioningServiceUUID])
        startTimeout()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("Failed to connect: \(error?.localizedDescription ?? "Unknown")")
        fail(with: .bleError(error?.localizedDescription ?? "Connection failed"))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if !state.isTerminal {
            log("Disconnected unexpectedly")
            fail(with: .bleError("Disconnected"))
        }
    }
}

// MARK: - CBPeripheralDelegate

extension ProvisioningManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            log("Service discovery error: \(error.localizedDescription)")
            fail(with: .bleError(error.localizedDescription))
            return
        }

        guard let services = peripheral.services else {
            fail(with: .bleError("No services found"))
            return
        }

        log("Discovered \(services.count) services")

        for service in services {
            if service.uuid == provisioningServiceUUID {
                log("Found provisioning service (1827)")
                peripheral.discoverCharacteristics(
                    [provisioningDataInUUID, provisioningDataOutUUID],
                    for: service
                )
                return
            }
        }

        fail(with: .bleError("Provisioning service not found"))
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            log("Characteristic discovery error: \(error.localizedDescription)")
            fail(with: .bleError(error.localizedDescription))
            return
        }

        guard let characteristics = service.characteristics else {
            fail(with: .bleError("No characteristics found"))
            return
        }

        for char in characteristics {
            if char.uuid == provisioningDataInUUID {
                provisioningDataIn = char
                log("Found Provisioning Data In (2ADB)")
            } else if char.uuid == provisioningDataOutUUID {
                provisioningDataOut = char
                log("Found Provisioning Data Out (2ADC)")
                // Subscribe to notifications
                peripheral.setNotifyValue(true, for: char)
            }
        }

        if provisioningDataIn != nil && provisioningDataOut != nil {
            state = .ready
            log("Ready to provision - sending invite")
            sendInvite()
        } else {
            fail(with: .bleError("Missing provisioning characteristics"))
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            log("Notification state error: \(error.localizedDescription)")
        } else {
            log("Notifications enabled for \(characteristic.uuid)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            log("Read error: \(error.localizedDescription)")
            return
        }

        guard let data = characteristic.value else { return }

        log("Received PDU (\(data.count) bytes): \(data.map { String(format: "%02X", $0) }.joined())")
        handleReceivedPDU(data)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            log("Write error: \(error.localizedDescription)")
            // Don't fail immediately - some writes may be expected to fail
        }
    }
}

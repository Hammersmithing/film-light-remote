import Foundation
import CoreBluetooth

/// Handles post-provisioning configuration: AppKey Add + Model App Bind
/// These steps are required before light control commands will work.
class MeshConfigManager: ObservableObject {

    @Published var state: ConfigState = .idle
    @Published var statusMessage: String = ""

    enum ConfigState: Equatable {
        case idle
        case connecting
        case sendingAppKeyAdd
        case waitingAppKeyStatus
        case sendingModelBind
        case waitingModelBindStatus
        case complete
        case failed(String)
    }

    // MARK: - Config Opcodes

    // Config AppKey Add: opcode 0x00
    private static let opcodeAppKeyAdd: [UInt8] = [0x00]
    // Config AppKey Status: opcode 0x8003 → two bytes [0x80, 0x03]
    private static let opcodeAppKeyStatus: UInt16 = 0x8003

    // Config Model App Bind: opcode 0x803D
    private static let opcodeModelAppBind: [UInt8] = [0x80, 0x3D]
    // Config Model App Status: opcode 0x803E
    private static let opcodeModelAppStatus: UInt16 = 0x803E

    // Config Model Publication Set: opcode 0x03
    private static let opcodeModelPubSet: [UInt8] = [0x03]

    // Config Relay Set: opcode 0x8023
    private static let opcodeRelaySet: [UInt8] = [0x80, 0x23]

    // Config Model Subscription Add: opcode 0x801B (for SIG models, 2-byte model ID)
    private static let opcodeModelSubAddSIG: [UInt8] = [0x80, 0x1B]
    // Config Vendor Model Subscription Add: opcode 0x801C (for vendor models, 4-byte model ID)
    private static let opcodeModelSubAddVendor: [UInt8] = [0x80, 0x1C]

    // Standard SIG model IDs for Aputure lights
    private static let lightModels: [(id: UInt16, name: String)] = [
        (0x1000, "Generic OnOff Server"),
        (0x1300, "Light Lightness Server"),
        (0x1303, "Light CTL Server"),
        (0x1307, "Light HSL Server"),
    ]

    // Vendor model for Sidus/Telink: Company ID 0x0211, Model ID 0x0000
    // Wire format (LE): 11 02 00 00
    private static let vendorModelID: UInt32 = 0x00000211

    // MARK: - State

    private var deviceKey: [UInt8] = []
    private var unicastAddress: UInt16 = 0x0002
    private var networkKeyIndex: UInt16 = 0
    private var appKeyIndex: UInt16 = 0
    private var appKey: [UInt8] = []

    private var proxyDataIn: CBCharacteristic?
    private var peripheral: CBPeripheral?

    private var modelBindIndex = 0
    private var responseTimer: Timer?
    private var groupAddresses: [UInt16] = []
    private var groupSubIndex = 0
    private var groupModelSubIndex = 0  // tracks which model within current group address

    private var completion: ((Bool) -> Void)?

    // MARK: - Public

    /// Send only group subscriptions (for already-configured saved lights)
    func sendGroupSubscriptionsOnly(
        peripheral: CBPeripheral,
        proxyDataIn: CBCharacteristic,
        deviceAddress: UInt16,
        deviceKey: [UInt8],
        groupAddresses: [UInt16],
        completion: @escaping (Bool) -> Void
    ) {
        self.peripheral = peripheral
        self.proxyDataIn = proxyDataIn
        self.unicastAddress = deviceAddress
        self.deviceKey = deviceKey
        self.groupAddresses = groupAddresses
        self.groupSubIndex = 0
        self.groupModelSubIndex = 0
        self.completion = completion

        log("Enabling relay + sending \(groupAddresses.count) group subscription(s) x \(Self.subscriptionModels.count) models for device 0x\(String(format: "%04X", deviceAddress))")
        // Enable relay first, then send subscriptions
        sendRelaySet()
    }

    /// Run the full post-provisioning config sequence
    func configure(
        peripheral: CBPeripheral,
        proxyDataIn: CBCharacteristic,
        deviceAddress: UInt16,
        deviceKey: [UInt8],
        groupAddresses: [UInt16] = [],
        completion: @escaping (Bool) -> Void
    ) {
        self.peripheral = peripheral
        self.proxyDataIn = proxyDataIn
        self.unicastAddress = deviceAddress
        self.deviceKey = deviceKey
        self.groupAddresses = groupAddresses
        self.groupSubIndex = 0
        self.groupModelSubIndex = 0
        self.completion = completion

        let storage = KeyStorage.shared
        self.appKey = storage.getAppKeyOrDefault()
        self.networkKeyIndex = 0
        self.appKeyIndex = 0

        log("Starting configuration for device 0x\(String(format: "%04X", deviceAddress))")
        log("Device key: \(deviceKey.prefix(4).map { String(format: "%02X", $0) }.joined())...")
        if !groupAddresses.isEmpty {
            log("Will subscribe to \(groupAddresses.count) group(s): \(groupAddresses.map { String(format: "0x%04X", $0) }.joined(separator: ", "))")
        }

        sendAppKeyAdd()
    }

    /// Call this when data is received on 2ADE (proxy data out)
    func handleProxyResponse(_ data: Data) {
        // For now, we don't fully decrypt responses — we check timing
        // and proceed optimistically. The light will reject commands
        // if config actually failed.
        log("Received proxy response: \(data.map { String(format: "%02X", $0) }.joined(separator: " "))")
    }

    // MARK: - Config AppKey Add

    private func sendAppKeyAdd() {
        state = .sendingAppKeyAdd
        log("Sending Config AppKey Add...")

        // Payload: opcode (1 byte) + NetKeyIndex|AppKeyIndex (3 bytes) + AppKey (16 bytes)
        var payload: [UInt8] = Self.opcodeAppKeyAdd

        // Pack NetKeyIndex (12-bit) and AppKeyIndex (12-bit) into 3 bytes (little-endian)
        let packed = (UInt32(networkKeyIndex) & 0xFFF) | ((UInt32(appKeyIndex) & 0xFFF) << 12)
        payload.append(UInt8(packed & 0xFF))
        payload.append(UInt8((packed >> 8) & 0xFF))
        payload.append(UInt8((packed >> 16) & 0xFF))

        // Append the 16-byte app key
        payload.append(contentsOf: appKey)

        log("AppKey Add payload (\(payload.count) bytes): \(payload.map { String(format: "%02X", $0) }.joined(separator: " "))")

        // Encrypt with device key and send (may be multiple PDUs if segmented)
        guard let pdus = MeshCrypto.createDeviceKeyPDU(
            accessPayload: payload,
            deviceKey: deviceKey,
            dst: unicastAddress
        ) else {
            fail("Failed to create AppKey Add PDU")
            return
        }

        sendPDUs(pdus)

        state = .waitingAppKeyStatus

        // Proceed after a short delay (we can't easily decrypt the response yet)
        responseTimer?.invalidate()
        responseTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            self?.log("AppKey Add sent — proceeding to model binding")
            self?.modelBindIndex = 0
            self?.sendNextModelBind()
        }
    }

    // MARK: - Model App Bind

    private func sendNextModelBind() {
        // Bind SIG models first, then vendor model
        let allModels = Self.lightModels

        if modelBindIndex < allModels.count {
            let model = allModels[modelBindIndex]
            sendModelAppBind(modelID: UInt32(model.id), isSIG: true, name: model.name)
        } else if modelBindIndex == allModels.count {
            // Bind vendor model
            sendModelAppBind(modelID: Self.vendorModelID, isSIG: false, name: "Sidus Vendor Model")
        } else {
            // All models bound — now configure vendor model publication
            sendModelPublicationSet()
        }
    }

    private func sendModelAppBind(modelID: UInt32, isSIG: Bool, name: String) {
        state = .sendingModelBind
        log("Binding \(name) (0x\(String(format: isSIG ? "%04X" : "%08X", modelID)))...")

        // Payload: opcode (2 bytes) + element address (2) + app key index (2) + model id (2 or 4)
        var payload: [UInt8] = Self.opcodeModelAppBind

        // Element address (little-endian)
        payload.append(UInt8(unicastAddress & 0xFF))
        payload.append(UInt8((unicastAddress >> 8) & 0xFF))

        // App key index (little-endian)
        payload.append(UInt8(appKeyIndex & 0xFF))
        payload.append(UInt8((appKeyIndex >> 8) & 0xFF))

        if isSIG {
            // SIG model: 2 bytes (little-endian)
            payload.append(UInt8(modelID & 0xFF))
            payload.append(UInt8((modelID >> 8) & 0xFF))
        } else {
            // Vendor model: 4 bytes (little-endian)
            payload.append(UInt8(modelID & 0xFF))
            payload.append(UInt8((modelID >> 8) & 0xFF))
            payload.append(UInt8((modelID >> 16) & 0xFF))
            payload.append(UInt8((modelID >> 24) & 0xFF))
        }

        guard let pdus = MeshCrypto.createDeviceKeyPDU(
            accessPayload: payload,
            deviceKey: deviceKey,
            dst: unicastAddress
        ) else {
            fail("Failed to create Model App Bind PDU")
            return
        }

        sendPDUs(pdus)

        state = .waitingModelBindStatus
        modelBindIndex += 1

        // Proceed after delay
        responseTimer?.invalidate()
        responseTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            self?.sendNextModelBind()
        }
    }

    // MARK: - Model Publication Set

    /// Configure the vendor model to publish status to our provisioner address (0x0001).
    /// Without this, the light has no destination for status messages and won't report state changes.
    private func sendModelPublicationSet() {
        log("Setting vendor model publication address to 0x0001...")

        // Config Model Publication Set payload:
        //   Opcode: 0x03
        //   ElementAddress (2 bytes LE)
        //   PublishAddress (2 bytes LE) — our address 0x0001
        //   AppKeyIndex (12 bits) + CredentialFlag (1 bit) = 2 bytes
        //   PublishTTL (1 byte)
        //   PublishPeriod (1 byte) — Step Resolution | NumberOfSteps
        //   PublishRetransmit (1 byte) — Count(3) | IntervalSteps(5)
        //   ModelIdentifier (4 bytes for vendor model)
        var payload: [UInt8] = Self.opcodeModelPubSet

        // Element address (LE)
        payload.append(UInt8(unicastAddress & 0xFF))
        payload.append(UInt8((unicastAddress >> 8) & 0xFF))

        // Publish address = 0x0001 (our provisioner address)
        let publishAddress: UInt16 = 0x0001
        payload.append(UInt8(publishAddress & 0xFF))
        payload.append(UInt8((publishAddress >> 8) & 0xFF))

        // AppKeyIndex (12 bits) + CredentialFlag (1 bit), packed into 2 bytes LE
        let appKeyAndCred = UInt16(appKeyIndex & 0xFFF)  // CredentialFlag = 0
        payload.append(UInt8(appKeyAndCred & 0xFF))
        payload.append(UInt8((appKeyAndCred >> 8) & 0xFF))

        // Publish TTL
        payload.append(7)

        // Publish Period: Resolution=1 (1 second), Steps=5 → publish every 5 seconds
        // Bits 6-7 = Step Resolution (1 = 1s), Bits 0-5 = Number of Steps (5)
        let publishPeriod: UInt8 = (1 << 6) | 5  // 0x45
        payload.append(publishPeriod)

        // Retransmit: Count=0, IntervalSteps=0 (no retransmit)
        payload.append(0x00)

        // Vendor Model ID (4 bytes LE): company_id(2) + model_id(2)
        let modelID = Self.vendorModelID
        payload.append(UInt8(modelID & 0xFF))
        payload.append(UInt8((modelID >> 8) & 0xFF))
        payload.append(UInt8((modelID >> 16) & 0xFF))
        payload.append(UInt8((modelID >> 24) & 0xFF))

        log("Publication Set payload (\(payload.count) bytes): \(payload.map { String(format: "%02X", $0) }.joined(separator: " "))")

        guard let pdus = MeshCrypto.createDeviceKeyPDU(
            accessPayload: payload,
            deviceKey: deviceKey,
            dst: unicastAddress
        ) else {
            fail("Failed to create Model Publication Set PDU")
            return
        }

        sendPDUs(pdus)

        // Wait for response then enable relay
        responseTimer?.invalidate()
        responseTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            self?.log("Publication Set sent")
            self?.sendRelaySet()
        }
    }

    // MARK: - Relay Enable

    /// Enable relay on the light so it forwards mesh PDUs on the advertising bearer.
    /// Without this, group-addressed messages only reach the directly connected light.
    private func sendRelaySet() {
        log("Enabling relay...")

        // Config Relay Set payload:
        //   Opcode: 0x8023
        //   Relay (1 byte): 0x01 = enabled
        //   RelayRetransmitCount (3 bits) | RelayRetransmitIntervalSteps (5 bits)
        var payload: [UInt8] = Self.opcodeRelaySet
        payload.append(0x01)  // Relay = enabled
        // Retransmit: Count=3 (retransmit 3 times), IntervalSteps=2 (30ms intervals)
        let retransmit: UInt8 = (3 & 0x07) | ((2 & 0x1F) << 3)
        payload.append(retransmit)

        guard let pdus = MeshCrypto.createDeviceKeyPDU(
            accessPayload: payload,
            deviceKey: deviceKey,
            dst: unicastAddress
        ) else {
            fail("Failed to create Relay Set PDU")
            return
        }

        sendPDUs(pdus)

        responseTimer?.invalidate()
        responseTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            self?.log("Relay Set sent")
            self?.groupSubIndex = 0
            self?.groupModelSubIndex = 0
            self?.sendNextGroupSubscription()
        }
    }

    // MARK: - Group Subscriptions

    /// All models to subscribe: SIG models + vendor model (nil id = vendor)
    private static let subscriptionModels: [(id: UInt32, isSIG: Bool, name: String)] = [
        (0x1000, true, "Generic OnOff Server"),
        (0x1300, true, "Light Lightness Server"),
        (0x1303, true, "Light CTL Server"),
        (0x1307, true, "Light HSL Server"),
        (vendorModelID, false, "Sidus Vendor Model"),
    ]

    private func sendNextGroupSubscription() {
        let allModels = Self.subscriptionModels

        guard groupSubIndex < groupAddresses.count else {
            log("All group subscriptions sent — config complete")
            configComplete()
            return
        }

        // If we've subscribed all models for this group address, move to next group
        if groupModelSubIndex >= allModels.count {
            groupSubIndex += 1
            groupModelSubIndex = 0
            sendNextGroupSubscription()
            return
        }

        let groupAddr = groupAddresses[groupSubIndex]
        let model = allModels[groupModelSubIndex]

        log("Subscribing \(model.name) to group 0x\(String(format: "%04X", groupAddr))...")

        var payload: [UInt8]

        if model.isSIG {
            // SIG model: opcode 0x801B, 2-byte model ID
            payload = Self.opcodeModelSubAddSIG
            payload.append(UInt8(unicastAddress & 0xFF))
            payload.append(UInt8((unicastAddress >> 8) & 0xFF))
            payload.append(UInt8(groupAddr & 0xFF))
            payload.append(UInt8((groupAddr >> 8) & 0xFF))
            payload.append(UInt8(model.id & 0xFF))
            payload.append(UInt8((model.id >> 8) & 0xFF))
        } else {
            // Vendor model: opcode 0x801C, 4-byte model ID (company + model)
            payload = Self.opcodeModelSubAddVendor
            payload.append(UInt8(unicastAddress & 0xFF))
            payload.append(UInt8((unicastAddress >> 8) & 0xFF))
            payload.append(UInt8(groupAddr & 0xFF))
            payload.append(UInt8((groupAddr >> 8) & 0xFF))
            payload.append(UInt8(model.id & 0xFF))
            payload.append(UInt8((model.id >> 8) & 0xFF))
            payload.append(UInt8((model.id >> 16) & 0xFF))
            payload.append(UInt8((model.id >> 24) & 0xFF))
        }

        guard let pdus = MeshCrypto.createDeviceKeyPDU(
            accessPayload: payload,
            deviceKey: deviceKey,
            dst: unicastAddress
        ) else {
            fail("Failed to create Group Subscription Add PDU")
            return
        }

        sendPDUs(pdus)
        groupModelSubIndex += 1

        responseTimer?.invalidate()
        responseTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            self?.sendNextGroupSubscription()
        }
    }

    // MARK: - Completion

    private func configComplete() {
        state = .complete
        log("Configuration complete! Light is ready for control commands.")
        completion?(true)
        completion = nil
    }

    private func fail(_ message: String) {
        state = .failed(message)
        log("Configuration failed: \(message)")
        completion?(false)
        completion = nil
    }

    // MARK: - Send

    /// Write each proxy PDU as a separate GATT write with 50ms spacing.
    /// Each transport segment must be a separate write to the proxy characteristic.
    private func sendPDUs(_ pdus: [Data]) {
        guard let peripheral = peripheral, let char = proxyDataIn else {
            fail("No proxy connection")
            return
        }

        for (i, pdu) in pdus.enumerated() {
            let delay = Double(i) * 0.05  // 50ms between segments
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                peripheral.writeValue(pdu, for: char, type: .withoutResponse)
            }
        }
        log("Sent \(pdus.count) PDU(s) to proxy (\(pdus.map { $0.count }.reduce(0, +)) bytes total)")
    }

    private func log(_ message: String) {
        print("[MeshConfig] \(message)")
        DispatchQueue.main.async {
            self.statusMessage = message
        }
    }
}

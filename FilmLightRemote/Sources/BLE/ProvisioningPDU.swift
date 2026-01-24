import Foundation

/// Provisioning PDU types per Mesh Profile 5.4.1
enum ProvisioningPDUType: UInt8 {
    case invite = 0x00
    case capabilities = 0x01
    case start = 0x02
    case publicKey = 0x03
    case inputComplete = 0x04
    case confirmation = 0x05
    case random = 0x06
    case data = 0x07
    case complete = 0x08
    case failed = 0x09
}

/// Provisioning failure error codes per Mesh Profile 5.4.4
enum ProvisioningFailureCode: UInt8 {
    case prohibited = 0x00
    case invalidPDU = 0x01
    case invalidFormat = 0x02
    case unexpectedPDU = 0x03
    case confirmationFailed = 0x04
    case outOfResources = 0x05
    case decryptionFailed = 0x06
    case unexpectedError = 0x07
    case cannotAssignAddresses = 0x08

    var description: String {
        switch self {
        case .prohibited: return "Prohibited"
        case .invalidPDU: return "Invalid PDU"
        case .invalidFormat: return "Invalid Format"
        case .unexpectedPDU: return "Unexpected PDU"
        case .confirmationFailed: return "Confirmation Failed"
        case .outOfResources: return "Out of Resources"
        case .decryptionFailed: return "Decryption Failed"
        case .unexpectedError: return "Unexpected Error"
        case .cannotAssignAddresses: return "Cannot Assign Addresses"
        }
    }
}

// MARK: - Outgoing PDUs

/// Provisioning Invite PDU (Type 0x00)
/// Sent by provisioner to begin provisioning
struct ProvisioningInvite {
    /// Attention duration in seconds (0 = no attention)
    let attentionDuration: UInt8

    init(attentionDuration: UInt8 = 0) {
        self.attentionDuration = attentionDuration
    }

    /// Serialize to bytes (1 byte value for confirmation inputs)
    func toBytes() -> [UInt8] {
        return [attentionDuration]
    }

    /// Serialize to PDU with type prefix
    func toPDU() -> Data {
        var pdu: [UInt8] = [ProvisioningPDUType.invite.rawValue]
        pdu.append(contentsOf: toBytes())
        return Data(pdu)
    }

    /// Serialize to PB-GATT PDU (with Proxy header)
    func toGATTPDU() -> Data {
        // Proxy PDU header: SAR (2 bits) = 0 (complete), Type (6 bits) = 0x03 (Provisioning)
        var pdu: [UInt8] = [0x03]  // Proxy header for provisioning
        pdu.append(ProvisioningPDUType.invite.rawValue)
        pdu.append(contentsOf: toBytes())
        return Data(pdu)
    }
}

/// Provisioning Start PDU (Type 0x02)
/// Sent by provisioner to select provisioning method
struct ProvisioningStart {
    /// Algorithm: 0x00 = FIPS P-256 Elliptic Curve
    let algorithm: UInt8

    /// Public Key: 0x00 = No OOB Public Key, 0x01 = OOB Public Key
    let publicKeyType: UInt8

    /// Authentication Method
    let authMethod: UInt8

    /// Authentication Action (depends on method)
    let authAction: UInt8

    /// Authentication Size
    let authSize: UInt8

    /// Standard initialization with no OOB
    init(algorithm: UInt8 = 0x00,
         publicKeyType: UInt8 = 0x00,
         authMethod: UInt8 = 0x00,
         authAction: UInt8 = 0x00,
         authSize: UInt8 = 0x00) {
        self.algorithm = algorithm
        self.publicKeyType = publicKeyType
        self.authMethod = authMethod
        self.authAction = authAction
        self.authSize = authSize
    }

    /// Serialize to bytes (5 bytes for confirmation inputs)
    func toBytes() -> [UInt8] {
        return [algorithm, publicKeyType, authMethod, authAction, authSize]
    }

    /// Serialize to PDU with type prefix
    func toPDU() -> Data {
        var pdu: [UInt8] = [ProvisioningPDUType.start.rawValue]
        pdu.append(contentsOf: toBytes())
        return Data(pdu)
    }

    /// Serialize to PB-GATT PDU (with Proxy header)
    func toGATTPDU() -> Data {
        var pdu: [UInt8] = [0x03]  // Proxy header for provisioning
        pdu.append(ProvisioningPDUType.start.rawValue)
        pdu.append(contentsOf: toBytes())
        return Data(pdu)
    }
}

/// Provisioning Public Key PDU (Type 0x03)
/// Sent by provisioner with 64-byte ECDH P-256 public key
struct ProvisioningPublicKey {
    /// 64-byte public key (X || Y coordinates)
    let publicKey: [UInt8]

    init(publicKey: [UInt8]) {
        precondition(publicKey.count == 64, "Public key must be 64 bytes")
        self.publicKey = publicKey
    }

    /// Serialize to PDU with type prefix
    func toPDU() -> Data {
        var pdu: [UInt8] = [ProvisioningPDUType.publicKey.rawValue]
        pdu.append(contentsOf: publicKey)
        return Data(pdu)
    }

    /// Serialize to PB-GATT PDU (with Proxy header)
    func toGATTPDU() -> Data {
        var pdu: [UInt8] = [0x03]  // Proxy header for provisioning
        pdu.append(ProvisioningPDUType.publicKey.rawValue)
        pdu.append(contentsOf: publicKey)
        return Data(pdu)
    }
}

/// Provisioning Confirmation PDU (Type 0x05)
/// Sent by provisioner with 16-byte confirmation value
struct ProvisioningConfirmation {
    /// 16-byte confirmation value
    let confirmation: [UInt8]

    init(confirmation: [UInt8]) {
        precondition(confirmation.count == 16, "Confirmation must be 16 bytes")
        self.confirmation = confirmation
    }

    /// Serialize to PDU with type prefix
    func toPDU() -> Data {
        var pdu: [UInt8] = [ProvisioningPDUType.confirmation.rawValue]
        pdu.append(contentsOf: confirmation)
        return Data(pdu)
    }

    /// Serialize to PB-GATT PDU (with Proxy header)
    func toGATTPDU() -> Data {
        var pdu: [UInt8] = [0x03]  // Proxy header for provisioning
        pdu.append(ProvisioningPDUType.confirmation.rawValue)
        pdu.append(contentsOf: confirmation)
        return Data(pdu)
    }
}

/// Provisioning Random PDU (Type 0x06)
/// Sent by provisioner with 16-byte random value
struct ProvisioningRandom {
    /// 16-byte random value
    let random: [UInt8]

    init(random: [UInt8]) {
        precondition(random.count == 16, "Random must be 16 bytes")
        self.random = random
    }

    /// Serialize to PDU with type prefix
    func toPDU() -> Data {
        var pdu: [UInt8] = [ProvisioningPDUType.random.rawValue]
        pdu.append(contentsOf: random)
        return Data(pdu)
    }

    /// Serialize to PB-GATT PDU (with Proxy header)
    func toGATTPDU() -> Data {
        var pdu: [UInt8] = [0x03]  // Proxy header for provisioning
        pdu.append(ProvisioningPDUType.random.rawValue)
        pdu.append(contentsOf: random)
        return Data(pdu)
    }
}

/// Provisioning Data PDU (Type 0x07)
/// Sent by provisioner with encrypted network credentials
struct ProvisioningData {
    /// Encrypted data (25 bytes plaintext + 8 bytes MIC = 33 bytes)
    let encryptedData: [UInt8]

    init(encryptedData: [UInt8]) {
        precondition(encryptedData.count == 33, "Encrypted data must be 33 bytes (25 + 8 MIC)")
        self.encryptedData = encryptedData
    }

    /// Serialize to PDU with type prefix
    func toPDU() -> Data {
        var pdu: [UInt8] = [ProvisioningPDUType.data.rawValue]
        pdu.append(contentsOf: encryptedData)
        return Data(pdu)
    }

    /// Serialize to PB-GATT PDU (with Proxy header)
    func toGATTPDU() -> Data {
        var pdu: [UInt8] = [0x03]  // Proxy header for provisioning
        pdu.append(ProvisioningPDUType.data.rawValue)
        pdu.append(contentsOf: encryptedData)
        return Data(pdu)
    }
}

// MARK: - Incoming PDUs

/// Provisioning Capabilities PDU (Type 0x01)
/// Received from device describing its capabilities
struct ProvisioningCapabilities {
    /// Number of elements on the device
    let numberOfElements: UInt8

    /// Supported algorithms bitmap (bit 0 = FIPS P-256)
    let algorithms: UInt16

    /// Supported public key types bitmap
    let publicKeyType: UInt8

    /// Supported static OOB types bitmap
    let staticOOBType: UInt8

    /// Output OOB size
    let outputOOBSize: UInt8

    /// Output OOB actions bitmap
    let outputOOBAction: UInt16

    /// Input OOB size
    let inputOOBSize: UInt8

    /// Input OOB actions bitmap
    let inputOOBAction: UInt16

    /// Original PDU bytes (for confirmation inputs)
    let rawBytes: [UInt8]

    /// Parse capabilities from PDU data
    init?(from data: Data) {
        // Capabilities PDU is 11 bytes (after type byte):
        // Elements(1) + Algorithms(2) + PubKeyType(1) + StaticOOB(1) + OutSize(1) + OutAction(2) + InSize(1) + InAction(2)
        guard data.count >= 11 else {
            print("ProvisioningCapabilities: Invalid length \(data.count), expected 11")
            return nil
        }

        self.numberOfElements = data[data.startIndex]
        self.algorithms = UInt16(data[data.startIndex + 1]) << 8 | UInt16(data[data.startIndex + 2])
        self.publicKeyType = data[data.startIndex + 3]
        self.staticOOBType = data[data.startIndex + 4]
        self.outputOOBSize = data[data.startIndex + 5]
        self.outputOOBAction = UInt16(data[data.startIndex + 6]) << 8 | UInt16(data[data.startIndex + 7])
        self.inputOOBSize = data[data.startIndex + 8]
        self.inputOOBAction = UInt16(data[data.startIndex + 9]) << 8 | UInt16(data[data.startIndex + 10])
        self.rawBytes = Array(data.prefix(11))

        print("ProvisioningCapabilities: Elements=\(numberOfElements), Algorithms=\(String(format: "0x%04X", algorithms))")
    }

    /// Check if device supports FIPS P-256 algorithm
    var supportsFIPSP256: Bool {
        return (algorithms & 0x0001) != 0
    }
}

/// Provisioning Complete PDU (Type 0x08)
/// Received from device when provisioning succeeds
struct ProvisioningComplete {
    init() {}

    static func parse(from data: Data) -> ProvisioningComplete? {
        // Complete PDU has no additional data
        return ProvisioningComplete()
    }
}

/// Provisioning Failed PDU (Type 0x09)
/// Received from device when provisioning fails
struct ProvisioningFailed {
    let errorCode: ProvisioningFailureCode

    init?(from data: Data) {
        guard data.count >= 1 else { return nil }
        self.errorCode = ProvisioningFailureCode(rawValue: data[0]) ?? .unexpectedError
    }
}

// MARK: - PDU Parser

/// Parses incoming provisioning PDUs
struct ProvisioningPDUParser {

    enum ParsedPDU {
        case capabilities(ProvisioningCapabilities)
        case publicKey([UInt8])
        case confirmation([UInt8])
        case random([UInt8])
        case complete
        case failed(ProvisioningFailureCode)
        case unknown(UInt8)
    }

    /// Parse raw PDU data (with Proxy header)
    static func parse(_ data: Data) -> ParsedPDU? {
        // Incoming PDUs have Proxy header: first byte is SAR+Type
        // For provisioning PDUs, the header should be 0x03
        guard data.count >= 2 else { return nil }

        let proxyHeader = data[0]
        let messageType = proxyHeader & 0x3F  // Lower 6 bits

        // Verify it's a provisioning PDU (type 0x03)
        if messageType != 0x03 {
            print("ProvisioningPDUParser: Unexpected proxy message type: \(messageType)")
            // Try parsing without proxy header for backwards compatibility
            return parseRaw(data)
        }

        // Strip proxy header and parse the provisioning PDU
        return parseRaw(data.dropFirst())
    }

    /// Parse raw provisioning PDU (without Proxy header)
    private static func parseRaw(_ data: Data) -> ParsedPDU? {
        guard data.count >= 1 else { return nil }

        let type = data[data.startIndex]
        let payload = data.dropFirst()

        guard let pduType = ProvisioningPDUType(rawValue: type) else {
            return .unknown(type)
        }

        switch pduType {
        case .capabilities:
            guard let caps = ProvisioningCapabilities(from: Data(payload)) else {
                return nil
            }
            return .capabilities(caps)

        case .publicKey:
            guard payload.count == 64 else {
                print("ProvisioningPDUParser: Invalid public key length \(payload.count)")
                return nil
            }
            return .publicKey(Array(payload))

        case .confirmation:
            guard payload.count == 16 else {
                print("ProvisioningPDUParser: Invalid confirmation length \(payload.count)")
                return nil
            }
            return .confirmation(Array(payload))

        case .random:
            guard payload.count == 16 else {
                print("ProvisioningPDUParser: Invalid random length \(payload.count)")
                return nil
            }
            return .random(Array(payload))

        case .complete:
            return .complete

        case .failed:
            guard let failure = ProvisioningFailed(from: Data(payload)) else {
                return .failed(.unexpectedError)
            }
            return .failed(failure.errorCode)

        default:
            return .unknown(type)
        }
    }
}

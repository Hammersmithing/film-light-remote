import Foundation
import CryptoSwift

/// Bluetooth Mesh Cryptography implementation for Sidus/Aputure lights
/// Uses the extracted keys from Sidus Link APK
class MeshCrypto {

    // MARK: - Keys (from SidusMeshConfig)

    static let networkKey: [UInt8] = [
        0x7D, 0xD7, 0x36, 0x4C, 0xD8, 0x42, 0xAD, 0x18,
        0xC1, 0x7C, 0x74, 0x65, 0x6C, 0x69, 0x6E, 0x6B
    ]

    static let appKey: [UInt8] = [
        0x63, 0x96, 0x47, 0x71, 0x73, 0x4F, 0xBD, 0x76,
        0xE3, 0xB4, 0x74, 0x65, 0x6C, 0x69, 0x6E, 0x6B
    ]

    static let ivIndex: UInt32 = 0x12345678

    // MARK: - Derived Keys

    private static var encryptionKey: [UInt8]?
    private static var privacyKey: [UInt8]?
    private static var nid: UInt8 = 0
    private static var aid: UInt8 = 0

    // MARK: - Sequence Number

    private static var sequenceNumber: UInt32 = 1

    // MARK: - Initialization

    static func initialize() {
        print("MeshCrypto: Initializing with k2 derivation...")

        // Derive NID, encryption key, privacy key using k2 function
        let (derivedNid, encKey, privKey) = k2(n: networkKey, p: [0x00])

        nid = derivedNid
        encryptionKey = encKey
        privacyKey = privKey

        // Derive AID from app key using k4 function
        aid = k4(n: appKey)

        print("MeshCrypto: NID = \(String(format: "0x%02X", nid))")
        print("MeshCrypto: AID = \(String(format: "0x%02X", aid))")
        print("MeshCrypto: Encryption Key = \(encKey.map { String(format: "%02X", $0) }.joined(separator: " "))")
    }

    // MARK: - Create Mesh Proxy PDU

    /// Create an encrypted mesh network PDU for the given Sidus command payload
    static func createMeshProxyPDU(
        accessPayload: Data,
        dst: UInt16 = 0xC000,  // All devices group
        src: UInt16 = 0x0001,  // Our address
        ttl: UInt8 = 7
    ) -> Data? {
        if encryptionKey == nil {
            initialize()
        }

        guard let encKey = encryptionKey, let privKey = privacyKey else {
            print("MeshCrypto: Keys not initialized")
            return nil
        }

        // Increment sequence number
        sequenceNumber += 1
        let seq = sequenceNumber

        // Build access message with Sidus vendor opcode
        // Vendor opcode format: 0xC0-0xC3 + 2-byte vendor ID
        // Sidus uses opcode 0x26 which maps to vendor model
        var accessMessage: [UInt8] = [0xC0, 0x11, 0x02]  // Vendor opcode + Telink vendor ID (0x0211, little endian)
        accessMessage.append(contentsOf: accessPayload)

        print("MeshCrypto: Access message = \(accessMessage.map { String(format: "%02X", $0) }.joined(separator: " "))")

        // Encrypt access layer with app key (AES-CCM, 4-byte MIC for unsegmented)
        let appNonce = buildApplicationNonce(seq: seq, src: src, dst: dst, ivIndex: ivIndex)

        guard let encryptedAccess = aes_ccm_encrypt(
            key: appKey,
            nonce: appNonce,
            plaintext: accessMessage,
            micSize: 4
        ) else {
            print("MeshCrypto: Failed to encrypt access layer")
            return nil
        }

        print("MeshCrypto: Encrypted access = \(encryptedAccess.map { String(format: "%02X", $0) }.joined(separator: " "))")

        // Build lower transport PDU (unsegmented access message)
        // SEG=0, AKF=1, AID (6 bits)
        let ltpHeader: UInt8 = (0 << 7) | (1 << 6) | (aid & 0x3F)
        var lowerTransportPDU: [UInt8] = [ltpHeader]
        lowerTransportPDU.append(contentsOf: encryptedAccess)

        // Build network PDU
        let ivi = UInt8((ivIndex >> 31) & 0x01)
        let nidByte = (ivi << 7) | (nid & 0x7F)
        let ctlTtl: UInt8 = (0 << 7) | (ttl & 0x7F)  // CTL=0 for access message

        // Network nonce
        let netNonce = buildNetworkNonce(ctl: 0, ttl: ttl, seq: seq, src: src, ivIndex: ivIndex)

        // DST + Transport PDU for encryption
        var dstTransport: [UInt8] = [
            UInt8((dst >> 8) & 0xFF),
            UInt8(dst & 0xFF)
        ]
        dstTransport.append(contentsOf: lowerTransportPDU)

        // Encrypt with network key (4-byte NetMIC for unsegmented)
        guard let encryptedNet = aes_ccm_encrypt(
            key: encKey,
            nonce: netNonce,
            plaintext: dstTransport,
            micSize: 4
        ) else {
            print("MeshCrypto: Failed to encrypt network layer")
            return nil
        }

        // Obfuscate CTL/TTL, SEQ, SRC using privacy key
        let obfuscatedHeader = obfuscate(
            ctlTtl: ctlTtl,
            seq: seq,
            src: src,
            encDst: Array(encryptedNet.prefix(2)),
            privacyKey: privKey,
            ivIndex: ivIndex
        )

        // Build final network PDU
        var networkPDU: [UInt8] = [nidByte]
        networkPDU.append(contentsOf: obfuscatedHeader)
        networkPDU.append(contentsOf: encryptedNet)

        print("MeshCrypto: Network PDU = \(networkPDU.map { String(format: "%02X", $0) }.joined(separator: " "))")

        // Wrap in Mesh Proxy PDU (SAR=0, Type=0x01 for Network PDU)
        var proxyPDU: [UInt8] = [0x01]  // Complete message, Network PDU type
        proxyPDU.append(contentsOf: networkPDU)

        print("MeshCrypto: Proxy PDU = \(proxyPDU.map { String(format: "%02X", $0) }.joined(separator: " "))")

        return Data(proxyPDU)
    }

    // MARK: - Key Derivation Functions

    /// k2 function - derives NID, encryption key, privacy key from network key
    private static func k2(n: [UInt8], p: [UInt8]) -> (nid: UInt8, encryptionKey: [UInt8], privacyKey: [UInt8]) {
        // SALT = s1("smk2")
        let salt = s1(Array("smk2".utf8))

        // T = AES-CMAC(SALT, N)
        let t = aes_cmac(key: salt, message: n)

        // T0 = empty, T1 = AES-CMAC(T, T0 || P || 0x01)
        let t1 = aes_cmac(key: t, message: p + [0x01])

        // T2 = AES-CMAC(T, T1 || P || 0x02)
        let t2 = aes_cmac(key: t, message: t1 + p + [0x02])

        // T3 = AES-CMAC(T, T2 || P || 0x03)
        let t3 = aes_cmac(key: t, message: t2 + p + [0x03])

        // NID = (T1[15] & 0x7F)
        let nid = t1[15] & 0x7F

        // Encryption Key = T2
        // Privacy Key = T3
        return (nid, t2, t3)
    }

    /// k4 function - derives AID from app key
    private static func k4(n: [UInt8]) -> UInt8 {
        // SALT = s1("smk4")
        let salt = s1(Array("smk4".utf8))

        // T = AES-CMAC(SALT, N)
        let t = aes_cmac(key: salt, message: n)

        // AID = AES-CMAC(T, "id6" || 0x01)[15] & 0x3F
        let id6: [UInt8] = Array("id6".utf8) + [0x01]
        let result = aes_cmac(key: t, message: id6)

        return result[15] & 0x3F
    }

    /// s1 function - generates salt
    private static func s1(_ m: [UInt8]) -> [UInt8] {
        let zero = [UInt8](repeating: 0, count: 16)
        return aes_cmac(key: zero, message: m)
    }

    // MARK: - Nonce Builders

    private static func buildApplicationNonce(seq: UInt32, src: UInt16, dst: UInt16, ivIndex: UInt32) -> [UInt8] {
        var nonce = [UInt8](repeating: 0, count: 13)
        nonce[0] = 0x01  // Application nonce type
        nonce[1] = 0x00  // ASZMIC || Pad
        nonce[2] = UInt8((seq >> 16) & 0xFF)
        nonce[3] = UInt8((seq >> 8) & 0xFF)
        nonce[4] = UInt8(seq & 0xFF)
        nonce[5] = UInt8((src >> 8) & 0xFF)
        nonce[6] = UInt8(src & 0xFF)
        nonce[7] = UInt8((dst >> 8) & 0xFF)
        nonce[8] = UInt8(dst & 0xFF)
        nonce[9] = UInt8((ivIndex >> 24) & 0xFF)
        nonce[10] = UInt8((ivIndex >> 16) & 0xFF)
        nonce[11] = UInt8((ivIndex >> 8) & 0xFF)
        nonce[12] = UInt8(ivIndex & 0xFF)
        return nonce
    }

    private static func buildNetworkNonce(ctl: UInt8, ttl: UInt8, seq: UInt32, src: UInt16, ivIndex: UInt32) -> [UInt8] {
        var nonce = [UInt8](repeating: 0, count: 13)
        nonce[0] = 0x00  // Network nonce type
        nonce[1] = (ctl << 7) | (ttl & 0x7F)
        nonce[2] = UInt8((seq >> 16) & 0xFF)
        nonce[3] = UInt8((seq >> 8) & 0xFF)
        nonce[4] = UInt8(seq & 0xFF)
        nonce[5] = UInt8((src >> 8) & 0xFF)
        nonce[6] = UInt8(src & 0xFF)
        nonce[7] = 0x00  // Pad
        nonce[8] = 0x00  // Pad
        nonce[9] = UInt8((ivIndex >> 24) & 0xFF)
        nonce[10] = UInt8((ivIndex >> 16) & 0xFF)
        nonce[11] = UInt8((ivIndex >> 8) & 0xFF)
        nonce[12] = UInt8(ivIndex & 0xFF)
        return nonce
    }

    // MARK: - Obfuscation

    private static func obfuscate(ctlTtl: UInt8, seq: UInt32, src: UInt16, encDst: [UInt8], privacyKey: [UInt8], ivIndex: UInt32) -> [UInt8] {
        // Privacy Random = EncDST[0:5] || Encrypted Transport PDU[0]
        // Since we only have 2 bytes of encDst, pad with zeros
        var privacyRandom = encDst
        while privacyRandom.count < 7 {
            privacyRandom.append(0x00)
        }

        // PECB = AES(PrivacyKey, 0x0000000000 || IV Index || Privacy Random)
        var pecbInput: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x00]
        pecbInput.append(UInt8((ivIndex >> 24) & 0xFF))
        pecbInput.append(UInt8((ivIndex >> 16) & 0xFF))
        pecbInput.append(UInt8((ivIndex >> 8) & 0xFF))
        pecbInput.append(UInt8(ivIndex & 0xFF))
        pecbInput.append(contentsOf: Array(privacyRandom.prefix(7)))

        let pecb = aes_encrypt(key: privacyKey, plaintext: pecbInput)

        // ObfuscatedData = (CTL || TTL || SEQ || SRC) XOR PECB[0:5]
        var header: [UInt8] = [
            ctlTtl,
            UInt8((seq >> 16) & 0xFF),
            UInt8((seq >> 8) & 0xFF),
            UInt8(seq & 0xFF),
            UInt8((src >> 8) & 0xFF),
            UInt8(src & 0xFF)
        ]

        for i in 0..<6 {
            header[i] ^= pecb[i]
        }

        return header
    }

    // MARK: - Crypto Primitives

    /// AES-CMAC using CryptoSwift
    private static func aes_cmac(key: [UInt8], message: [UInt8]) -> [UInt8] {
        do {
            let cmac = try CMAC(key: key).authenticate(message)
            return cmac
        } catch {
            print("MeshCrypto: AES-CMAC error: \(error)")
            return [UInt8](repeating: 0, count: 16)
        }
    }

    /// AES-128 ECB encrypt single block
    private static func aes_encrypt(key: [UInt8], plaintext: [UInt8]) -> [UInt8] {
        do {
            let aes = try AES(key: key, blockMode: ECB(), padding: .noPadding)
            return try aes.encrypt(plaintext)
        } catch {
            print("MeshCrypto: AES encrypt error: \(error)")
            return [UInt8](repeating: 0, count: 16)
        }
    }

    /// AES-CCM encrypt using CryptoSwift
    private static func aes_ccm_encrypt(key: [UInt8], nonce: [UInt8], plaintext: [UInt8], micSize: Int) -> [UInt8]? {
        do {
            // CryptoSwift CCM mode
            let ccm = CCM(iv: nonce, tagLength: micSize, messageLength: plaintext.count)
            let aes = try AES(key: key, blockMode: ccm, padding: .noPadding)
            let encrypted = try aes.encrypt(plaintext)
            return encrypted
        } catch {
            print("MeshCrypto: AES-CCM encrypt error: \(error)")
            return nil
        }
    }
}

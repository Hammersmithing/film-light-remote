import Foundation
import CryptoSwift

/// Bluetooth Mesh Cryptography implementation for Sidus/Aputure lights
/// Uses keys from KeyStorage (which may be provisioned keys or default Sidus keys)
class MeshCrypto {

    // MARK: - Keys (loaded from KeyStorage)

    private static var networkKey: [UInt8] = []
    private static var appKey: [UInt8] = []
    private static var ivIndex: UInt32 = 0x12345678

    // MARK: - Derived Keys

    private static var encryptionKey: [UInt8]?
    private static var privacyKey: [UInt8]?
    private static var nid: UInt8 = 0
    private static var aid: UInt8 = 0

    // MARK: - Observed Network Parameters (from light's beacon)

    static var observedNID: UInt8? = nil  // NID seen in light's mesh beacon
    static var useObservedNID: Bool = false  // Use calculated NID from our network key

    // MARK: - Sequence Number

    private static var sequenceNumber: UInt32 = 0x010000  // Start high to avoid replay rejection

    // MARK: - Key State

    private static var isInitialized = false

    // MARK: - Initialization

    /// Initialize or reinitialize with keys from KeyStorage
    static func initialize() {
        let storage = KeyStorage.shared

        // Load keys from KeyStorage (set during provisioning)
        networkKey = storage.getNetworkKeyOrDefault()
        appKey = storage.getAppKeyOrDefault()
        ivIndex = storage.ivIndex

        print("MeshCrypto: Network Key = \(networkKey.map { String(format: "%02X", $0) }.joined())")
        print("MeshCrypto: App Key = \(appKey.map { String(format: "%02X", $0) }.joined())")
        print("MeshCrypto: IV Index = 0x\(String(format: "%08X", ivIndex))")

        // Derive NID, encryption key, privacy key using k2 function
        let (derivedNid, encKey, privKey) = k2(n: networkKey, p: [0x00])

        nid = derivedNid
        encryptionKey = encKey
        privacyKey = privKey

        // Derive AID from app key using k4 function
        aid = k4(n: appKey)

        isInitialized = true

        print("MeshCrypto: NID = \(String(format: "0x%02X", nid))")
        print("MeshCrypto: AID = \(String(format: "0x%02X", aid))")
        print("MeshCrypto: Encryption Key = \(encKey.map { String(format: "%02X", $0) }.joined())")

        storage.printDebugInfo()
    }

    /// Force reinitialization (call after keys change, e.g., after provisioning)
    static func reinitialize() {
        isInitialized = false
        encryptionKey = nil
        privacyKey = nil
        initialize()
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
        // Vendor opcode format: 0xC0 + 2-byte vendor ID (Telink = 0x0211, little endian)
        // Then Sidus sub-opcode (0x26 = 38) followed by payload
        var accessMessage: [UInt8] = [0xC0, 0x11, 0x02, 0x26]  // Vendor opcode + Telink vendor ID + Sidus opcode
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
        // Try using observed NID from light if available (for key mismatch debugging)
        var finalNidByte = nidByte
        if useObservedNID, let obsNID = observedNID {
            finalNidByte = (ivi << 7) | (obsNID & 0x7F)
            print("MeshCrypto: Using OBSERVED NID = \(String(format: "0x%02X", obsNID)) instead of calculated \(String(format: "0x%02X", nid))")
        }

        var networkPDU: [UInt8] = [finalNidByte]
        networkPDU.append(contentsOf: obfuscatedHeader)
        networkPDU.append(contentsOf: encryptedNet)

        print("MeshCrypto: Network PDU = \(networkPDU.map { String(format: "%02X", $0) }.joined(separator: " "))")

        // Wrap in Mesh Proxy PDU (SAR=0, Type=0x01 for Network PDU)
        var proxyPDU: [UInt8] = [0x01]  // Complete message, Network PDU type
        proxyPDU.append(contentsOf: networkPDU)

        print("MeshCrypto: Proxy PDU = \(proxyPDU.map { String(format: "%02X", $0) }.joined(separator: " "))")

        return Data(proxyPDU)
    }

    // MARK: - Device Key PDU (for Config messages)

    /// Create a mesh proxy PDU encrypted with the device key (AKF=0)
    /// Used for Config AppKey Add, Model App Bind, etc.
    static func createDeviceKeyPDU(
        accessPayload: [UInt8],
        deviceKey: [UInt8],
        dst: UInt16,
        src: UInt16 = 0x0001,
        ttl: UInt8 = 7
    ) -> Data? {
        if encryptionKey == nil {
            initialize()
        }

        guard let encKey = encryptionKey, let privKey = privacyKey else {
            print("MeshCrypto: Keys not initialized")
            return nil
        }

        sequenceNumber += 1
        let seq = sequenceNumber

        print("MeshCrypto: [DevKey] Access payload = \(accessPayload.map { String(format: "%02X", $0) }.joined(separator: " "))")

        // Device nonce (type 0x02)
        let devNonce = buildDeviceNonce(seq: seq, src: src, dst: dst, ivIndex: ivIndex)

        // Encrypt access layer with device key (AES-CCM, 4-byte MIC)
        guard let encryptedAccess = aes_ccm_encrypt(
            key: deviceKey,
            nonce: devNonce,
            plaintext: accessPayload,
            micSize: 4
        ) else {
            print("MeshCrypto: [DevKey] Failed to encrypt access layer")
            return nil
        }

        // Lower transport PDU: AKF=0, AID=0x00
        let ltpHeader: UInt8 = 0x00  // SEG=0, AKF=0, AID=0
        var lowerTransportPDU: [UInt8] = [ltpHeader]
        lowerTransportPDU.append(contentsOf: encryptedAccess)

        // Check if we need segmentation (max unsegmented = 15 bytes of upper transport)
        // Upper transport = encrypted access payload + 4 byte MIC
        if encryptedAccess.count > 15 {
            print("MeshCrypto: [DevKey] Message needs segmentation (\(encryptedAccess.count) bytes)")
            return createSegmentedDeviceKeyPDU(
                accessPayload: accessPayload,
                deviceKey: deviceKey,
                dst: dst, src: src, ttl: ttl,
                seq: seq
            )
        }

        // Build network PDU (same as app key path)
        let ivi = UInt8((ivIndex >> 31) & 0x01)
        let nidByte = (ivi << 7) | (nid & 0x7F)
        let ctlTtl: UInt8 = (0 << 7) | (ttl & 0x7F)

        let netNonce = buildNetworkNonce(ctl: 0, ttl: ttl, seq: seq, src: src, ivIndex: ivIndex)

        var dstTransport: [UInt8] = [
            UInt8((dst >> 8) & 0xFF),
            UInt8(dst & 0xFF)
        ]
        dstTransport.append(contentsOf: lowerTransportPDU)

        guard let encryptedNet = aes_ccm_encrypt(
            key: encKey,
            nonce: netNonce,
            plaintext: dstTransport,
            micSize: 4
        ) else {
            print("MeshCrypto: [DevKey] Failed to encrypt network layer")
            return nil
        }

        let obfuscatedHeader = obfuscate(
            ctlTtl: ctlTtl, seq: seq, src: src,
            encDst: Array(encryptedNet.prefix(2)),
            privacyKey: privKey, ivIndex: ivIndex
        )

        var networkPDU: [UInt8] = [nidByte]
        networkPDU.append(contentsOf: obfuscatedHeader)
        networkPDU.append(contentsOf: encryptedNet)

        // Wrap in proxy PDU
        var proxyPDU: [UInt8] = [0x01]  // Complete message, Network PDU type
        proxyPDU.append(contentsOf: networkPDU)

        print("MeshCrypto: [DevKey] Proxy PDU = \(proxyPDU.map { String(format: "%02X", $0) }.joined(separator: " "))")
        return Data(proxyPDU)
    }

    /// Create segmented device key PDU for messages > 15 bytes
    private static func createSegmentedDeviceKeyPDU(
        accessPayload: [UInt8],
        deviceKey: [UInt8],
        dst: UInt16, src: UInt16, ttl: UInt8,
        seq: UInt32
    ) -> Data? {
        guard let encKey = encryptionKey, let privKey = privacyKey else { return nil }

        // For segmented messages, use 8-byte TransMIC
        let devNonce = buildDeviceNonce(seq: seq, src: src, dst: dst, ivIndex: ivIndex)

        guard let encryptedAccess = aes_ccm_encrypt(
            key: deviceKey,
            nonce: devNonce,
            plaintext: accessPayload,
            micSize: 8  // 8-byte MIC for segmented
        ) else { return nil }

        // Segment the encrypted access PDU into 12-byte chunks
        let segmentSize = 12
        let totalSegments = (encryptedAccess.count + segmentSize - 1) / segmentSize
        let seqZero = seq & 0x1FFF  // 13-bit SeqZero

        var proxyPDUs: [UInt8] = []

        for segN in 0..<totalSegments {
            let isFirst = segN == 0
            let isLast = segN == totalSegments - 1
            let start = segN * segmentSize
            let end = min(start + segmentSize, encryptedAccess.count)
            let segmentData = Array(encryptedAccess[start..<end])

            // Segmented lower transport header (4 bytes):
            // SEG=1, AKF=0, AID=0x00 | SZMIC(1) + SeqZero(13) | SegO(5) + SegN(5)
            let byte0: UInt8 = 0x80  // SEG=1, AKF=0, AID=0
            let szmic: UInt8 = 1  // 8-byte TransMIC
            let byte1: UInt8 = (szmic << 7) | UInt8((seqZero >> 6) & 0x7F)
            let byte2: UInt8 = UInt8((seqZero & 0x3F) << 2) | UInt8((segN >> 3) & 0x03)
            let byte3: UInt8 = UInt8((segN & 0x07) << 5) | UInt8(totalSegments - 1)

            var lowerTransportPDU: [UInt8] = [byte0, byte1, byte2, byte3]
            lowerTransportPDU.append(contentsOf: segmentData)

            // Each segment gets its own sequence number
            let segSeq = seq + UInt32(segN)

            // Build network PDU
            let ivi = UInt8((ivIndex >> 31) & 0x01)
            let nidByte = (ivi << 7) | (nid & 0x7F)
            let ctlTtl: UInt8 = (0 << 7) | (ttl & 0x7F)

            let netNonce = buildNetworkNonce(ctl: 0, ttl: ttl, seq: segSeq, src: src, ivIndex: ivIndex)

            var dstTransport: [UInt8] = [
                UInt8((dst >> 8) & 0xFF),
                UInt8(dst & 0xFF)
            ]
            dstTransport.append(contentsOf: lowerTransportPDU)

            guard let encryptedNet = aes_ccm_encrypt(
                key: encKey, nonce: netNonce,
                plaintext: dstTransport, micSize: 8
            ) else { return nil }

            let obfuscatedHeader = obfuscate(
                ctlTtl: ctlTtl, seq: segSeq, src: src,
                encDst: Array(encryptedNet.prefix(2)),
                privacyKey: privKey, ivIndex: ivIndex
            )

            var networkPDU: [UInt8] = [nidByte]
            networkPDU.append(contentsOf: obfuscatedHeader)
            networkPDU.append(contentsOf: encryptedNet)

            // Proxy PDU SAR: first=0x40, continuation=0x80, last=0xC0, complete=0x00
            let sar: UInt8
            if totalSegments == 1 {
                sar = 0x01  // Complete, Network PDU
            } else if isFirst {
                sar = 0x41  // First segment
            } else if isLast {
                sar = 0xC1  // Last segment
            } else {
                sar = 0x81  // Continuation
            }

            proxyPDUs.append(sar)
            proxyPDUs.append(contentsOf: networkPDU)

            // Consume sequence numbers
            if segN > 0 {
                sequenceNumber += 1
            }
        }

        print("MeshCrypto: [DevKey] Segmented into \(totalSegments) segments")
        return Data(proxyPDUs)
    }

    // MARK: - Beacon Parsing

    /// Parse incoming mesh proxy PDU and extract network info
    static func parseIncomingPDU(_ data: Data) {
        guard data.count >= 2 else { return }

        let proxyHeader = data[0]
        let sarType = proxyHeader & 0x3F  // Lower 6 bits = message type

        if sarType == 0x01 {
            // Network PDU
            let nidByte = data[1]
            let ivi = (nidByte >> 7) & 0x01
            let incomingNID = nidByte & 0x7F

            print("MeshCrypto: Received Network PDU - IVI=\(ivi), NID=\(String(format: "0x%02X", incomingNID))")

            if observedNID == nil || observedNID != incomingNID {
                observedNID = incomingNID
                print("MeshCrypto: *** Stored observed NID = \(String(format: "0x%02X", incomingNID)) ***")
            }
        } else if sarType == 0x03 {
            // Mesh Beacon
            print("MeshCrypto: Received Mesh Beacon")
            if data.count >= 2 {
                let beaconType = data[1]
                print("MeshCrypto: Beacon type = \(beaconType)")
            }
        }
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

    /// s1 function - generates salt (used by provisioning)
    static func s1(_ m: [UInt8]) -> [UInt8] {
        let zero = [UInt8](repeating: 0, count: 16)
        return aes_cmac(key: zero, message: m)
    }

    /// k1 function - key derivation for provisioning
    /// k1(N, SALT, P) = AES-CMAC(AES-CMAC(SALT, N), P)
    static func k1(n: [UInt8], salt: [UInt8], p: [UInt8]) -> [UInt8] {
        let t = aes_cmac(key: salt, message: n)
        return aes_cmac(key: t, message: p)
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

    private static func buildDeviceNonce(seq: UInt32, src: UInt16, dst: UInt16, ivIndex: UInt32) -> [UInt8] {
        var nonce = [UInt8](repeating: 0, count: 13)
        nonce[0] = 0x02  // Device nonce type
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

    /// AES-CCM encrypt - Manual implementation per RFC 3610
    /// CryptoSwift CCM had compatibility issues, so we implement manually
    private static func aes_ccm_encrypt(key: [UInt8], nonce: [UInt8], plaintext: [UInt8], micSize: Int) -> [UInt8]? {
        guard nonce.count == 13 else {
            print("MeshCrypto: CCM nonce must be 13 bytes")
            return nil
        }
        guard micSize == 4 || micSize == 8 else {
            print("MeshCrypto: CCM MIC must be 4 or 8 bytes")
            return nil
        }

        // CCM parameters for 13-byte nonce: L = 2
        let L = 2

        // === Step 1: Generate MIC using CBC-MAC ===
        // B_0 flags: Reserved(1) | Adata(1) | M'(3) | L'(3)
        let flagsB0: UInt8 = UInt8(((micSize - 2) / 2) << 3) | UInt8(L - 1)

        var b0 = [UInt8](repeating: 0, count: 16)
        b0[0] = flagsB0
        for i in 0..<13 {
            b0[1 + i] = nonce[i]
        }
        b0[14] = UInt8((plaintext.count >> 8) & 0xFF)
        b0[15] = UInt8(plaintext.count & 0xFF)

        // CBC-MAC
        var cbcState = aes_encrypt(key: key, plaintext: b0)

        let numBlocks = (plaintext.count + 15) / 16
        for i in 0..<numBlocks {
            var block = [UInt8](repeating: 0, count: 16)
            let start = i * 16
            let end = min(start + 16, plaintext.count)
            for j in start..<end {
                block[j - start] = plaintext[j]
            }
            for j in 0..<16 {
                block[j] ^= cbcState[j]
            }
            cbcState = aes_encrypt(key: key, plaintext: block)
        }

        let tag = Array(cbcState.prefix(micSize))

        // === Step 2: CTR encryption ===
        let flagsCtr: UInt8 = UInt8(L - 1)

        // A_0 for encrypting the tag
        var a0 = [UInt8](repeating: 0, count: 16)
        a0[0] = flagsCtr
        for i in 0..<13 {
            a0[1 + i] = nonce[i]
        }
        a0[14] = 0
        a0[15] = 0

        let s0 = aes_encrypt(key: key, plaintext: a0)

        // Encrypt tag
        var mic = [UInt8](repeating: 0, count: micSize)
        for i in 0..<micSize {
            mic[i] = tag[i] ^ s0[i]
        }

        // Encrypt plaintext with A_1, A_2, ...
        var ciphertext = [UInt8](repeating: 0, count: plaintext.count)
        for i in 0..<numBlocks {
            let counter = i + 1
            var ai = [UInt8](repeating: 0, count: 16)
            ai[0] = flagsCtr
            for j in 0..<13 {
                ai[1 + j] = nonce[j]
            }
            ai[14] = UInt8((counter >> 8) & 0xFF)
            ai[15] = UInt8(counter & 0xFF)

            let si = aes_encrypt(key: key, plaintext: ai)

            let start = i * 16
            let end = min(start + 16, plaintext.count)
            for j in start..<end {
                ciphertext[j] = plaintext[j] ^ si[j - start]
            }
        }

        // Output = Ciphertext || MIC
        var result = ciphertext
        result.append(contentsOf: mic)
        return result
    }
}

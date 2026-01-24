import Foundation
import Security
import CryptoSwift

/// Handles Bluetooth Mesh Provisioning cryptographic operations
/// Implements ECDH P-256 key exchange and session key derivation per Mesh Profile 5.4
class ProvisioningCrypto {

    // MARK: - ECDH Key Pair

    private var privateKey: SecKey?
    private var publicKey: SecKey?

    /// Raw 64-byte public key (X || Y coordinates)
    private(set) var publicKeyBytes: [UInt8]?

    /// Device's public key (received during provisioning)
    private(set) var devicePublicKeyBytes: [UInt8]?

    /// Computed ECDH shared secret
    private(set) var sharedSecret: [UInt8]?

    // MARK: - Provisioning Parameters

    /// Confirmation inputs collected during provisioning
    private(set) var confirmationInputs: [UInt8] = []

    /// Provisioner's random value (16 bytes)
    private(set) var provisionerRandom: [UInt8]?

    /// Device's random value (16 bytes)
    private(set) var deviceRandom: [UInt8]?

    // MARK: - Derived Keys

    private(set) var confirmationSalt: [UInt8]?
    private(set) var confirmationKey: [UInt8]?
    private(set) var provisioningSalt: [UInt8]?
    private(set) var sessionKey: [UInt8]?
    private(set) var sessionNonce: [UInt8]?
    private(set) var deviceKey: [UInt8]?

    // MARK: - Initialization

    init() {}

    /// Reset all state for a new provisioning session
    func reset() {
        privateKey = nil
        publicKey = nil
        publicKeyBytes = nil
        devicePublicKeyBytes = nil
        sharedSecret = nil
        confirmationInputs = []
        provisionerRandom = nil
        deviceRandom = nil
        confirmationSalt = nil
        confirmationKey = nil
        provisioningSalt = nil
        sessionKey = nil
        sessionNonce = nil
        deviceKey = nil
    }

    // MARK: - ECDH Key Generation

    /// Generate ECDH P-256 key pair for provisioning
    /// Returns the raw 64-byte public key (X || Y coordinates)
    func generateKeyPair() throws -> [UInt8] {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: false
            ]
        ]

        var error: Unmanaged<CFError>?
        guard let privKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw ProvisioningError.keyGenerationFailed(error?.takeRetainedValue().localizedDescription ?? "Unknown error")
        }

        guard let pubKey = SecKeyCopyPublicKey(privKey) else {
            throw ProvisioningError.keyGenerationFailed("Failed to extract public key")
        }

        self.privateKey = privKey
        self.publicKey = pubKey

        // Extract raw public key bytes (X || Y, 64 bytes total)
        // The exported format is 04 || X || Y (65 bytes), we need just X || Y
        guard let pubKeyData = SecKeyCopyExternalRepresentation(pubKey, &error) as Data? else {
            throw ProvisioningError.keyGenerationFailed("Failed to export public key")
        }

        // Skip the 0x04 prefix (uncompressed point indicator)
        guard pubKeyData.count == 65 else {
            throw ProvisioningError.keyGenerationFailed("Unexpected public key length: \(pubKeyData.count)")
        }

        let rawPubKey = Array(pubKeyData.dropFirst())
        self.publicKeyBytes = rawPubKey

        print("ProvisioningCrypto: Generated ECDH P-256 key pair")
        print("ProvisioningCrypto: Public key (64 bytes): \(rawPubKey.prefix(16).map { String(format: "%02X", $0) }.joined())...")

        return rawPubKey
    }

    // MARK: - ECDH Shared Secret

    /// Compute ECDH shared secret from device's public key
    func computeSharedSecret(devicePublicKey: [UInt8]) throws -> [UInt8] {
        guard devicePublicKey.count == 64 else {
            throw ProvisioningError.invalidPublicKey("Device public key must be 64 bytes, got \(devicePublicKey.count)")
        }

        guard let privKey = privateKey else {
            throw ProvisioningError.keyNotGenerated
        }

        self.devicePublicKeyBytes = devicePublicKey

        // Reconstruct SEC1 format public key: 04 || X || Y
        var sec1Key = Data([0x04])
        sec1Key.append(contentsOf: devicePublicKey)

        // Create SecKey from device's public key
        let keyAttributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 256
        ]

        var error: Unmanaged<CFError>?
        guard let devicePubKey = SecKeyCreateWithData(sec1Key as CFData, keyAttributes as CFDictionary, &error) else {
            throw ProvisioningError.invalidPublicKey(error?.takeRetainedValue().localizedDescription ?? "Failed to parse device public key")
        }

        // Compute shared secret
        let algorithm = SecKeyAlgorithm.ecdhKeyExchangeStandard
        guard SecKeyIsAlgorithmSupported(privKey, .keyExchange, algorithm) else {
            throw ProvisioningError.algorithmNotSupported
        }

        guard let sharedSecretData = SecKeyCopyKeyExchangeResult(privKey, algorithm, devicePubKey, [:] as CFDictionary, &error) as Data? else {
            throw ProvisioningError.sharedSecretFailed(error?.takeRetainedValue().localizedDescription ?? "Key exchange failed")
        }

        let secret = Array(sharedSecretData)
        self.sharedSecret = secret

        print("ProvisioningCrypto: Computed ECDH shared secret (\(secret.count) bytes)")
        print("ProvisioningCrypto: SharedSecret: \(secret.map { String(format: "%02X", $0) }.joined())")

        return secret
    }

    // MARK: - Confirmation Inputs

    /// Build confirmation inputs from provisioning PDUs
    /// ConfirmationInputs = ProvisioningInvitePDUValue || ProvisioningCapabilitiesPDUValue || ProvisioningStartPDUValue || PublicKeyProvisioner || PublicKeyDevice
    func buildConfirmationInputs(
        invitePDU: [UInt8],
        capabilitiesPDU: [UInt8],
        startPDU: [UInt8]
    ) throws {
        guard let provPubKey = publicKeyBytes else {
            throw ProvisioningError.keyNotGenerated
        }
        guard let devPubKey = devicePublicKeyBytes else {
            throw ProvisioningError.deviceKeyMissing
        }

        var inputs: [UInt8] = []
        inputs.append(contentsOf: invitePDU)
        inputs.append(contentsOf: capabilitiesPDU)
        inputs.append(contentsOf: startPDU)
        inputs.append(contentsOf: provPubKey)
        inputs.append(contentsOf: devPubKey)

        self.confirmationInputs = inputs

        print("ProvisioningCrypto: Built confirmation inputs (\(inputs.count) bytes)")
        print("ProvisioningCrypto:   InvitePDU: \(invitePDU.map { String(format: "%02X", $0) }.joined())")
        print("ProvisioningCrypto:   CapsPDU: \(capabilitiesPDU.map { String(format: "%02X", $0) }.joined())")
        print("ProvisioningCrypto:   StartPDU: \(startPDU.map { String(format: "%02X", $0) }.joined())")
        print("ProvisioningCrypto:   ProvPubKey: \(provPubKey.prefix(8).map { String(format: "%02X", $0) }.joined())...")
        print("ProvisioningCrypto:   DevPubKey: \(devPubKey.prefix(8).map { String(format: "%02X", $0) }.joined())...")
    }

    // MARK: - Key Derivation

    /// Derive confirmation salt and key
    /// ConfirmationSalt = s1(ConfirmationInputs)
    /// ConfirmationKey = k1(ECDHSecret, ConfirmationSalt, "prck")
    func deriveConfirmationKey() throws {
        guard !confirmationInputs.isEmpty else {
            throw ProvisioningError.confirmationInputsMissing
        }
        guard let secret = sharedSecret else {
            throw ProvisioningError.sharedSecretMissing
        }

        print("ProvisioningCrypto: Deriving confirmation key...")
        print("ProvisioningCrypto:   ConfirmationInputs (\(confirmationInputs.count) bytes)")

        // ConfirmationSalt = s1(ConfirmationInputs)
        let confSalt = MeshCrypto.s1(confirmationInputs)
        self.confirmationSalt = confSalt

        print("ProvisioningCrypto:   ConfirmationSalt: \(confSalt.map { String(format: "%02X", $0) }.joined())")

        // ConfirmationKey = k1(ECDHSecret, ConfirmationSalt, "prck")
        let confKey = k1(n: secret, salt: confSalt, p: Array("prck".utf8))
        self.confirmationKey = confKey

        print("ProvisioningCrypto:   ConfirmationKey: \(confKey.map { String(format: "%02X", $0) }.joined())")
    }

    /// Generate provisioner random value (16 bytes)
    func generateProvisionerRandom() -> [UInt8] {
        var random = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &random)
        self.provisionerRandom = random
        print("ProvisioningCrypto: Generated provisioner random")
        return random
    }

    /// Set device's random value (received from device)
    func setDeviceRandom(_ random: [UInt8]) {
        self.deviceRandom = random
        print("ProvisioningCrypto: Stored device random")
    }

    /// Calculate confirmation value
    /// Confirmation = AES-CMAC(ConfirmationKey, Random || AuthValue)
    func calculateConfirmation(random: [UInt8], authValue: [UInt8]) throws -> [UInt8] {
        guard let confKey = confirmationKey else {
            throw ProvisioningError.confirmationKeyMissing
        }

        var input = random
        input.append(contentsOf: authValue)

        return aesCmac(key: confKey, message: input)
    }

    // MARK: - Session Key Derivation

    /// Derive session keys after random exchange
    /// ProvisioningSalt = s1(ConfirmationSalt || ProvisionerRandom || DeviceRandom)
    /// SessionKey = k1(ECDHSecret, ProvisioningSalt, "prsk")
    /// SessionNonce = k1(ECDHSecret, ProvisioningSalt, "prsn")[0:13]
    /// DeviceKey = k1(ECDHSecret, ProvisioningSalt, "prdk")
    func deriveSessionKeys() throws {
        guard let confSalt = confirmationSalt else {
            throw ProvisioningError.confirmationKeyMissing
        }
        guard let provRandom = provisionerRandom else {
            throw ProvisioningError.randomMissing
        }
        guard let devRandom = deviceRandom else {
            throw ProvisioningError.randomMissing
        }
        guard let secret = sharedSecret else {
            throw ProvisioningError.sharedSecretMissing
        }

        // ProvisioningSalt = s1(ConfirmationSalt || ProvisionerRandom || DeviceRandom)
        var saltInput = confSalt
        saltInput.append(contentsOf: provRandom)
        saltInput.append(contentsOf: devRandom)

        print("ProvisioningCrypto: Session key derivation inputs:")
        print("ProvisioningCrypto:   ConfirmationSalt: \(confSalt.map { String(format: "%02X", $0) }.joined())")
        print("ProvisioningCrypto:   ProvisionerRandom: \(provRandom.map { String(format: "%02X", $0) }.joined())")
        print("ProvisioningCrypto:   DeviceRandom: \(devRandom.map { String(format: "%02X", $0) }.joined())")
        print("ProvisioningCrypto:   SaltInput (\(saltInput.count) bytes): \(saltInput.map { String(format: "%02X", $0) }.joined())")

        let provSalt = MeshCrypto.s1(saltInput)
        self.provisioningSalt = provSalt

        // SessionKey = k1(ECDHSecret, ProvisioningSalt, "prsk")
        let sessKey = k1(n: secret, salt: provSalt, p: Array("prsk".utf8))
        self.sessionKey = sessKey

        // SessionNonce = k1(ECDHSecret, ProvisioningSalt, "prsn") - last 13 bytes (drop first 3)
        let sessNonceFull = k1(n: secret, salt: provSalt, p: Array("prsn".utf8))
        self.sessionNonce = Array(sessNonceFull.dropFirst(3))

        // DeviceKey = k1(ECDHSecret, ProvisioningSalt, "prdk")
        let devKey = k1(n: secret, salt: provSalt, p: Array("prdk".utf8))
        self.deviceKey = devKey

        print("ProvisioningCrypto: Derived session keys")
        print("ProvisioningCrypto: ProvisioningSalt: \(provSalt.map { String(format: "%02X", $0) }.joined())")
        print("ProvisioningCrypto: SessionKey: \(sessKey.map { String(format: "%02X", $0) }.joined())")
        print("ProvisioningCrypto: SessionNonce: \(sessionNonce!.map { String(format: "%02X", $0) }.joined())")
        print("ProvisioningCrypto: DeviceKey: \(devKey.map { String(format: "%02X", $0) }.joined())")
    }

    // MARK: - Provisioning Data Encryption

    /// Encrypt provisioning data with AES-CCM
    /// Provisioning Data: NetworkKey(16) + KeyIndex(2) + Flags(1) + IVIndex(4) + UnicastAddr(2) = 25 bytes
    func encryptProvisioningData(
        networkKey: [UInt8],
        keyIndex: UInt16,
        flags: UInt8,
        ivIndex: UInt32,
        unicastAddress: UInt16
    ) throws -> [UInt8] {
        guard let sessKey = sessionKey else {
            throw ProvisioningError.sessionKeyMissing
        }
        guard let sessNonce = sessionNonce else {
            throw ProvisioningError.sessionKeyMissing
        }

        // Build plaintext (25 bytes)
        var plaintext: [UInt8] = []
        plaintext.append(contentsOf: networkKey)  // 16 bytes
        plaintext.append(UInt8((keyIndex >> 8) & 0xFF))  // KeyIndex (big-endian)
        plaintext.append(UInt8(keyIndex & 0xFF))
        plaintext.append(flags)  // Flags
        plaintext.append(UInt8((ivIndex >> 24) & 0xFF))  // IVIndex (big-endian)
        plaintext.append(UInt8((ivIndex >> 16) & 0xFF))
        plaintext.append(UInt8((ivIndex >> 8) & 0xFF))
        plaintext.append(UInt8(ivIndex & 0xFF))
        plaintext.append(UInt8((unicastAddress >> 8) & 0xFF))  // Unicast (big-endian)
        plaintext.append(UInt8(unicastAddress & 0xFF))

        print("ProvisioningCrypto: Provisioning data plaintext (\(plaintext.count) bytes):")
        print("ProvisioningCrypto:   NetworkKey: \(networkKey.map { String(format: "%02X", $0) }.joined())")
        print("ProvisioningCrypto:   KeyIndex: \(String(format: "0x%04X", keyIndex))")
        print("ProvisioningCrypto:   Flags: \(String(format: "0x%02X", flags))")
        print("ProvisioningCrypto:   IVIndex: \(String(format: "0x%08X", ivIndex))")
        print("ProvisioningCrypto:   UnicastAddr: \(String(format: "0x%04X", unicastAddress))")
        print("ProvisioningCrypto:   Plaintext hex: \(plaintext.map { String(format: "%02X", $0) }.joined())")

        // Encrypt with AES-CCM (8-byte MIC)
        let encrypted = try aesCcmEncrypt(key: sessKey, nonce: sessNonce, plaintext: plaintext, micSize: 8)

        print("ProvisioningCrypto: Encrypted provisioning data (\(encrypted.count) bytes): \(encrypted.map { String(format: "%02X", $0) }.joined())")

        return encrypted
    }

    // MARK: - Crypto Primitives

    /// k1 function: k1(N, SALT, P) = AES-CMAC(AES-CMAC(SALT, N), P)
    private func k1(n: [UInt8], salt: [UInt8], p: [UInt8]) -> [UInt8] {
        let t = aesCmac(key: salt, message: n)
        let result = aesCmac(key: t, message: p)
        print("ProvisioningCrypto: k1(\(n.map { String(format: "%02X", $0) }.joined().prefix(16))..., \(salt.map { String(format: "%02X", $0) }.joined().prefix(16))..., \"\(String(bytes: p, encoding: .utf8) ?? p.map { String(format: "%02X", $0) }.joined())\") = \(result.map { String(format: "%02X", $0) }.joined())")
        return result
    }

    /// AES-CMAC using CryptoSwift
    private func aesCmac(key: [UInt8], message: [UInt8]) -> [UInt8] {
        do {
            return try CMAC(key: key).authenticate(message)
        } catch {
            print("ProvisioningCrypto: AES-CMAC error: \(error)")
            return [UInt8](repeating: 0, count: 16)
        }
    }

    /// AES-CCM encryption - Manual implementation per RFC 3610 / Bluetooth Mesh spec
    /// This replaces CryptoSwift CCM which may have compatibility issues
    private func aesCcmEncrypt(key: [UInt8], nonce: [UInt8], plaintext: [UInt8], micSize: Int) throws -> [UInt8] {
        print("ProvisioningCrypto: AES-CCM encrypt inputs:")
        print("ProvisioningCrypto:   Key (\(key.count) bytes): \(key.map { String(format: "%02X", $0) }.joined())")
        print("ProvisioningCrypto:   Nonce (\(nonce.count) bytes): \(nonce.map { String(format: "%02X", $0) }.joined())")
        print("ProvisioningCrypto:   Plaintext (\(plaintext.count) bytes): \(plaintext.map { String(format: "%02X", $0) }.joined())")
        print("ProvisioningCrypto:   MIC size: \(micSize) bytes")

        guard nonce.count == 13 else {
            throw ProvisioningError.encryptionFailed("Nonce must be 13 bytes for Mesh CCM")
        }
        guard micSize == 4 || micSize == 8 else {
            throw ProvisioningError.encryptionFailed("MIC must be 4 or 8 bytes for Mesh CCM")
        }

        // CCM parameters for 13-byte nonce:
        // L = 15 - 13 = 2 (length field size, supports messages up to 65535 bytes)
        // M = micSize (4 or 8 bytes)
        let L = 2

        // === Step 1: Generate MIC using CBC-MAC ===
        // B_0 block format (RFC 3610 Section 2.2):
        // Flags (1) || Nonce (13) || message length (L=2 bytes, big-endian)
        // Flags = Reserved(1) | Adata(1) | M'(3) | L'(3)
        //       = 0 | 0 | ((M-2)/2) | (L-1)
        //       = 0 | 0 | ((micSize-2)/2 << 3) | 1
        let flagsB0: UInt8 = UInt8(((micSize - 2) / 2) << 3) | UInt8(L - 1)

        var b0 = [UInt8](repeating: 0, count: 16)
        b0[0] = flagsB0
        for i in 0..<13 {
            b0[1 + i] = nonce[i]
        }
        b0[14] = UInt8((plaintext.count >> 8) & 0xFF)
        b0[15] = UInt8(plaintext.count & 0xFF)

        print("ProvisioningCrypto:   B_0 flags: \(String(format: "0x%02X", flagsB0))")
        print("ProvisioningCrypto:   B_0: \(b0.map { String(format: "%02X", $0) }.joined())")

        // CBC-MAC: Start with B_0, then XOR and encrypt each plaintext block
        var cbcState = aesEncryptBlock(key: key, block: b0)

        // Process plaintext in 16-byte blocks (pad last block with zeros if needed)
        let numBlocks = (plaintext.count + 15) / 16
        for i in 0..<numBlocks {
            var block = [UInt8](repeating: 0, count: 16)
            let start = i * 16
            let end = min(start + 16, plaintext.count)
            for j in start..<end {
                block[j - start] = plaintext[j]
            }
            // XOR with previous CBC state
            for j in 0..<16 {
                block[j] ^= cbcState[j]
            }
            cbcState = aesEncryptBlock(key: key, block: block)
        }

        // T = first M bytes of final CBC-MAC state
        let tag = Array(cbcState.prefix(micSize))
        print("ProvisioningCrypto:   CBC-MAC tag (before CTR): \(tag.map { String(format: "%02X", $0) }.joined())")

        // === Step 2: CTR encryption ===
        // A_i counter block format (RFC 3610 Section 2.3):
        // Flags (1) || Nonce (13) || Counter (L=2 bytes, big-endian)
        // Flags = 0 | 0 | 0 | (L-1) = 1
        let flagsCtr: UInt8 = UInt8(L - 1)

        // A_0 is used to encrypt the tag
        var a0 = [UInt8](repeating: 0, count: 16)
        a0[0] = flagsCtr
        for i in 0..<13 {
            a0[1 + i] = nonce[i]
        }
        a0[14] = 0
        a0[15] = 0

        let s0 = aesEncryptBlock(key: key, block: a0)

        // Encrypt tag: MIC = T XOR S_0[0:M]
        var mic = [UInt8](repeating: 0, count: micSize)
        for i in 0..<micSize {
            mic[i] = tag[i] ^ s0[i]
        }
        print("ProvisioningCrypto:   S_0: \(s0.map { String(format: "%02X", $0) }.joined())")
        print("ProvisioningCrypto:   Final MIC: \(mic.map { String(format: "%02X", $0) }.joined())")

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

            let si = aesEncryptBlock(key: key, block: ai)

            let start = i * 16
            let end = min(start + 16, plaintext.count)
            for j in start..<end {
                ciphertext[j] = plaintext[j] ^ si[j - start]
            }
        }

        // Output = Ciphertext || MIC
        var result = ciphertext
        result.append(contentsOf: mic)

        print("ProvisioningCrypto:   Output (\(result.count) bytes): \(result.map { String(format: "%02X", $0) }.joined())")
        print("ProvisioningCrypto:   Ciphertext: \(ciphertext.map { String(format: "%02X", $0) }.joined())")

        return result
    }

    /// AES-128 ECB encrypt a single 16-byte block
    private func aesEncryptBlock(key: [UInt8], block: [UInt8]) -> [UInt8] {
        do {
            let aes = try AES(key: key, blockMode: ECB(), padding: .noPadding)
            return try aes.encrypt(block)
        } catch {
            print("ProvisioningCrypto: AES block encrypt error: \(error)")
            return [UInt8](repeating: 0, count: 16)
        }
    }
}

// MARK: - Provisioning Errors

enum ProvisioningError: LocalizedError {
    case keyGenerationFailed(String)
    case invalidPublicKey(String)
    case keyNotGenerated
    case deviceKeyMissing
    case algorithmNotSupported
    case sharedSecretFailed(String)
    case sharedSecretMissing
    case confirmationInputsMissing
    case confirmationKeyMissing
    case randomMissing
    case sessionKeyMissing
    case encryptionFailed(String)
    case timeout
    case invalidPDU(String)
    case provisioningFailed(UInt8)
    case unexpectedState
    case bleError(String)

    var errorDescription: String? {
        switch self {
        case .keyGenerationFailed(let msg): return "Key generation failed: \(msg)"
        case .invalidPublicKey(let msg): return "Invalid public key: \(msg)"
        case .keyNotGenerated: return "Key pair not generated"
        case .deviceKeyMissing: return "Device public key not received"
        case .algorithmNotSupported: return "ECDH algorithm not supported"
        case .sharedSecretFailed(let msg): return "Shared secret computation failed: \(msg)"
        case .sharedSecretMissing: return "Shared secret not computed"
        case .confirmationInputsMissing: return "Confirmation inputs not built"
        case .confirmationKeyMissing: return "Confirmation key not derived"
        case .randomMissing: return "Random values missing"
        case .sessionKeyMissing: return "Session keys not derived"
        case .encryptionFailed(let msg): return "Encryption failed: \(msg)"
        case .timeout: return "Provisioning timeout"
        case .invalidPDU(let msg): return "Invalid PDU: \(msg)"
        case .provisioningFailed(let code): return "Provisioning failed with code: \(code)"
        case .unexpectedState: return "Unexpected provisioning state"
        case .bleError(let msg): return "BLE error: \(msg)"
        }
    }
}

import Foundation

/// Sidus Mesh configuration with encryption keys extracted from Sidus Link APK
/// These are the default "Fast Provisioning" keys used by Aputure/Amaran lights
struct SidusMeshConfig {
    // MARK: - Default Mesh Keys (from FastProvisioningConfiguration.java)

    /// Default Network Key - used for mesh network layer encryption
    /// Last 6 bytes spell "telink" (Telink semiconductor)
    static let defaultNetworkKey = Data([
        0x7D, 0xD7, 0x36, 0x4C, 0xD8, 0x42, 0xAD, 0x18,
        0xC1, 0x7C, 0x74, 0x65, 0x6C, 0x69, 0x6E, 0x6B  // "telink"
    ])

    /// Default Application Key - used for application layer encryption
    static let defaultAppKey = Data([
        0x63, 0x96, 0x47, 0x71, 0x73, 0x4F, 0xBD, 0x76,
        0xE3, 0xB4, 0x74, 0x65, 0x6C, 0x69, 0x6E, 0x6B  // "telink"
    ])

    /// Default IV Index for mesh network
    static let defaultIVIndex: UInt32 = 0x12345678

    // MARK: - Key Indices

    static let defaultNetKeyIndex: UInt16 = 0
    static let defaultAppKeyIndex: UInt16 = 0

    // MARK: - AES Storage Key (from AES.java)

    /// Key used for app storage encryption (AES/ECB/PKCS7Padding)
    static let storageEncryptorKey = "SidusLink_SLCKfp"

    // MARK: - Message Configuration

    /// Default opcode for Sidus commands
    static let defaultOpcode: UInt8 = 38  // 0x26

    /// Default TTL (Time To Live) for mesh messages
    static let defaultTTL: UInt8 = 7

    /// All devices group address
    static let allDevicesGroup: UInt16 = 0xC000  // 49152

    // MARK: - Service UUIDs

    /// Mesh Proxy Service (primary control path)
    static let meshProxyServiceUUID = "1828"
    static let meshProxyDataInUUID = "2ADD"
    static let meshProxyDataOutUUID = "2ADE"

    /// Mesh Provisioning Service
    static let meshProvisioningServiceUUID = "1827"

    /// Custom Aputure Control Service
    static let aputureControlServiceUUID = "00010203-0405-0607-0809-0a0b0c0d1912"
    static let aputureControlCharacteristicUUID = "00010203-0405-0607-0809-0a0b0c0d2b12"

    /// Custom Aputure Status Service
    static let aputureStatusServiceUUID = "00010203-0405-0607-0809-0a0b0c0d7fde"
    static let aputureStatusCharacteristicUUID = "00010203-0405-0607-0809-0a0b0c0d7fdf"
}

// Extension to display Data as hex string
extension Data {
    var hexEncodedString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

import Foundation
import Security

/// Persistent storage for Bluetooth Mesh network keys and device keys
class KeyStorage {

    // MARK: - Singleton

    static let shared = KeyStorage()

    // MARK: - UserDefaults Keys

    private let networkKeyKey = "mesh.networkKey"
    private let appKeyKey = "mesh.appKey"
    private let ivIndexKey = "mesh.ivIndex"
    private let deviceKeysKey = "mesh.deviceKeys"
    private let nextUnicastAddressKey = "mesh.nextUnicastAddress"

    private let defaults = UserDefaults.standard

    // MARK: - Initialization

    private init() {
        // Generate keys on first use if not present
        if networkKey == nil {
            generateNetworkKey()
        }
        if appKey == nil {
            generateAppKey()
        }
    }

    // MARK: - Network Key

    /// The network key used for mesh encryption
    var networkKey: [UInt8]? {
        get {
            guard let data = defaults.data(forKey: networkKeyKey) else { return nil }
            return Array(data)
        }
        set {
            if let key = newValue {
                defaults.set(Data(key), forKey: networkKeyKey)
            } else {
                defaults.removeObject(forKey: networkKeyKey)
            }
        }
    }

    /// Generate a new random network key
    @discardableResult
    func generateNetworkKey() -> [UInt8] {
        var key = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &key)
        networkKey = key
        print("KeyStorage: Generated new network key")
        return key
    }

    /// Get network key, using default Sidus key if none stored
    func getNetworkKeyOrDefault() -> [UInt8] {
        return networkKey ?? Array(SidusMeshConfig.defaultNetworkKey)
    }

    // MARK: - Application Key

    /// The application key used for app-layer encryption
    var appKey: [UInt8]? {
        get {
            guard let data = defaults.data(forKey: appKeyKey) else { return nil }
            return Array(data)
        }
        set {
            if let key = newValue {
                defaults.set(Data(key), forKey: appKeyKey)
            } else {
                defaults.removeObject(forKey: appKeyKey)
            }
        }
    }

    /// Generate a new random application key
    @discardableResult
    func generateAppKey() -> [UInt8] {
        var key = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &key)
        appKey = key
        print("KeyStorage: Generated new app key")
        return key
    }

    /// Get app key, using default Sidus key if none stored
    func getAppKeyOrDefault() -> [UInt8] {
        return appKey ?? Array(SidusMeshConfig.defaultAppKey)
    }

    // MARK: - IV Index

    /// The current IV Index for the mesh network
    var ivIndex: UInt32 {
        get {
            let value = defaults.integer(forKey: ivIndexKey)
            return value == 0 ? SidusMeshConfig.defaultIVIndex : UInt32(value)
        }
        set {
            defaults.set(Int(newValue), forKey: ivIndexKey)
        }
    }

    // MARK: - Unicast Address Management

    /// The next available unicast address for provisioning
    var nextUnicastAddress: UInt16 {
        get {
            let value = defaults.integer(forKey: nextUnicastAddressKey)
            return value == 0 ? 0x0002 : UInt16(value)  // 0x0001 is provisioner
        }
        set {
            defaults.set(Int(newValue), forKey: nextUnicastAddressKey)
        }
    }

    /// Allocate and return the next unicast address
    func allocateUnicastAddress() -> UInt16 {
        let address = nextUnicastAddress
        nextUnicastAddress = address + 1
        print("KeyStorage: Allocated unicast address 0x\(String(format: "%04X", address))")
        return address
    }

    // MARK: - Device Keys

    /// Stored device keys indexed by unicast address (hex string)
    private var deviceKeysDictionary: [String: Data] {
        get {
            return defaults.dictionary(forKey: deviceKeysKey) as? [String: Data] ?? [:]
        }
        set {
            defaults.set(newValue, forKey: deviceKeysKey)
        }
    }

    /// Store a device key for a provisioned device
    func storeDeviceKey(_ key: [UInt8], forAddress address: UInt16) {
        var keys = deviceKeysDictionary
        let addressKey = String(format: "%04X", address)
        keys[addressKey] = Data(key)
        deviceKeysDictionary = keys
        print("KeyStorage: Stored device key for address 0x\(addressKey)")
    }

    /// Retrieve device key for a given unicast address
    func getDeviceKey(forAddress address: UInt16) -> [UInt8]? {
        let addressKey = String(format: "%04X", address)
        guard let data = deviceKeysDictionary[addressKey] else { return nil }
        return Array(data)
    }

    /// Get all provisioned device addresses
    var provisionedAddresses: [UInt16] {
        return deviceKeysDictionary.keys.compactMap { key in
            UInt16(key, radix: 16)
        }.sorted()
    }

    /// Remove device key for an address
    func removeDeviceKey(forAddress address: UInt16) {
        var keys = deviceKeysDictionary
        let addressKey = String(format: "%04X", address)
        keys.removeValue(forKey: addressKey)
        deviceKeysDictionary = keys
        print("KeyStorage: Removed device key for address 0x\(addressKey)")
    }

    // MARK: - Reset

    /// Reset all stored keys (for testing/debugging)
    func resetAllKeys() {
        defaults.removeObject(forKey: networkKeyKey)
        defaults.removeObject(forKey: appKeyKey)
        defaults.removeObject(forKey: ivIndexKey)
        defaults.removeObject(forKey: deviceKeysKey)
        defaults.removeObject(forKey: nextUnicastAddressKey)
        print("KeyStorage: Reset all keys")

        // Regenerate base keys
        generateNetworkKey()
        generateAppKey()
    }

    /// Use default Sidus Link keys (for compatibility with existing lights)
    func useDefaultSidusKeys() {
        networkKey = Array(SidusMeshConfig.defaultNetworkKey)
        appKey = Array(SidusMeshConfig.defaultAppKey)
        ivIndex = SidusMeshConfig.defaultIVIndex
        print("KeyStorage: Using default Sidus Link keys")
    }

    // MARK: - Debug

    /// Print current key storage state
    func printDebugInfo() {
        print("=== KeyStorage Debug Info ===")
        if let nk = networkKey {
            print("Network Key: \(nk.map { String(format: "%02X", $0) }.joined())")
        } else {
            print("Network Key: Not set (will use default)")
        }
        if let ak = appKey {
            print("App Key: \(ak.map { String(format: "%02X", $0) }.joined())")
        } else {
            print("App Key: Not set (will use default)")
        }
        print("IV Index: 0x\(String(format: "%08X", ivIndex))")
        print("Next Unicast: 0x\(String(format: "%04X", nextUnicastAddress))")
        print("Provisioned Devices: \(provisionedAddresses.map { String(format: "0x%04X", $0) })")
        print("=============================")
    }
}

import Foundation

/// A light that has been provisioned and saved by the user
struct SavedLight: Codable, Identifiable {
    let id: UUID
    var name: String
    let unicastAddress: UInt16
    let lightType: String
    let dateAdded: Date
    var lastConnected: Date?
    let peripheralIdentifier: UUID

    init(
        id: UUID = UUID(),
        name: String,
        unicastAddress: UInt16,
        lightType: String = "Aputure Light",
        dateAdded: Date = Date(),
        lastConnected: Date? = nil,
        peripheralIdentifier: UUID
    ) {
        self.id = id
        self.name = name
        self.unicastAddress = unicastAddress
        self.lightType = lightType
        self.dateAdded = dateAdded
        self.lastConnected = lastConnected
        self.peripheralIdentifier = peripheralIdentifier
    }
}

/// A named group of lights for quick access during a session
struct LightGroup: Codable, Identifiable {
    let id: UUID
    var name: String
    var lightIds: [UUID]   // references SavedLight.id
    var meshGroupAddress: UInt16?  // 0xC001, 0xC002, etc.

    init(id: UUID = UUID(), name: String, lightIds: [UUID] = [], meshGroupAddress: UInt16? = nil) {
        self.id = id
        self.name = name
        self.lightIds = lightIds
        self.meshGroupAddress = meshGroupAddress
    }
}

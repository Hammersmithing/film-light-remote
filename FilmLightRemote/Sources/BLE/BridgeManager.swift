import Foundation
import Network
import Combine

/// Manages WiFi WebSocket connection to the ESP32 BLE bridge.
/// When connected, light commands and effect engines are routed through the bridge
/// instead of direct BLE, enabling simultaneous multi-light effects.
class BridgeManager: ObservableObject {
    static let shared = BridgeManager()

    // MARK: - Published State
    @Published var isConnected = false
    @Published var discoveredBridges: [BridgeInfo] = []
    @Published var connectedBridgeAddress: String?
    @Published var bridgeVersion: String?
    @Published var maxLights: Int = 9
    @Published var lightStatuses: [UInt16: Bool] = [:]  // unicast → connected
    @Published var lastError: String?

    struct BridgeInfo: Identifiable {
        let id = UUID()
        let name: String
        let host: String
        let port: UInt16
    }

    // MARK: - Private
    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var browser: NWBrowser?
    private var reconnectWork: DispatchWorkItem?
    private var pingTimer: Timer?

    private init() {}

    // MARK: - Discovery

    func startDiscovery() {
        stopDiscovery()
        discoveredBridges.removeAll()

        let params = NWParameters()
        params.includePeerToPeer = true
        browser = NWBrowser(for: .bonjour(type: "_filmlightbridge._tcp", domain: nil), using: params)

        browser?.browseResultsChangedHandler = { [weak self] results, _ in
            DispatchQueue.main.async {
                self?.discoveredBridges = results.compactMap { result in
                    if case .service(let name, _, _, _) = result.endpoint {
                        return BridgeInfo(name: name, host: name, port: 8765)
                    }
                    return nil
                }
            }
        }

        browser?.stateUpdateHandler = { state in
            print("BridgeManager: browser state = \(state)")
        }

        browser?.start(queue: .main)
    }

    func stopDiscovery() {
        browser?.cancel()
        browser = nil
    }

    /// Resolve a discovered bridge and connect to it.
    func connectToBridge(_ bridge: BridgeInfo) {
        // Use mDNS hostname
        let host = bridge.name.lowercased().replacingOccurrences(of: " ", with: "") + ".local"
        connect(to: host, port: bridge.port)
    }

    // MARK: - Connection

    func connect(to host: String, port: UInt16 = 8765) {
        disconnect()

        let urlString = "ws://\(host):\(port)/ws"
        guard let url = URL(string: urlString) else {
            lastError = "Invalid bridge URL: \(urlString)"
            return
        }

        print("BridgeManager: connecting to \(urlString)")

        session = URLSession(configuration: .default)
        webSocket = session?.webSocketTask(with: url)
        webSocket?.resume()

        connectedBridgeAddress = host
        startReceiving()
        startPingTimer()
    }

    func disconnect() {
        pingTimer?.invalidate()
        pingTimer = nil
        reconnectWork?.cancel()
        reconnectWork = nil

        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        session?.invalidateAndCancel()
        session = nil

        DispatchQueue.main.async { [weak self] in
            self?.isConnected = false
            self?.connectedBridgeAddress = nil
            self?.bridgeVersion = nil
            self?.lightStatuses.removeAll()
        }
    }

    // MARK: - Receiving

    private func startReceiving() {
        webSocket?.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self?.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self?.handleMessage(text)
                    }
                @unknown default:
                    break
                }
                self?.startReceiving()

            case .failure(let error):
                print("BridgeManager: receive error: \(error)")
                DispatchQueue.main.async {
                    self?.isConnected = false
                    self?.lastError = "Connection lost: \(error.localizedDescription)"
                }
                self?.scheduleReconnect()
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = json["event"] as? String else { return }

        DispatchQueue.main.async { [weak self] in
            switch event {
            case "ready":
                self?.isConnected = true
                self?.bridgeVersion = json["version"] as? String
                self?.maxLights = json["max_lights"] as? Int ?? 9
                self?.lastError = nil
                print("BridgeManager: bridge ready v\(self?.bridgeVersion ?? "?")")
                self?.sendKeysAndLights()

            case "light_status":
                if let unicast = json["unicast"] as? Int,
                   let connected = json["connected"] as? Bool {
                    self?.lightStatuses[UInt16(unicast)] = connected
                }

            case "error":
                let msg = json["message"] as? String ?? "Unknown bridge error"
                self?.lastError = msg
                print("BridgeManager: error from bridge: \(msg)")

            default:
                print("BridgeManager: unknown event: \(event)")
            }
        }
    }

    // MARK: - Send Helpers

    private func send(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return }

        webSocket?.send(.string(text)) { error in
            if let error = error {
                print("BridgeManager: send error: \(error)")
            }
        }
    }

    // MARK: - Initial Setup

    /// Send mesh keys and all saved lights to the bridge after connection.
    private func sendKeysAndLights() {
        let ks = KeyStorage.shared
        let networkKey = ks.getNetworkKeyOrDefault()
        let appKey = ks.getAppKeyOrDefault()
        let ivIndex = ks.ivIndex

        send([
            "cmd": "set_keys",
            "network_key": networkKey.map { String(format: "%02X", $0) }.joined(),
            "app_key": appKey.map { String(format: "%02X", $0) }.joined(),
            "iv_index": ivIndex,
            "src_address": 1
        ])

        // Register all saved lights
        for light in ks.savedLights {
            addLight(light)
        }
    }

    // MARK: - Light Management

    func addLight(_ light: SavedLight) {
        send([
            "cmd": "add_light",
            "id": light.id.uuidString,
            "ble_addr": light.peripheralIdentifier.uuidString,
            "unicast": light.unicastAddress,
            "name": light.name
        ])
    }

    func connectLight(unicast: UInt16) {
        send(["cmd": "connect", "unicast": unicast])
    }

    func disconnectLight(unicast: UInt16) {
        send(["cmd": "disconnect", "unicast": unicast])
    }

    // MARK: - One-Shot Commands

    func setCCT(unicast: UInt16, intensity: Double, cctKelvin: Int, sleepMode: Int) {
        send([
            "cmd": "set_cct",
            "unicast": unicast,
            "intensity": intensity,
            "cct_kelvin": cctKelvin,
            "sleep_mode": sleepMode
        ])
    }

    func setHSI(unicast: UInt16, intensity: Double, hue: Int, saturation: Int, cctKelvin: Int, sleepMode: Int) {
        send([
            "cmd": "set_hsi",
            "unicast": unicast,
            "intensity": intensity,
            "hue": hue,
            "saturation": saturation,
            "cct_kelvin": cctKelvin,
            "sleep_mode": sleepMode
        ])
    }

    func sendSleep(unicast: UInt16, on: Bool) {
        send(["cmd": "sleep", "unicast": unicast, "on": on])
    }

    func setEffect(unicast: UInt16, effectType: Int, intensity: Double, frq: Int,
                   cctKelvin: Int, copCarColor: Int, effectMode: Int,
                   hue: Int, saturation: Int) {
        send([
            "cmd": "set_effect",
            "unicast": unicast,
            "effect_type": effectType,
            "intensity": intensity,
            "frequency": frq,
            "cct_kelvin": cctKelvin,
            "cop_car_color": copCarColor,
            "effect_mode": effectMode,
            "hue": hue,
            "saturation": saturation
        ])
    }

    // MARK: - Software Effect Commands

    func startSoftwareEffect(unicast: UInt16, engine: String, params: [String: Any]) {
        var cmd: [String: Any] = [
            "cmd": "start_effect",
            "unicast": unicast,
            "engine": engine
        ]
        cmd["params"] = params
        send(cmd)
    }

    func updateEffect(unicast: UInt16, params: [String: Any]) {
        send([
            "cmd": "update_effect",
            "unicast": unicast,
            "params": params
        ])
    }

    func stopEffect(unicast: UInt16) {
        send(["cmd": "stop_effect", "unicast": unicast])
    }

    func stopAll() {
        send(["cmd": "stop_all"])
    }

    // MARK: - Reconnection

    private func scheduleReconnect() {
        guard let address = connectedBridgeAddress else { return }
        reconnectWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            print("BridgeManager: attempting reconnect to \(address)")
            self?.connect(to: address)
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
    }

    private func startPingTimer() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            self?.webSocket?.sendPing { error in
                if let error = error {
                    print("BridgeManager: ping failed: \(error)")
                    DispatchQueue.main.async {
                        self?.isConnected = false
                    }
                    self?.scheduleReconnect()
                }
            }
        }
    }
}

// MARK: - LightState Serialization Helpers

extension BridgeManager {
    /// Convert a LightState to bridge effect parameters dictionary.
    static func effectParams(from ls: LightState, effect: LightEffect) -> [String: Any] {
        var params: [String: Any] = [
            "intensity": ls.intensity,
            "cctKelvin": Int(ls.cctKelvin),
            "hue": Int(ls.hue),
            "saturation": Int(ls.saturation),
            "hsiCCT": Int(ls.hsiCCT),
            "frequency": ls.effectFrequency,
        ]

        // Color mode
        let colorMode: String
        switch effect {
        case .paparazzi:
            colorMode = ls.paparazziColorMode == .hsi ? "hsi" : "cct"
        case .strobe:
            colorMode = ls.strobeColorMode == .hsi ? "hsi" : "cct"
        case .faultyBulb:
            colorMode = ls.faultyBulbColorMode == .hsi ? "hsi" : "cct"
        default:
            colorMode = ls.effectColorMode == .hsi ? "hsi" : "cct"
        }
        params["colorMode"] = colorMode

        // Effect-specific params
        switch effect {
        case .pulsing:
            params["pulsingMin"] = ls.pulsingMin
            params["pulsingMax"] = ls.pulsingMax
            params["pulsingShape"] = ls.pulsingShape

        case .strobe:
            params["strobeHz"] = ls.strobeHz

        case .faultyBulb:
            params["faultyMin"] = ls.faultyBulbMin
            params["faultyMax"] = ls.faultyBulbMax
            params["faultyBias"] = ls.faultyBulbBias
            params["faultyRecovery"] = ls.faultyBulbRecovery
            params["faultyWarmth"] = ls.faultyBulbWarmth
            params["warmestCCT"] = 2700
            params["faultyPoints"] = ls.faultyBulbPoints
            params["faultyTransition"] = ls.faultyBulbTransition
            params["faultyFrequency"] = ls.faultyBulbFrequency

        case .party:
            params["partyColors"] = ls.partyColors.map { Double($0) }
            params["partyTransition"] = ls.partyTransition
            params["partyHueBias"] = ls.partyHueBias

        default:
            break
        }

        return params
    }

    /// Map a LightEffect to the bridge engine name string.
    static func engineName(for effect: LightEffect) -> String {
        switch effect {
        case .pulsing: return "pulsing"
        case .strobe: return "strobe"
        case .fire: return "fire"
        case .candle: return "candle"
        case .lightning: return "lightning"
        case .tvFlicker: return "tv"
        case .party: return "party"
        case .explosion: return "explosion"
        case .welding: return "welding"
        case .faultyBulb: return "faultyBulb"
        case .paparazzi: return "paparazzi"
        default: return "pulsing"
        }
    }
}

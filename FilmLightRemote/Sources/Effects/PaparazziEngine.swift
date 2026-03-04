import Foundation

// MARK: - Paparazzi Software Engine
/// Simulates camera flash bursts (paparazzi) in any color mode.
/// Brief intense flashes at random intervals with occasional double/triple bursts.
class PaparazziEngine {
    private var workItem: DispatchWorkItem?
    private var bleManager: BLEManager?
    private let queue = DispatchQueue(label: "com.filmlightremote.paparazzi", qos: .userInitiated)

    // Stored parameters
    private(set) var targetAddress: UInt16 = 0x0002
    /// The peripheral this engine writes through (set at start time).
    private(set) var peripheralIdentifier: UUID = UUID()
    private var colorMode: LightMode = .hsi
    private var cctKelvin: Int = 5600
    private var hue: Int = 0
    private var saturation: Int = 100
    private var hsiCCT: Int = 5600
    private var intensity: Double = 100.0
    private var frequency: Double = 8.0  // 0-15

    func start(bleManager: BLEManager, lightState: LightState, targetAddress: UInt16, peripheralIdentifier: UUID? = nil) {
        stop()
        self.bleManager = bleManager
        self.targetAddress = targetAddress
        self.peripheralIdentifier = peripheralIdentifier ?? bleManager.connectedPeripheral?.identifier ?? UUID()
        updateParams(from: lightState)
        scheduleNextFlash()
    }

    func stop() {
        workItem?.cancel()
        workItem = nil
        bleManager = nil
    }

    func updateParams(from lightState: LightState) {
        colorMode = lightState.paparazziColorMode
        cctKelvin = Int(lightState.cctKelvin)
        hue = Int(lightState.hue)
        saturation = Int(lightState.saturation)
        hsiCCT = Int(lightState.hsiCCT)
        intensity = max(lightState.intensity, 10) // Ensure visible flash
        frequency = lightState.effectFrequency
    }

    private func scheduleNextFlash() {
        guard bleManager != nil else { return }

        // Map frequency (0-15) to gap between flashes
        // frq 0 = slow (~3s gaps), frq 15 = rapid (~0.08s gaps)
        let baseGap = 3.0 * pow(0.75, frequency)
        let gap = baseGap * Double.random(in: 0.5...1.5)

        let work = DispatchWorkItem { [weak self] in
            self?.fireFlash()
        }
        workItem = work
        queue.asyncAfter(deadline: .now() + gap, execute: work)
    }

    private func fireFlash() {
        guard bleManager != nil else { return }

        // Flash ON
        sendColor(intensity: intensity, sleepMode: 1)

        // Flash duration: 30-80ms (brief camera flash)
        let flashDuration = Double.random(in: 0.03...0.08)

        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.bleManager != nil else { return }
            // Flash OFF
            self.sendColor(intensity: 0, sleepMode: 0)

            // 30% chance of a quick double flash
            if Double.random(in: 0...1) < 0.3 {
                let burstDelay = Double.random(in: 0.05...0.15)
                let burstWork = DispatchWorkItem { [weak self] in
                    guard let self = self, self.bleManager != nil else { return }
                    // Second flash ON
                    self.sendColor(intensity: self.intensity, sleepMode: 1)

                    let offWork = DispatchWorkItem { [weak self] in
                        guard let self = self else { return }
                        self.sendColor(intensity: 0, sleepMode: 0)
                        self.scheduleNextFlash()
                    }
                    self.workItem = offWork
                    self.queue.asyncAfter(deadline: .now() + flashDuration, execute: offWork)
                }
                self.workItem = burstWork
                self.queue.asyncAfter(deadline: .now() + burstDelay, execute: burstWork)
            } else {
                self.scheduleNextFlash()
            }
        }
        workItem = work
        queue.asyncAfter(deadline: .now() + flashDuration, execute: work)
    }

    private func sendColor(intensity: Double, sleepMode: Int) {
        guard let mgr = bleManager else { return }
        if colorMode == .hsi {
            mgr.setHSIWithSleep(
                intensity: intensity,
                hue: hue,
                saturation: saturation,
                cctKelvin: hsiCCT,
                sleepMode: sleepMode,
                targetAddress: targetAddress,
                viaPeripheral: peripheralIdentifier
            )
        } else {
            mgr.setCCTWithSleep(
                intensity: intensity,
                cctKelvin: cctKelvin,
                sleepMode: sleepMode,
                targetAddress: targetAddress,
                viaPeripheral: peripheralIdentifier
            )
        }
    }
}

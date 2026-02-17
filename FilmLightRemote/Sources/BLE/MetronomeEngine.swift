import AVFoundation

/// Low-latency metronome click using AVAudioEngine.
class MetronomeEngine {
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var downbeatBuffer: AVAudioPCMBuffer?
    private var offbeatBuffer: AVAudioPCMBuffer?
    private var isSetUp = false

    func setup() {
        guard !isSetUp else { return }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)

        let sampleRate: Double = 44100
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        engine.connect(player, to: engine.mainMixerNode, format: format)

        // Synthesize click buffers
        downbeatBuffer = synthesizeClick(frequency: 1500, amplitude: 0.7, duration: 0.03, sampleRate: sampleRate, format: format)
        offbeatBuffer = synthesizeClick(frequency: 1000, amplitude: 0.4, duration: 0.025, sampleRate: sampleRate, format: format)

        do {
            try engine.start()
            player.play()
            self.engine = engine
            self.playerNode = player
            isSetUp = true
        } catch {
            print("MetronomeEngine setup failed: \(error)")
        }
    }

    /// Called each display-link frame. Finds beat crossings and schedules clicks.
    func tick(previousTime: Double, currentTime: Double, tempoMap: TempoMap) {
        guard isSetUp, let player = playerNode else { return }
        let ticks = tempoMap.beatTicks(from: previousTime, to: currentTime)
        for (_, isDownbeat) in ticks {
            let buf = isDownbeat ? downbeatBuffer : offbeatBuffer
            if let buf = buf {
                player.scheduleBuffer(buf, at: nil, options: [], completionHandler: nil)
            }
        }
    }

    func reset() {
        playerNode?.stop()
        playerNode?.play()
    }

    func stop() {
        playerNode?.stop()
        engine?.stop()
        engine = nil
        playerNode = nil
        downbeatBuffer = nil
        offbeatBuffer = nil
        isSetUp = false
    }

    // MARK: - Synthesis

    private func synthesizeClick(frequency: Double, amplitude: Float, duration: Double, sampleRate: Double, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(duration * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount

        guard let data = buffer.floatChannelData?[0] else { return nil }
        for i in 0..<Int(frameCount) {
            let t = Double(i) / sampleRate
            let envelope = Float(max(0, 1.0 - t / duration))  // linear decay
            data[i] = amplitude * envelope * sin(Float(2.0 * Double.pi * frequency * t))
        }
        return buffer
    }
}

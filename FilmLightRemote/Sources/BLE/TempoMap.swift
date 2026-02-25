import Foundation

/// Converts between beat positions (quarter notes) and wall-clock seconds
/// using a sorted list of tempo/time-signature events.
struct TempoMap {
    private let events: [TempoEvent]
    /// Cumulative seconds at the start of each event
    private let eventSeconds: [Double]

    init(events: [TempoEvent]) {
        var sorted = events.sorted { $0.beatPosition < $1.beatPosition }
        // Ensure there's always an event at beat 0
        if sorted.isEmpty || sorted[0].beatPosition > 0 {
            sorted.insert(TempoEvent(beatPosition: 0, bpm: 120, timeSignature: .common), at: 0)
        }
        self.events = sorted

        // Precompute cumulative seconds at each event boundary
        var secs: [Double] = [0]
        for i in 1..<sorted.count {
            let prev = sorted[i - 1]
            let beatDelta = sorted[i].beatPosition - prev.beatPosition
            let secsPerBeat = 60.0 / prev.bpm
            secs.append(secs[i - 1] + beatDelta * secsPerBeat)
        }
        self.eventSeconds = secs
    }

    // MARK: - Beat <-> Seconds

    /// Convert a beat position (quarter notes) to seconds.
    func seconds(forBeat beat: Double) -> Double {
        let idx = eventIndex(forBeat: beat)
        let ev = events[idx]
        let beatDelta = beat - ev.beatPosition
        let secsPerBeat = 60.0 / ev.bpm
        return eventSeconds[idx] + beatDelta * secsPerBeat
    }

    /// Convert seconds to a beat position (quarter notes).
    func beat(forSeconds secs: Double) -> Double {
        let idx = eventIndex(forSeconds: secs)
        let ev = events[idx]
        let secDelta = secs - eventSeconds[idx]
        let beatsPerSec = ev.bpm / 60.0
        return ev.beatPosition + secDelta * beatsPerSec
    }

    /// Total seconds for a given number of beats from beat 0.
    func totalSeconds(forBeats beats: Double) -> Double {
        seconds(forBeat: beats)
    }

    // MARK: - Bar/Beat

    /// Returns (bar, beat) for an absolute beat position. Bar is 1-based.
    func barBeat(forBeat beat: Double) -> (bar: Int, beat: Double) {
        var remainingBeat = beat
        var bar = 1

        for i in 0..<events.count {
            let ev = events[i]
            let qnPerBar = ev.timeSignature.quarterNotesPerBar
            let nextBeatPos: Double
            if i + 1 < events.count {
                nextBeatPos = events[i + 1].beatPosition
            } else {
                nextBeatPos = .infinity
            }

            let beatsInSegment = min(remainingBeat, nextBeatPos - ev.beatPosition)
            let barsInSegment = Int(beatsInSegment / qnPerBar)

            if ev.beatPosition + Double(barsInSegment) * qnPerBar + qnPerBar > nextBeatPos && i + 1 < events.count {
                // This segment ends before using all remaining beats
                remainingBeat -= (nextBeatPos - ev.beatPosition)
                bar += Int((nextBeatPos - ev.beatPosition) / qnPerBar)
                continue
            }

            let beatInBar = beatsInSegment - Double(barsInSegment) * qnPerBar
            return (bar + barsInSegment, beatInBar)
        }
        return (bar, 0)
    }

    /// Convert a bar number (1-based) to an absolute beat position.
    func beatPosition(forBar targetBar: Int) -> Double {
        var currentBar = 1
        var currentBeat: Double = 0

        for i in 0..<events.count {
            let ev = events[i]
            let qnPerBar = ev.timeSignature.quarterNotesPerBar

            // Last segment extends to infinity — target bar must be here
            guard i + 1 < events.count else {
                return currentBeat + Double(targetBar - currentBar) * qnPerBar
            }

            let nextBeatPos = events[i + 1].beatPosition
            let segmentBeats = nextBeatPos - ev.beatPosition
            let barsInSegment = Int(segmentBeats / qnPerBar)

            if currentBar + barsInSegment >= targetBar {
                return currentBeat + Double(targetBar - currentBar) * qnPerBar
            }

            currentBar += barsInSegment
            currentBeat += Double(barsInSegment) * qnPerBar
        }
        return currentBeat
    }

    // MARK: - Beat Ticks (for metronome)

    /// Returns an array of (seconds, isDownbeat) for beat crossings in the given time range.
    func beatTicks(from startSec: Double, to endSec: Double) -> [(seconds: Double, isDownbeat: Bool)] {
        guard endSec > startSec else { return [] }
        var result: [(Double, Bool)] = []

        let startBeat = beat(forSeconds: startSec)
        let endBeat = beat(forSeconds: endSec)

        // Find first whole beat after startBeat
        var b = ceil(startBeat)
        while b < endBeat {
            let s = seconds(forBeat: b)
            if s > startSec && s <= endSec {
                let (_, beatInBar) = barBeat(forBeat: b)
                let isDown = beatInBar < 0.001
                result.append((s, isDown))
            }
            b += 1.0
        }
        return result
    }

    // MARK: - Snap

    /// Snap a beat position to the nearest subdivision (e.g. 0.25 for sixteenth notes).
    func snapBeat(_ beat: Double, subdivision: Double) -> Double {
        (beat / subdivision).rounded() * subdivision
    }

    /// Snap to the nearest bar line.
    func snapToBar(_ beat: Double) -> Double {
        let (bar, beatInBar) = barBeat(forBeat: beat)
        let ev = events[eventIndex(forBeat: beat)]
        let qnPerBar = ev.timeSignature.quarterNotesPerBar
        if beatInBar > qnPerBar / 2 {
            return beatPosition(forBar: bar + 1)
        }
        return beatPosition(forBar: bar)
    }

    /// Find the active TempoEvent at a given beat position.
    func tempo(atBeat beat: Double) -> TempoEvent {
        events[eventIndex(forBeat: beat)]
    }

    // MARK: - Private

    private func eventIndex(forBeat beat: Double) -> Int {
        var idx = 0
        for i in 1..<events.count {
            if events[i].beatPosition <= beat {
                idx = i
            } else {
                break
            }
        }
        return idx
    }

    private func eventIndex(forSeconds secs: Double) -> Int {
        var idx = 0
        for i in 1..<eventSeconds.count {
            if eventSeconds[i] <= secs {
                idx = i
            } else {
                break
            }
        }
        return idx
    }
}

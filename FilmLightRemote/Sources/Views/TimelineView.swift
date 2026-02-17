import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

/// Visual block-timeline editor and player for a single Timeline.
struct TimelineView: View {
    @EnvironmentObject var bleManager: BLEManager
    @StateObject private var engine = TimelineEngine()
    @State var timeline: Timeline
    var onUpdate: () -> Void

    // Zoom: points per second (or per beat in beat mode)
    @State private var ptsPerSecond: CGFloat = 40
    @State private var scrollOffset: CGFloat = 0

    // Editing state
    @State private var editingBlock: EditingBlockInfo?
    @State private var showLightPicker = false
    @State private var showDurationEditor = false
    @State private var durationText = ""
    @State private var showDurationWarning = false
    @State private var pendingDuration: Double = 0
    @State private var showAudioPicker = false
    @State private var editingTempoEvent: TempoEvent?

    // Dragging
    @State private var draggingBlockId: UUID?
    @State private var draggingTrackId: UUID?
    @State private var dragStartTime: Double = 0

    // Resizing
    @State private var resizingBlockId: UUID?
    @State private var resizingTrackId: UUID?

    // Pinch zoom
    @State private var pinchBasePts: CGFloat?

    private let trackLabelWidth: CGFloat = 70
    private let trackHeight: CGFloat = 50
    private let rulerHeight: CGFloat = 30
    private let tempoLaneHeight: CGFloat = 28
    private let snapGrid: Double = 0.25

    private var isBeatMode: Bool { timeline.effectiveMode == .beats }

    /// The authoritative timeline length in the current mode's unit.
    private var timelineLength: Double {
        isBeatMode ? (timeline.totalBeats ?? 32) : timeline.totalDuration
    }

    var body: some View {
        VStack(spacing: 0) {
            timelineCanvas
            transportBar
        }
        .navigationTitle(timeline.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button { showLightPicker = true } label: {
                        Label("Add Light", systemImage: "plus")
                    }
                    if timeline.audioFileId == nil {
                        Button { showAudioPicker = true } label: {
                            Label("Add Song", systemImage: "music.note")
                        }
                    }
                    Button { showDurationEditor = true } label: {
                        Label(isBeatMode ? "Set Length (Bars)" : "Set Duration", systemImage: "clock")
                    }
                    Button {
                        toggleMode()
                    } label: {
                        Label(isBeatMode ? "Switch to Seconds Mode" : "Switch to Beat Mode",
                              systemImage: isBeatMode ? "clock" : "metronome")
                    }
                    Button {
                        timeline.name = timeline.name // trigger rename alert
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showLightPicker) {
            NavigationStack {
                TimelineLightPickerView(
                    existingIds: Set(timeline.tracks.map { $0.lightId })
                ) { saved in
                    let track = TimelineTrack(
                        lightId: saved.id,
                        lightName: saved.name,
                        unicastAddress: saved.unicastAddress
                    )
                    timeline.tracks.append(track)
                    save()
                    showLightPicker = false
                }
            }
        }
        .sheet(item: $editingBlock) { info in
            NavigationStack {
                CueLightEditorView(
                    entry: LightCueEntry(
                        lightId: info.lightId,
                        lightName: info.lightName,
                        unicastAddress: info.unicastAddress,
                        state: info.state
                    )
                ) { updated in
                    applyBlockEdit(trackId: info.trackId, blockId: info.blockId, newState: updated.state)
                    editingBlock = nil
                }
            }
        }
        .sheet(item: $editingTempoEvent) { event in
            NavigationStack {
                TempoEventEditorView(
                    event: event,
                    isFirst: event.beatPosition < 0.001
                ) { updated in
                    applyTempoEventEdit(updated)
                    editingTempoEvent = nil
                } onDelete: {
                    deleteTempoEvent(event)
                    editingTempoEvent = nil
                }
            }
        }
        .alert("Timeline Duration", isPresented: $showDurationEditor) {
            TextField(isBeatMode ? "Bars" : "Seconds", text: $durationText)
                .keyboardType(.decimalPad)
            Button("Cancel", role: .cancel) {}
            Button("Set") {
                if let d = Double(durationText), d > 0 {
                    if isBeatMode {
                        // d is in bars — convert to beats
                        let map = TempoMap(events: timeline.effectiveTempoEvents)
                        let beats = map.beatPosition(forBar: Int(d) + 1)
                        let outOfBounds = blocksOutsideDuration(beats)
                        if outOfBounds > 0 {
                            pendingDuration = beats
                            showDurationWarning = true
                        } else {
                            timeline.totalBeats = beats
                            timeline.totalDuration = map.totalSeconds(forBeats: beats)
                            save()
                        }
                    } else {
                        let outOfBounds = blocksOutsideDuration(d)
                        if outOfBounds > 0 {
                            pendingDuration = d
                            showDurationWarning = true
                        } else {
                            timeline.totalDuration = d
                            save()
                        }
                    }
                }
            }
        } message: {
            Text(isBeatMode ? "Set the total timeline length in bars." : "Set the total timeline length in seconds.")
        }
        .alert("Blocks Outside Timeline", isPresented: $showDurationWarning) {
            Button("Cancel", role: .cancel) { pendingDuration = 0 }
            Button("Delete & Set Duration", role: .destructive) {
                removeBlocksOutsideDuration(pendingDuration)
                if isBeatMode {
                    timeline.totalBeats = pendingDuration
                    let map = TempoMap(events: timeline.effectiveTempoEvents)
                    timeline.totalDuration = map.totalSeconds(forBeats: pendingDuration)
                } else {
                    timeline.totalDuration = pendingDuration
                }
                pendingDuration = 0
                save()
            }
        } message: {
            let count = blocksOutsideDuration(pendingDuration)
            Text("\(count) block\(count == 1 ? "" : "s") will be deleted because \(count == 1 ? "it extends" : "they extend") past the new duration.")
        }
        .fileImporter(isPresented: $showAudioPicker, allowedContentTypes: [.audio]) { result in
            if case .success(let url) = result {
                importAudioFile(from: url)
            }
        }
        .onAppear {
            engine.bleManager = bleManager
            updateDurationText()
        }
        .onDisappear {
            engine.stop()
        }
    }

    // MARK: - Timeline Canvas

    private var timelineCanvas: some View {
        GeometryReader { geo in
            let availableWidth = geo.size.width - trackLabelWidth
            let minPts = max(1, availableWidth / CGFloat(timelineLength))
            let maxPts = availableWidth / 0.5
            let canvasWidth = max(availableWidth, ptsPerSecond * CGFloat(timelineLength))

            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                ZStack(alignment: .topLeading) {
                    // Background
                    Color(.systemBackground)
                        .frame(width: trackLabelWidth + canvasWidth, height: totalCanvasHeight)

                    VStack(alignment: .leading, spacing: 0) {
                        // Time ruler
                        HStack(spacing: 0) {
                            Color.clear.frame(width: trackLabelWidth, height: rulerHeight)
                            timeRuler(width: canvasWidth)
                        }

                        // Tempo lane (beat mode only)
                        if isBeatMode {
                            HStack(spacing: 0) {
                                Text("Tempo")
                                    .font(.system(size: 9, weight: .medium))
                                    .frame(width: trackLabelWidth, height: tempoLaneHeight)
                                    .background(Color(.systemGray6))
                                tempoLane(width: canvasWidth)
                            }
                            Divider()
                        }

                        // Audio lane
                        if timeline.audioFileName != nil {
                            HStack(spacing: 0) {
                                audioLaneLabel
                                audioLaneBar(canvasWidth: canvasWidth)
                            }
                            Divider()
                        }

                        // Tracks
                        ForEach(Array(timeline.tracks.enumerated()), id: \.element.id) { idx, track in
                            HStack(spacing: 0) {
                                trackLabel(track: track, index: idx)
                                trackLane(track: track, canvasWidth: canvasWidth)
                            }
                            Divider()
                        }
                    }

                    // Playhead
                    if engine.isPlaying || engine.currentTime > 0 {
                        playheadView(canvasHeight: totalCanvasHeight)
                    }
                }
            }
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { scale in
                        if pinchBasePts == nil { pinchBasePts = ptsPerSecond }
                        ptsPerSecond = max(minPts, min(maxPts, pinchBasePts! * scale))
                    }
                    .onEnded { _ in
                        pinchBasePts = nil
                    }
            )
        }
    }

    private var totalCanvasHeight: CGFloat {
        let audioLane: CGFloat = timeline.audioFileName != nil ? (trackHeight + 1) : 0
        let tempo: CGFloat = isBeatMode ? (tempoLaneHeight + 1) : 0
        return rulerHeight + tempo + audioLane + CGFloat(timeline.tracks.count) * (trackHeight + 1)
    }

    // MARK: - Time Ruler

    private func timeRuler(width: CGFloat) -> some View {
        Group {
            if isBeatMode {
                beatRuler(width: width)
            } else {
                secondsRuler(width: width)
            }
        }
    }

    private func secondsRuler(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color(.systemGray5))
                .frame(width: width, height: rulerHeight)

            let interval = rulerInterval()
            let count = Int(timeline.totalDuration / interval) + 1
            ForEach(0..<count, id: \.self) { i in
                let t = Double(i) * interval
                let x = CGFloat(t) * ptsPerSecond
                VStack(spacing: 1) {
                    Text(formatTime(t))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                    Rectangle()
                        .fill(Color.secondary.opacity(0.4))
                        .frame(width: 1, height: 8)
                }
                .offset(x: x - 10)
            }
        }
        .frame(height: rulerHeight)
    }

    private func beatRuler(width: CGFloat) -> some View {
        let map = TempoMap(events: timeline.effectiveTempoEvents)
        let totalBeats = timeline.totalBeats ?? 32

        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color(.systemGray5))
                .frame(width: width, height: rulerHeight)

            // Draw bar lines and beat ticks
            let maxBar = 500 // safety limit
            ForEach(0..<maxBar, id: \.self) { barIdx in
                let barNum = barIdx + 1
                let beatPos = map.beatPosition(forBar: barNum)
                if beatPos < totalBeats {
                    let x = CGFloat(beatPos) * ptsPerSecond
                    // Bar number label + tall tick
                    VStack(spacing: 1) {
                        Text("\(barNum)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                        Rectangle()
                            .fill(Color.secondary.opacity(0.6))
                            .frame(width: 1, height: 10)
                    }
                    .offset(x: x - 6)

                    // Beat ticks within bar
                    let tempo = map.tempo(atBeat: beatPos)
                    let qnPerBar = tempo.timeSignature.quarterNotesPerBar
                    let beatsInBar = Int(qnPerBar)
                    ForEach(1..<beatsInBar, id: \.self) { beatInBar in
                        let tickBeat = beatPos + Double(beatInBar)
                        if tickBeat < totalBeats {
                            let tickX = CGFloat(tickBeat) * ptsPerSecond
                            Rectangle()
                                .fill(Color.secondary.opacity(0.3))
                                .frame(width: 1, height: 5)
                                .offset(x: tickX, y: rulerHeight - 6)
                        }
                    }
                }
            }
        }
        .frame(height: rulerHeight)
    }

    private func rulerInterval() -> Double {
        if ptsPerSecond > 80 { return 1 }
        if ptsPerSecond > 30 { return 5 }
        return 10
    }

    // MARK: - Tempo Lane

    private func tempoLane(width: CGFloat) -> some View {
        let events = timeline.effectiveTempoEvents

        return ZStack(alignment: .leading) {
            Rectangle()
                .fill(Color(.systemGray6).opacity(0.3))
                .frame(width: width, height: tempoLaneHeight)
                .contentShape(Rectangle())
                .onTapGesture { location in
                    let beat = Double(location.x) / Double(ptsPerSecond)
                    let map = TempoMap(events: events)
                    let snappedBeat = map.snapToBar(beat)
                    // Don't add at position 0 if one already exists there
                    if events.contains(where: { abs($0.beatPosition - snappedBeat) < 0.001 }) {
                        return
                    }
                    let prevTempo = map.tempo(atBeat: snappedBeat)
                    let newEvent = TempoEvent(beatPosition: snappedBeat, bpm: prevTempo.bpm, timeSignature: prevTempo.timeSignature)
                    editingTempoEvent = newEvent
                }

            ForEach(events) { event in
                let x = CGFloat(event.beatPosition) * ptsPerSecond
                Text("\(Int(event.bpm)) \(event.timeSignature.displayString)")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.indigo))
                    .offset(x: x)
                    .onTapGesture {
                        editingTempoEvent = event
                    }
            }
        }
        .frame(width: width, height: tempoLaneHeight)
    }

    // MARK: - Track Label

    private func trackLabel(track: TimelineTrack, index: Int) -> some View {
        Text(track.lightName)
            .font(.caption2)
            .fontWeight(.medium)
            .lineLimit(2)
            .frame(width: trackLabelWidth, height: trackHeight)
            .padding(.horizontal, 4)
            .background(Color(.systemGray6))
            .contextMenu {
                Button(role: .destructive) {
                    timeline.tracks.removeAll { $0.id == track.id }
                    save()
                } label: {
                    Label("Remove Track", systemImage: "trash")
                }
            }
    }

    // MARK: - Track Lane

    private func trackLane(track: TimelineTrack, canvasWidth: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            // Tap empty area to add block
            Rectangle()
                .fill(Color(.systemGray6).opacity(0.3))
                .frame(width: canvasWidth, height: trackHeight)
                .contentShape(Rectangle())
                .onTapGesture { location in
                    let time = snapToGrid(Double(location.x) / Double(ptsPerSecond))
                    addBlock(to: track.id, at: time)
                }

            // Blocks
            ForEach(track.blocks) { block in
                blockView(block: block, track: track)
            }
        }
        .frame(width: canvasWidth, height: trackHeight)
    }

    // MARK: - Block View

    private func blockView(block: TimelineBlock, track: TimelineTrack) -> some View {
        let blockWidth = max(CGFloat(block.duration) * ptsPerSecond, 30)
        let x = CGFloat(block.startTime) * ptsPerSecond

        return ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(blockColor(for: block.state))
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5)
            Text(block.state.shortSummary)
                .font(.system(size: 9))
                .foregroundColor(.white)
                .lineLimit(1)
                .padding(.horizontal, 3)

            // Right-edge resize handle
            HStack {
                Spacer()
                Rectangle()
                    .fill(Color.white.opacity(0.4))
                    .frame(width: 6, height: trackHeight - 12)
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { value in
                                resizeBlock(trackId: track.id, blockId: block.id, dragX: value.translation.width)
                            }
                            .onEnded { _ in
                                resizingBlockId = nil
                                resizingTrackId = nil
                                save()
                            }
                    )
            }
        }
        .frame(width: blockWidth, height: trackHeight - 6)
        .offset(x: x)
        .onTapGesture {
            editingBlock = EditingBlockInfo(
                trackId: track.id,
                blockId: block.id,
                lightId: track.lightId,
                lightName: track.lightName,
                unicastAddress: track.unicastAddress,
                state: block.state
            )
        }
        .gesture(
            LongPressGesture(minimumDuration: 0.3)
                .sequenced(before: DragGesture(minimumDistance: 2))
                .onChanged { value in
                    switch value {
                    case .second(true, let drag):
                        if let drag = drag {
                            if draggingBlockId == nil {
                                draggingBlockId = block.id
                                draggingTrackId = track.id
                                dragStartTime = block.startTime
                            }
                            let delta = Double(drag.translation.width) / Double(ptsPerSecond)
                            moveBlock(trackId: track.id, blockId: block.id, to: dragStartTime + delta)
                        }
                    default:
                        break
                    }
                }
                .onEnded { _ in
                    draggingBlockId = nil
                    draggingTrackId = nil
                    save()
                }
        )
        .contextMenu {
            Button(role: .destructive) {
                removeBlock(trackId: track.id, blockId: block.id)
            } label: {
                Label("Delete Block", systemImage: "trash")
            }
        }
    }

    private func blockColor(for state: CueState) -> Color {
        let mode = LightMode(rawValue: state.mode) ?? .cct
        switch mode {
        case .cct: return .orange
        case .hsi: return .blue
        case .effects: return .purple
        }
    }

    // MARK: - Playhead

    private func playheadView(canvasHeight: CGFloat) -> some View {
        let position: CGFloat
        if isBeatMode {
            position = trackLabelWidth + CGFloat(engine.currentBeat) * ptsPerSecond
        } else {
            position = trackLabelWidth + CGFloat(engine.currentTime) * ptsPerSecond
        }
        return Rectangle()
            .fill(Color.red)
            .frame(width: 2, height: canvasHeight)
            .offset(x: position)
    }

    // MARK: - Transport Bar

    private var transportBar: some View {
        HStack(spacing: 16) {
            // Rewind
            Button {
                engine.stop()
                engine.currentTime = 0
                engine.currentBeat = 0
            } label: {
                Image(systemName: "backward.end.fill")
                    .font(.title3)
            }

            // Play/Stop
            Button {
                if engine.isPlaying {
                    engine.stop()
                } else {
                    engine.play(timeline: timeline)
                }
            } label: {
                Image(systemName: engine.isPlaying ? "stop.fill" : "play.fill")
                    .font(.title2)
            }

            // Metronome toggle (beat mode only)
            if isBeatMode {
                Button {
                    timeline.metronomeEnabled = !(timeline.metronomeEnabled ?? false)
                    save()
                } label: {
                    Image(systemName: timeline.metronomeEnabled == true ? "metronome.fill" : "metronome")
                        .font(.title3)
                        .foregroundColor(timeline.metronomeEnabled == true ? .accentColor : .secondary)
                }
            }

            Spacer()

            // Time display
            if isBeatMode {
                let map = TempoMap(events: timeline.effectiveTempoEvents)
                let (bar, beatInBar) = map.barBeat(forBeat: engine.currentBeat)
                let totalBars = totalBarsCount()
                Text("Bar \(bar).\(Int(beatInBar) + 1) / \(totalBars)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
            } else {
                Text("\(formatTime(engine.currentTime)) / \(formatTime(timeline.totalDuration))")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(.systemGray6))
    }

    // MARK: - Block Operations

    private func addBlock(to trackId: UUID, at time: Double) {
        guard let idx = timeline.tracks.firstIndex(where: { $0.id == trackId }) else { return }
        let maxTime = timelineLength
        let clamped = min(time, maxTime - 1)
        let defaultDuration: Double = isBeatMode ? 4 : 2  // 1 bar or 2 seconds
        let block = TimelineBlock(startTime: max(0, clamped), duration: defaultDuration)
        timeline.tracks[idx].blocks.append(block)
        timeline.tracks[idx].blocks.sort { $0.startTime < $1.startTime }
        save()

        // Open editor immediately
        let track = timeline.tracks[idx]
        editingBlock = EditingBlockInfo(
            trackId: trackId,
            blockId: block.id,
            lightId: track.lightId,
            lightName: track.lightName,
            unicastAddress: track.unicastAddress,
            state: block.state
        )
    }

    private func removeBlock(trackId: UUID, blockId: UUID) {
        guard let tIdx = timeline.tracks.firstIndex(where: { $0.id == trackId }) else { return }
        timeline.tracks[tIdx].blocks.removeAll { $0.id == blockId }
        save()
    }

    private func moveBlock(trackId: UUID, blockId: UUID, to newTime: Double) {
        guard let tIdx = timeline.tracks.firstIndex(where: { $0.id == trackId }),
              let bIdx = timeline.tracks[tIdx].blocks.firstIndex(where: { $0.id == blockId }) else { return }
        let maxTime = timelineLength
        let snapped = snapToGrid(max(0, min(newTime, maxTime - timeline.tracks[tIdx].blocks[bIdx].duration)))
        timeline.tracks[tIdx].blocks[bIdx].startTime = snapped
    }

    private func resizeBlock(trackId: UUID, blockId: UUID, dragX: CGFloat) {
        guard let tIdx = timeline.tracks.firstIndex(where: { $0.id == trackId }),
              let bIdx = timeline.tracks[tIdx].blocks.firstIndex(where: { $0.id == blockId }) else { return }

        if resizingBlockId == nil {
            resizingBlockId = blockId
            resizingTrackId = trackId
        }

        let block = timeline.tracks[tIdx].blocks[bIdx]
        let delta = Double(dragX) / Double(ptsPerSecond)
        let newDur = max(0.25, block.duration + delta)
        let maxDur = timelineLength - block.startTime
        timeline.tracks[tIdx].blocks[bIdx].duration = snapToGrid(min(newDur, maxDur))
    }

    private func applyBlockEdit(trackId: UUID, blockId: UUID, newState: CueState) {
        guard let tIdx = timeline.tracks.firstIndex(where: { $0.id == trackId }),
              let bIdx = timeline.tracks[tIdx].blocks.firstIndex(where: { $0.id == blockId }) else { return }
        timeline.tracks[tIdx].blocks[bIdx].state = newState
        save()
    }

    // MARK: - Tempo Event Operations

    private func applyTempoEventEdit(_ event: TempoEvent) {
        var events = timeline.tempoEvents ?? []
        if let idx = events.firstIndex(where: { $0.id == event.id }) {
            events[idx] = event
        } else {
            events.append(event)
        }
        events.sort { $0.beatPosition < $1.beatPosition }
        timeline.tempoEvents = events
        // Update totalDuration to reflect new tempo
        if isBeatMode, let beats = timeline.totalBeats {
            let map = TempoMap(events: timeline.effectiveTempoEvents)
            timeline.totalDuration = map.totalSeconds(forBeats: beats)
        }
        save()
    }

    private func deleteTempoEvent(_ event: TempoEvent) {
        var events = timeline.tempoEvents ?? []
        events.removeAll { $0.id == event.id }
        timeline.tempoEvents = events.isEmpty ? nil : events
        if isBeatMode, let beats = timeline.totalBeats {
            let map = TempoMap(events: timeline.effectiveTempoEvents)
            timeline.totalDuration = map.totalSeconds(forBeats: beats)
        }
        save()
    }

    // MARK: - Mode Toggle

    private func toggleMode() {
        if isBeatMode {
            // Beat -> Seconds: convert block positions
            let map = TempoMap(events: timeline.effectiveTempoEvents)
            for i in timeline.tracks.indices {
                for j in timeline.tracks[i].blocks.indices {
                    let block = timeline.tracks[i].blocks[j]
                    let startSec = map.seconds(forBeat: block.startTime)
                    let endSec = map.seconds(forBeat: block.startTime + block.duration)
                    timeline.tracks[i].blocks[j].startTime = startSec
                    timeline.tracks[i].blocks[j].duration = endSec - startSec
                }
            }
            if let beats = timeline.totalBeats {
                timeline.totalDuration = map.totalSeconds(forBeats: beats)
            }
            timeline.mode = .seconds
        } else {
            // Seconds -> Beats: convert block positions
            let map = TempoMap(events: timeline.effectiveTempoEvents)
            for i in timeline.tracks.indices {
                for j in timeline.tracks[i].blocks.indices {
                    let block = timeline.tracks[i].blocks[j]
                    let startBeat = map.beat(forSeconds: block.startTime)
                    let endBeat = map.beat(forSeconds: block.startTime + block.duration)
                    timeline.tracks[i].blocks[j].startTime = startBeat
                    timeline.tracks[i].blocks[j].duration = endBeat - startBeat
                }
            }
            let totalBeats = map.beat(forSeconds: timeline.totalDuration)
            timeline.totalBeats = totalBeats
            timeline.mode = .beats
            if timeline.tempoEvents == nil {
                timeline.tempoEvents = [TempoEvent()]
            }
        }
        save()
    }

    // MARK: - Audio Lane

    private var audioLaneLabel: some View {
        Text("Song")
            .font(.caption2)
            .fontWeight(.medium)
            .frame(width: trackLabelWidth, height: trackHeight)
            .padding(.horizontal, 4)
            .background(Color(.systemGray6))
            .contextMenu {
                Button(role: .destructive) {
                    removeAudio()
                } label: {
                    Label("Remove Song", systemImage: "trash")
                }
            }
    }

    private func audioLaneBar(canvasWidth: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.teal.opacity(0.6))
                .frame(width: canvasWidth, height: trackHeight - 6)
            Text(timeline.audioFileName ?? "")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
                .padding(.horizontal, 8)
        }
        .frame(width: canvasWidth, height: trackHeight)
        .contextMenu {
            Button(role: .destructive) {
                removeAudio()
            } label: {
                Label("Remove Song", systemImage: "trash")
            }
        }
    }

    private func importAudioFile(from url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        let fileId = UUID().uuidString + "-" + url.lastPathComponent
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dest = docs.appendingPathComponent(fileId)

        do {
            try FileManager.default.copyItem(at: url, to: dest)
            timeline.audioFileName = url.lastPathComponent
            timeline.audioFileId = fileId

            // Extend timeline to at least the audio duration
            if let player = try? AVAudioPlayer(contentsOf: dest), player.duration > timeline.totalDuration {
                timeline.totalDuration = ceil(player.duration)
            }

            save()
        } catch {
            print("Failed to copy audio file: \(error)")
        }
    }

    private func removeAudio() {
        if let fileId = timeline.audioFileId {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try? FileManager.default.removeItem(at: docs.appendingPathComponent(fileId))
        }
        timeline.audioFileName = nil
        timeline.audioFileId = nil
        save()
    }

    // MARK: - Helpers

    private func save() {
        KeyStorage.shared.updateTimeline(timeline)
        onUpdate()
    }

    private func removeBlocksOutsideDuration(_ duration: Double) {
        for i in timeline.tracks.indices {
            timeline.tracks[i].blocks.removeAll {
                $0.startTime >= duration || $0.startTime + $0.duration > duration
            }
        }
    }

    private func blocksOutsideDuration(_ duration: Double) -> Int {
        timeline.tracks.flatMap { $0.blocks }.filter {
            $0.startTime >= duration || $0.startTime + $0.duration > duration
        }.count
    }

    private func snapToGrid(_ time: Double) -> Double {
        (time / snapGrid).rounded() * snapGrid
    }

    private func formatTime(_ t: Double) -> String {
        let mins = Int(t) / 60
        let secs = Int(t) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private func totalBarsCount() -> Int {
        let map = TempoMap(events: timeline.effectiveTempoEvents)
        let totalBeats = timeline.totalBeats ?? 32
        let (bar, _) = map.barBeat(forBeat: totalBeats)
        return bar
    }

    private func updateDurationText() {
        if isBeatMode {
            durationText = String(totalBarsCount())
        } else {
            durationText = String(Int(timeline.totalDuration))
        }
    }
}

// MARK: - Editing Info

private struct EditingBlockInfo: Identifiable {
    let id = UUID()
    let trackId: UUID
    let blockId: UUID
    let lightId: UUID
    let lightName: String
    let unicastAddress: UInt16
    let state: CueState
}

// MARK: - Tempo Event Editor

struct TempoEventEditorView: View {
    @State var event: TempoEvent
    let isFirst: Bool
    var onSave: (TempoEvent) -> Void
    var onDelete: () -> Void
    @Environment(\.dismiss) var dismiss

    @State private var bpmText: String = ""

    private let bpmPresets: [Double] = [60, 80, 100, 120, 140, 160]
    private let timeSigPresets: [(Int, Int)] = [(4,4), (3,4), (2,4), (6,8), (5,4), (7,8)]

    var body: some View {
        Form {
            Section("Tempo") {
                HStack {
                    Text("BPM")
                    TextField("BPM", text: $bpmText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .onChange(of: bpmText) { newVal in
                            if let v = Double(newVal), v > 0 { event.bpm = v }
                        }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(bpmPresets, id: \.self) { preset in
                            Button("\(Int(preset))") {
                                event.bpm = preset
                                bpmText = "\(Int(preset))"
                            }
                            .buttonStyle(.bordered)
                            .tint(event.bpm == preset ? .accentColor : .secondary)
                        }
                    }
                }
            }

            Section("Time Signature") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(timeSigPresets, id: \.0) { preset in
                            let ts = TimeSignature(beatsPerBar: preset.0, beatUnit: preset.1)
                            Button(ts.displayString) {
                                event.timeSignature = ts
                            }
                            .buttonStyle(.bordered)
                            .tint(event.timeSignature == ts ? .accentColor : .secondary)
                        }
                    }
                }

                Stepper("Beats per bar: \(event.timeSignature.beatsPerBar)",
                        value: $event.timeSignature.beatsPerBar, in: 1...16)
                Picker("Beat unit", selection: $event.timeSignature.beatUnit) {
                    Text("2").tag(2)
                    Text("4").tag(4)
                    Text("8").tag(8)
                    Text("16").tag(16)
                }
            }

            if !isFirst {
                Section {
                    Button(role: .destructive) {
                        onDelete()
                        dismiss()
                    } label: {
                        Label("Delete Tempo Change", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle(isFirst ? "Initial Tempo" : "Tempo Change")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    onSave(event)
                    dismiss()
                }
            }
        }
        .onAppear {
            bpmText = "\(Int(event.bpm))"
        }
    }
}

// MARK: - Light Picker for Timeline Tracks

struct TimelineLightPickerView: View {
    let existingIds: Set<UUID>
    var onSelect: (SavedLight) -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        let lights = KeyStorage.shared.savedLights
        let available = lights.filter { !existingIds.contains($0.id) }

        List {
            if available.isEmpty {
                Text("All lights are already in the timeline.")
                    .foregroundColor(.secondary)
            }
            ForEach(available, id: \.id) { light in
                Button {
                    onSelect(light)
                } label: {
                    HStack {
                        Image(systemName: "lightbulb.fill")
                            .foregroundColor(.yellow)
                        Text(light.name)
                    }
                }
            }
        }
        .navigationTitle("Add Light")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }
}

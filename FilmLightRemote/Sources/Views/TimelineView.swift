import SwiftUI

/// Visual block-timeline editor and player for a single Timeline.
struct TimelineView: View {
    @EnvironmentObject var bleManager: BLEManager
    @StateObject private var engine = TimelineEngine()
    @State var timeline: Timeline
    var onUpdate: () -> Void

    // Zoom: points per second
    @State private var ptsPerSecond: CGFloat = 40
    @State private var scrollOffset: CGFloat = 0

    // Editing state
    @State private var editingBlock: EditingBlockInfo?
    @State private var showLightPicker = false
    @State private var showDurationEditor = false
    @State private var durationText = ""

    // Dragging
    @State private var draggingBlockId: UUID?
    @State private var draggingTrackId: UUID?
    @State private var dragStartTime: Double = 0

    // Resizing
    @State private var resizingBlockId: UUID?
    @State private var resizingTrackId: UUID?

    private let trackLabelWidth: CGFloat = 70
    private let trackHeight: CGFloat = 50
    private let rulerHeight: CGFloat = 30
    private let snapGrid: Double = 0.25

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
                        Label("Add Track", systemImage: "plus")
                    }
                    Button { showDurationEditor = true } label: {
                        Label("Set Duration", systemImage: "clock")
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
        .alert("Timeline Duration", isPresented: $showDurationEditor) {
            TextField("Seconds", text: $durationText)
                .keyboardType(.decimalPad)
            Button("Cancel", role: .cancel) {}
            Button("Set") {
                if let d = Double(durationText), d > 0 {
                    timeline.totalDuration = d
                    save()
                }
            }
        } message: {
            Text("Set the total timeline length in seconds.")
        }
        .onAppear {
            engine.bleManager = bleManager
            durationText = String(Int(timeline.totalDuration))
        }
        .onDisappear {
            engine.stop()
        }
    }

    // MARK: - Timeline Canvas

    private var timelineCanvas: some View {
        GeometryReader { geo in
            let canvasWidth = ptsPerSecond * CGFloat(timeline.totalDuration)

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
                        let newPts = max(15, min(200, ptsPerSecond * scale))
                        ptsPerSecond = newPts
                    }
            )
        }
    }

    private var totalCanvasHeight: CGFloat {
        rulerHeight + CGFloat(timeline.tracks.count) * (trackHeight + 1)
    }

    // MARK: - Time Ruler

    private func timeRuler(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color(.systemGray5))
                .frame(width: width, height: rulerHeight)

            // Tick marks
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

    private func rulerInterval() -> Double {
        if ptsPerSecond > 80 { return 1 }
        if ptsPerSecond > 30 { return 5 }
        return 10
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
        let x = trackLabelWidth + CGFloat(engine.currentTime) * ptsPerSecond
        return Rectangle()
            .fill(Color.red)
            .frame(width: 2, height: canvasHeight)
            .offset(x: x)
    }

    // MARK: - Transport Bar

    private var transportBar: some View {
        HStack(spacing: 20) {
            // Rewind
            Button {
                engine.stop()
                engine.currentTime = 0
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

            Spacer()

            // Time display
            Text("\(formatTime(engine.currentTime)) / \(formatTime(timeline.totalDuration))")
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(.systemGray6))
    }

    // MARK: - Block Operations

    private func addBlock(to trackId: UUID, at time: Double) {
        guard let idx = timeline.tracks.firstIndex(where: { $0.id == trackId }) else { return }
        let clamped = min(time, timeline.totalDuration - 1)
        let block = TimelineBlock(startTime: max(0, clamped), duration: 2)
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
        let snapped = snapToGrid(max(0, min(newTime, timeline.totalDuration - timeline.tracks[tIdx].blocks[bIdx].duration)))
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
        let deltaSec = Double(dragX) / Double(ptsPerSecond)
        let newDur = max(0.25, block.duration + deltaSec)
        let maxDur = timeline.totalDuration - block.startTime
        timeline.tracks[tIdx].blocks[bIdx].duration = snapToGrid(min(newDur, maxDur))
    }

    private func applyBlockEdit(trackId: UUID, blockId: UUID, newState: CueState) {
        guard let tIdx = timeline.tracks.firstIndex(where: { $0.id == trackId }),
              let bIdx = timeline.tracks[tIdx].blocks.firstIndex(where: { $0.id == blockId }) else { return }
        timeline.tracks[tIdx].blocks[bIdx].state = newState
        save()
    }

    // MARK: - Helpers

    private func save() {
        KeyStorage.shared.updateTimeline(timeline)
        onUpdate()
    }

    private func snapToGrid(_ time: Double) -> Double {
        (time / snapGrid).rounded() * snapGrid
    }

    private func formatTime(_ t: Double) -> String {
        let mins = Int(t) / 60
        let secs = Int(t) % 60
        return String(format: "%d:%02d", mins, secs)
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
        .navigationTitle("Add Track")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }
}

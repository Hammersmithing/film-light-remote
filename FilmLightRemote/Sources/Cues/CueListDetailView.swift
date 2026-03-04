import SwiftUI

/// QLab-style cue runner — shows cues in a list with a big GO button.
///
/// Connection strategy: All commands route through the ESP32 bridge via WebSocket.
/// The bridge handles BLE connections to individual lights.
struct CueListDetailView: View {
    @EnvironmentObject var bleManager: BLEManager
    @ObservedObject private var bridgeManager = BridgeManager.shared
    @StateObject private var engine = CueEngine()
    @State private var cueList: CueList
    @State private var showingAddCue = false
    @State private var editingCue: Cue?
    var onUpdate: () -> Void

    init(cueList: CueList, onUpdate: @escaping () -> Void) {
        _cueList = State(initialValue: cueList)
        self.onUpdate = onUpdate
    }

    private var isReady: Bool {
        bridgeManager.isConnected || bleManager.connectionState == .ready
    }

    var body: some View {
        VStack(spacing: 0) {
            // Connection status
            connectionBanner

            // Cue list
            if cueList.cues.isEmpty {
                emptyCueState
            } else {
                cueListContent
            }

            // GO button
            goButton
        }
        .navigationTitle(cueList.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        addCue()
                    } label: {
                        Label("Add Cue", systemImage: "plus")
                    }
                    Button {
                        engine.reset()
                    } label: {
                        Label("Reset to Top", systemImage: "arrow.counterclockwise")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(item: $editingCue) { cue in
            NavigationStack {
                CueEditorView(cue: cue) { updatedCue in
                    if let idx = cueList.cues.firstIndex(where: { $0.id == updatedCue.id }) {
                        cueList.cues[idx] = updatedCue
                    }
                    saveCueList()
                    editingCue = nil
                }
            }
        }
        .onAppear {
            engine.bleManager = bleManager
        }
    }

    // MARK: - Connection Banner

    private var connectionBanner: some View {
        HStack(spacing: 6) {
            if isReady {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                Text("Bridge connected")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                Text("Bridge not connected")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color(.systemGray6))
    }

    // MARK: - Empty State

    private var emptyCueState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "theatermask.and.paintbrush")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("No Cues")
                .font(.headline)
            Text("Add cues to program lighting looks.")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Button("Add Cue") { addCue() }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
    }

    // MARK: - Cue List

    private var cueListContent: some View {
        List {
            ForEach(Array(cueList.cues.enumerated()), id: \.element.id) { index, cue in
                CueRow(
                    index: index,
                    cue: cue,
                    isActive: engine.currentCueIndex == index && engine.isRunning,
                    isNext: engine.currentCueIndex == index && !engine.isRunning
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    editingCue = cue
                }
            }
            .onDelete { offsets in
                cueList.cues.remove(atOffsets: offsets)
                saveCueList()
            }
            .onMove { from, to in
                cueList.cues.move(fromOffsets: from, toOffset: to)
                saveCueList()
            }
        }
        .listStyle(.plain)
    }

    // MARK: - GO / Stop / Reset Buttons

    private var goButton: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    engine.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.red)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                Button {
                    engine.reset()
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.orange)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
            }
            Button {
                fireCue()
            } label: {
                Text("GO")
                    .font(.system(size: 36, weight: .black, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .background(isReady ? Color.green : Color.gray)
                    .foregroundColor(.white)
                    .cornerRadius(16)
            }
            .disabled(cueList.cues.isEmpty || !isReady)
        }
        .padding()
    }

    // MARK: - Actions

    private func addCue() {
        let cue = Cue(name: "Cue \(cueList.cues.count + 1)")
        cueList.cues.append(cue)
        saveCueList()
        editingCue = cue
    }

    private func fireCue() {
        guard !cueList.cues.isEmpty else { return }
        let index = engine.currentCueIndex
        guard index < cueList.cues.count else {
            engine.reset()
            return
        }
        engine.fireCue(cueList.cues[index], allCues: cueList.cues)
    }

    private func saveCueList() {
        KeyStorage.shared.updateCueList(cueList)
        onUpdate()
    }
}

// MARK: - Cue Row

private struct CueRow: View {
    let index: Int
    let cue: Cue
    let isActive: Bool
    let isNext: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Cue number
            Text("\(index + 1)")
                .font(.system(.title3, design: .rounded))
                .fontWeight(.bold)
                .foregroundColor(isActive ? .green : (isNext ? .orange : .secondary))
                .frame(width: 32)

            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(cue.name)
                    .font(.body)
                    .fontWeight(isActive || isNext ? .semibold : .regular)

                HStack(spacing: 8) {
                    // Light count
                    Label("\(cue.lightEntries.count)", systemImage: "lightbulb")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    // Duration
                    if cue.fadeTime > 0 {
                        Label(String(format: "%.2fs", cue.fadeTime), systemImage: "timer")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    // Delay
                    if cue.followDelay > 0 {
                        Label(String(format: "%.2fs delay", cue.followDelay), systemImage: "clock")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    // Auto-follow
                    if cue.autoFollow {
                        Label("Auto", systemImage: "arrow.forward.circle")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                }
            }

            Spacer()

            // Active indicator
            if isActive {
                Image(systemName: "play.fill")
                    .foregroundColor(.green)
                    .font(.caption)
            } else if isNext {
                Image(systemName: "chevron.right")
                    .foregroundColor(.orange)
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(
            isActive ? Color.green.opacity(0.1) :
            isNext ? Color.orange.opacity(0.05) :
            Color.clear
        )
    }
}

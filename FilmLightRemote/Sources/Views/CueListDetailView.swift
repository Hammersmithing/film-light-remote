import SwiftUI

/// QLab-style cue runner — shows cues in a list with a big GO button.
///
/// Connection strategy: BLE mesh means we only need ONE proxy connection to
/// address ANY light by unicast. On appear, we auto-connect to the first
/// available saved light to establish that proxy. All cue commands route
/// through it to different unicast addresses.
struct CueListDetailView: View {
    @EnvironmentObject var bleManager: BLEManager
    @StateObject private var engine = CueEngine()
    @State private var cueList: CueList
    @State private var showingAddCue = false
    @State private var editingCue: Cue?
    @State private var isConnecting = false
    var onUpdate: () -> Void

    init(cueList: CueList, onUpdate: @escaping () -> Void) {
        _cueList = State(initialValue: cueList)
        self.onUpdate = onUpdate
    }

    private var isConnected: Bool {
        bleManager.connectedPeripheral != nil
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
            // Auto-connect to mesh proxy if not already connected
            if !isConnected {
                connectToMeshProxy()
            }
        }
        .onReceive(bleManager.$connectionState) { state in
            switch state {
            case .ready, .connected:
                isConnecting = false
            case .failed:
                isConnecting = false
            case .disconnected:
                isConnecting = false
            default:
                break
            }
        }
    }

    // MARK: - Connection Banner

    private var connectionBanner: some View {
        HStack(spacing: 6) {
            if isConnecting {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Connecting to mesh...")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else if isConnected {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                Text("Mesh proxy connected")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                Text("Not connected")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Connect") {
                    connectToMeshProxy()
                }
                .font(.caption2)
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
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

    // MARK: - GO Button

    private var goButton: some View {
        Button {
            fireCue()
        } label: {
            Text("GO")
                .font(.system(size: 36, weight: .black, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .background(isConnected ? Color.green : Color.gray)
                .foregroundColor(.white)
                .cornerRadius(16)
        }
        .disabled(cueList.cues.isEmpty || !isConnected)
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

    /// Connect to the first available saved light as a mesh proxy.
    /// Any single mesh node can relay commands to all other nodes.
    private func connectToMeshProxy() {
        // Prefer lights that are in this cue list's cues
        let cueListLightIds = Set(cueList.cues.flatMap { $0.lightEntries.map(\.lightId) })
        let savedLights = KeyStorage.shared.savedLights

        // Try cue-referenced lights first, then any saved light
        let preferred = savedLights.filter { cueListLightIds.contains($0.id) }
        let candidates = preferred.isEmpty ? savedLights : preferred

        guard let proxy = candidates.first else { return }

        isConnecting = true
        bleManager.connectToKnownPeripheral(identifier: proxy.peripheralIdentifier)
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

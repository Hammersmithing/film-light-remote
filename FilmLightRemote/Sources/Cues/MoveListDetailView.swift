import SwiftUI

/// Move runner — shows moves in a list with Play All and Next buttons.
struct MoveListDetailView: View {
    @EnvironmentObject var bleManager: BLEManager
    @StateObject private var engine = MoveEngine()
    @State private var moveList: MoveList
    @State private var editingMove: Move?
    @State private var pendingAction: PendingAction?
    var onUpdate: () -> Void

    enum PendingAction { case playAll, next }

    init(moveList: MoveList, onUpdate: @escaping () -> Void) {
        _moveList = State(initialValue: moveList)
        self.onUpdate = onUpdate
    }

    private var isReady: Bool {
        bleManager.connectionState == .ready
    }

    var body: some View {
        VStack(spacing: 0) {
            connectionBanner

            if moveList.moves.isEmpty {
                emptyState
            } else {
                moveListContent
            }

            controlButtons
        }
        .navigationTitle(moveList.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        addMove()
                    } label: {
                        Label("Add Move", systemImage: "plus")
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
        .sheet(item: $editingMove, onDismiss: {
            // Reconnect after light editor disconnects
            connectToProxyIfNeeded()
        }) { move in
            NavigationStack {
                MoveEditorView(move: move, moveList: moveList) { updatedMove in
                    if let idx = moveList.moves.firstIndex(where: { $0.id == updatedMove.id }) {
                        moveList.moves[idx] = updatedMove
                    }
                    saveMoveList()
                    editingMove = nil
                }
            }
        }
        .onAppear {
            engine.bleManager = bleManager
            connectToProxyIfNeeded()
        }
        .onChange(of: bleManager.connectionState) { _ in
            if bleManager.connectionState == .ready, let action = pendingAction {
                pendingAction = nil
                switch action {
                case .playAll: doPlayAll()
                case .next: doPlayNext()
                }
            }
        }
    }

    // MARK: - Connection Banner

    private var connectionBanner: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isReady ? Color.green : (pendingAction != nil || bleManager.connectionState == .connecting || bleManager.connectionState == .discoveringServices ? Color.orange : Color.red))
                .frame(width: 8, height: 8)
            Text(isReady ? "BLE connected" : (pendingAction != nil || bleManager.connectionState == .connecting || bleManager.connectionState == .discoveringServices ? "Connecting..." : "Not connected"))
                .font(.caption2)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color(.systemGray6))
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "arrow.right.arrow.left")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("No Moves")
                .font(.headline)
            Text("Add moves to create lighting transitions.")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Button("Add Move") { addMove() }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
    }

    // MARK: - Move List

    private var moveListContent: some View {
        List {
            ForEach(Array(moveList.moves.enumerated()), id: \.element.id) { index, move in
                MoveRow(
                    index: index,
                    move: move,
                    isActive: engine.currentMoveIndex == index && engine.isRunning,
                    isNext: engine.currentMoveIndex == index && !engine.isRunning
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    editingMove = move
                }
            }
            .onDelete { offsets in
                moveList.moves.remove(atOffsets: offsets)
                saveMoveList()
            }
            .onMove { from, to in
                moveList.moves.move(fromOffsets: from, toOffset: to)
                saveMoveList()
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Control Buttons

    private var controlButtons: some View {
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

            HStack(spacing: 12) {
                Button {
                    doPlayNext()
                } label: {
                    Text("Next")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(moveList.moves.isEmpty ? Color.gray : Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(14)
                }
                .disabled(moveList.moves.isEmpty)

                Button {
                    doPlayAll()
                } label: {
                    Text("Play All")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(moveList.moves.isEmpty ? Color.gray : Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(14)
                }
                .disabled(moveList.moves.isEmpty)
            }
        }
        .padding()
    }

    // MARK: - Actions

    private func addMove() {
        let move = Move(name: "Move \(moveList.moves.count + 1)")
        moveList.moves.append(move)
        saveMoveList()
        editingMove = move
    }

    private func doPlayAll() {
        guard !moveList.moves.isEmpty else { return }
        if !isReady {
            pendingAction = .playAll
            connectToProxyIfNeeded()
            return
        }
        engine.playAll(moves: moveList.moves)
    }

    private func doPlayNext() {
        guard !moveList.moves.isEmpty else { return }
        if !isReady {
            pendingAction = .next
            connectToProxyIfNeeded()
            return
        }
        guard engine.currentMoveIndex < moveList.moves.count else {
            engine.reset()
            return
        }
        engine.playNext(moves: moveList.moves)
    }

    private func connectToProxyIfNeeded() {
        guard !isReady else { return }
        let savedLights = KeyStorage.shared.savedLights
        for move in moveList.moves {
            for entry in move.lightEntries {
                if let saved = savedLights.first(where: { $0.id == entry.lightId }) {
                    bleManager.connectToKnownPeripheral(identifier: saved.peripheralIdentifier)
                    return
                }
            }
        }
    }

    private func saveMoveList() {
        KeyStorage.shared.updateMoveList(moveList)
        onUpdate()
    }
}

// MARK: - Move Row

private struct MoveRow: View {
    let index: Int
    let move: Move
    let isActive: Bool
    let isNext: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text("\(index + 1)")
                .font(.system(.title3, design: .rounded))
                .fontWeight(.bold)
                .foregroundColor(isActive ? .green : (isNext ? .blue : .secondary))
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(move.name)
                    .font(.body)
                    .fontWeight(isActive || isNext ? .semibold : .regular)

                HStack(spacing: 8) {
                    Label("\(move.lightEntries.count)", systemImage: "lightbulb")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    if move.fadeTime > 0 {
                        Label(String(format: "%.1fs", move.fadeTime), systemImage: "waveform.path")
                            .font(.caption2)
                            .foregroundColor(.blue)
                    }

                    if move.waitTime > 0 {
                        Label(String(format: "%.1fs wait", move.waitTime), systemImage: "clock")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                // Show from → to for first light as preview
                if let entry = move.lightEntries.first {
                    HStack(spacing: 4) {
                        Text(entry.fromState.shortSummary)
                            .foregroundColor(.secondary)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                        Text(entry.toState.shortSummary)
                            .foregroundColor(.primary)
                    }
                    .font(.caption2)
                }
            }

            Spacer()

            if isActive {
                Image(systemName: "play.fill")
                    .foregroundColor(.green)
                    .font(.caption)
            } else if isNext {
                Image(systemName: "chevron.right")
                    .foregroundColor(.blue)
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(
            isActive ? Color.green.opacity(0.1) :
            isNext ? Color.blue.opacity(0.05) :
            Color.clear
        )
    }
}

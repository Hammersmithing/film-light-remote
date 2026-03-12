import SwiftUI

/// Edit a single move — name, timing, and per-light from/to states.
struct MoveEditorView: View {
    @State private var move: Move
    @State private var showingLightPicker = false
    @State private var editingEntry: MoveLightEntry?
    @State private var copiedFrom: CueState?
    @State private var copiedTo: CueState?
    @State private var fadeText: String = ""
    @State private var waitText: String = ""
    @State private var savedFadeText: String = ""
    @State private var savedWaitText: String = ""
    @FocusState private var focusedField: TimingField?
    let moveList: MoveList
    var onSave: (Move) -> Void

    enum TimingField { case fade, wait }

    init(move: Move, moveList: MoveList, onSave: @escaping (Move) -> Void) {
        _move = State(initialValue: move)
        _fadeText = State(initialValue: Self.formatSeconds(move.fadeTime))
        _waitText = State(initialValue: Self.formatSeconds(move.waitTime))
        self.moveList = moveList
        self.onSave = onSave
    }

    private static func formatSeconds(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private static func parseSeconds(_ text: String, ceiling: Double) -> Double {
        let cleaned = text.trimmingCharacters(in: .whitespaces)
        guard let val = Double(cleaned) else { return 0 }
        return Swift.min(Swift.max(val, 0), ceiling)
    }

    private var isEditingTiming: Bool { focusedField != nil }

    var body: some View {
        ZStack(alignment: .bottom) {
            Form {
                Section("Move Name") {
                    TextField("Name", text: $move.name)
                }

                Section {
                    HStack {
                        Text("Fade")
                        Spacer()
                        TextField("0.00", text: $fadeText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .focused($focusedField, equals: .fade)
                            .frame(width: 70)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(.systemGray5))
                            .cornerRadius(6)
                            .onChange(of: fadeText) { _ in
                                move.fadeTime = Self.parseSeconds(fadeText, ceiling: 30)
                            }
                        Text("sec")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }

                    HStack {
                        Text("Wait")
                        Spacer()
                        TextField("0.00", text: $waitText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .focused($focusedField, equals: .wait)
                            .frame(width: 70)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(.systemGray5))
                            .cornerRadius(6)
                            .onChange(of: waitText) { _ in
                                move.waitTime = Self.parseSeconds(waitText, ceiling: 30)
                            }
                        Text("sec")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                } header: {
                    Text("Timing")
                } footer: {
                    Text(move.fadeTime > 0 ? "Fades from A to B over \(Self.formatSeconds(move.fadeTime))s." : "Snaps instantly to target.")
                    + Text(move.waitTime > 0 ? " Waits \(Self.formatSeconds(move.waitTime))s before next move." : "")
                }

                Section {
                    if move.lightEntries.isEmpty {
                        Text("No lights in this move")
                            .foregroundColor(.secondary)
                            .italic()
                    } else {
                        ForEach(move.lightEntries) { entry in
                            HStack(spacing: 0) {
                                MoveLightEntryRow(entry: entry)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        editingEntry = entry
                                    }

                                Menu {
                                    Button {
                                        copiedFrom = entry.fromState
                                        copiedTo = entry.toState
                                    } label: {
                                        Label("Copy Settings", systemImage: "doc.on.doc")
                                    }

                                    if copiedTo != nil {
                                        Button {
                                            if let idx = move.lightEntries.firstIndex(where: { $0.id == entry.id }) {
                                                if let from = copiedFrom { move.lightEntries[idx].fromState = from }
                                                if let to = copiedTo { move.lightEntries[idx].toState = to }
                                            }
                                        } label: {
                                            Label("Paste Settings", systemImage: "doc.on.clipboard")
                                        }
                                    }

                                    Divider()

                                    Button(role: .destructive) {
                                        move.lightEntries.removeAll { $0.id == entry.id }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                } label: {
                                    Image(systemName: "ellipsis")
                                        .font(.body)
                                        .foregroundColor(.secondary)
                                        .padding(.leading, 8)
                                        .padding(.vertical, 8)
                                }
                            }
                        }
                    }

                    Button {
                        showingLightPicker = true
                    } label: {
                        Label("Add Light", systemImage: "plus.circle")
                    }
                } header: {
                    Text("Lights")
                }
            }
        }
        .navigationTitle("Edit Move")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    commitField()
                    onSave(move)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isEditingTiming {
                HStack {
                    Button("Cancel") { cancelField() }
                        .foregroundColor(.red)
                    Spacer()
                    Button("Done") { commitField() }
                        .fontWeight(.semibold)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(.bar)
            }
        }
        .onChange(of: focusedField) { newField in
            if newField == .fade {
                savedFadeText = fadeText
                fadeText = ""
            } else if newField == .wait {
                savedWaitText = waitText
                waitText = ""
            }
        }
        .sheet(isPresented: $showingLightPicker) {
            SavedLightPickerView(existingIds: Set(move.lightEntries.map(\.lightId))) { light in
                // Default fromState: use previous move's toState for this light if available
                let defaultFrom = previousToState(for: light.id) ?? CueState()
                let entry = MoveLightEntry(
                    lightId: light.id,
                    lightName: light.name,
                    unicastAddress: light.unicastAddress,
                    fromState: defaultFrom,
                    toState: defaultFrom
                )
                move.lightEntries.append(entry)
                showingLightPicker = false
                editingEntry = entry
            }
        }
        .sheet(item: $editingEntry) { entry in
            NavigationStack {
                MoveLightEditorView(entry: entry) { updatedEntry in
                    if let idx = move.lightEntries.firstIndex(where: { $0.id == updatedEntry.id }) {
                        move.lightEntries[idx] = updatedEntry
                    }
                    editingEntry = nil
                }
            }
            .id(entry.id)
        }
    }

    /// Find the previous move's "to" state for a given light.
    private func previousToState(for lightId: UUID) -> CueState? {
        guard let moveIndex = moveList.moves.firstIndex(where: { $0.id == move.id }),
              moveIndex > 0 else { return nil }
        let prevMove = moveList.moves[moveIndex - 1]
        return prevMove.lightEntries.first(where: { $0.lightId == lightId })?.toState
    }

    private func commitField() {
        if focusedField == .fade {
            move.fadeTime = Self.parseSeconds(fadeText, ceiling: 30)
            fadeText = Self.formatSeconds(move.fadeTime)
        } else if focusedField == .wait {
            move.waitTime = Self.parseSeconds(waitText, ceiling: 30)
            waitText = Self.formatSeconds(move.waitTime)
        }
        focusedField = nil
    }

    private func cancelField() {
        if focusedField == .fade {
            fadeText = savedFadeText
        } else if focusedField == .wait {
            waitText = savedWaitText
        }
        focusedField = nil
    }
}

// MARK: - Light Entry Row

private struct MoveLightEntryRow: View {
    let entry: MoveLightEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lightbulb.fill")
                .foregroundColor(.yellow)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.lightName)
                    .font(.body)
                    .fontWeight(.medium)

                HStack(spacing: 4) {
                    Text(entry.fromState.shortSummary)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                    Text(entry.toState.shortSummary)
                        .font(.caption)
                        .foregroundColor(.primary)
                }
            }

            Spacer()

            Circle()
                .fill(entry.toState.isOn ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Saved Light Picker

struct SavedLightPickerView: View {
    let existingIds: Set<UUID>
    var onSelect: (SavedLight) -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            let lights = KeyStorage.shared.savedLights
            let available = lights.filter { !existingIds.contains($0.id) }

            List {
                if available.isEmpty {
                    if lights.isEmpty {
                        Text("No saved lights. Add lights in the Lights tab first.")
                            .foregroundColor(.secondary)
                    } else {
                        Text("All saved lights are already in this move.")
                            .foregroundColor(.secondary)
                    }
                } else {
                    ForEach(available) { light in
                        Button {
                            onSelect(light)
                        } label: {
                            HStack {
                                Image(systemName: "lightbulb.fill")
                                    .foregroundColor(.yellow)
                                VStack(alignment: .leading) {
                                    Text(light.name)
                                        .foregroundColor(.primary)
                                    Text(light.lightType)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
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
}

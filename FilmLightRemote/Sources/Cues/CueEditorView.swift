import SwiftUI

/// Edit a single cue — name, timing, and per-light states.
struct CueEditorView: View {
    @State private var cue: Cue
    @State private var showingLightPicker = false
    @State private var editingEntry: LightCueEntry?
    @State private var copiedState: CueState?
    @State private var delayText: String = ""
    @State private var durationText: String = ""
    @State private var savedDelayText: String = ""
    @State private var savedDurationText: String = ""
    @FocusState private var focusedField: TimingField?
    var onSave: (Cue) -> Void

    enum TimingField { case delay, duration }

    init(cue: Cue, onSave: @escaping (Cue) -> Void) {
        _cue = State(initialValue: cue)
        _delayText = State(initialValue: Self.formatSeconds(cue.followDelay))
        _durationText = State(initialValue: Self.formatSeconds(cue.fadeTime))
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
                // Name
                Section("Cue Name") {
                    TextField("Name", text: $cue.name)
                }

                // Timing
                Section {
                    // Auto-follow toggle at top
                    Toggle("Auto Start", isOn: $cue.autoFollow)

                    // Delay
                    HStack {
                        Text("Delay")
                        Spacer()
                        TextField("0.00", text: $delayText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .focused($focusedField, equals: .delay)
                            .frame(width: 70)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(.systemGray5))
                            .cornerRadius(6)
                            .onChange(of: delayText) { _ in
                                cue.followDelay = Self.parseSeconds(delayText, ceiling: 8)
                            }
                        Text("sec")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }

                    // Duration
                    HStack {
                        Text("Duration")
                        Spacer()
                        TextField("0.00", text: $durationText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .focused($focusedField, equals: .duration)
                            .frame(width: 70)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(.systemGray5))
                            .cornerRadius(6)
                            .onChange(of: durationText) { _ in
                                cue.fadeTime = Self.parseSeconds(durationText, ceiling: 30)
                            }
                        Text("sec")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                } header: {
                    Text("Timing")
                } footer: {
                    if cue.fadeTime == 0 {
                        Text("Duration 0 = stays active until next GO.")
                    } else {
                        Text("Light holds for \(Self.formatSeconds(cue.fadeTime))s then the cue ends.")
                    }
                }

                // Lights
                Section {
                    if cue.lightEntries.isEmpty {
                        Text("No lights in this cue")
                            .foregroundColor(.secondary)
                            .italic()
                    } else {
                        ForEach(cue.lightEntries) { entry in
                            HStack(spacing: 0) {
                                LightEntryRow(entry: entry)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        editingEntry = entry
                                    }

                                Menu {
                                    Button {
                                        copiedState = entry.state
                                    } label: {
                                        Label("Copy Settings", systemImage: "doc.on.doc")
                                    }

                                    if copiedState != nil {
                                        Button {
                                            if let idx = cue.lightEntries.firstIndex(where: { $0.id == entry.id }),
                                               let state = copiedState {
                                                cue.lightEntries[idx].state = state
                                            }
                                        } label: {
                                            Label("Paste Settings", systemImage: "doc.on.clipboard")
                                        }
                                    }

                                    Divider()

                                    Button(role: .destructive) {
                                        cue.lightEntries.removeAll { $0.id == entry.id }
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
        .navigationTitle("Edit Cue")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    commitField()
                    onSave(cue)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isEditingTiming {
                HStack {
                    Button("Cancel") {
                        cancelField()
                    }
                    .foregroundColor(.red)
                    Spacer()
                    Button("Done") {
                        commitField()
                    }
                    .fontWeight(.semibold)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(.bar)
            }
        }
        .onChange(of: focusedField) { newField in
            // Save the current text so Cancel can revert, then clear for fresh input
            if newField == .delay {
                savedDelayText = delayText
                delayText = ""
            } else if newField == .duration {
                savedDurationText = durationText
                durationText = ""
            }
        }
        .sheet(isPresented: $showingLightPicker) {
            SavedLightPickerView(existingIds: Set(cue.lightEntries.map(\.lightId))) { light in
                let entry = LightCueEntry(
                    lightId: light.id,
                    lightName: light.name,
                    unicastAddress: light.unicastAddress
                )
                cue.lightEntries.append(entry)
                showingLightPicker = false
                // Open editor immediately for the new entry
                editingEntry = entry
            }
        }
        .sheet(item: $editingEntry) { entry in
            NavigationStack {
                CueLightEditorView(entry: entry) { updatedEntry in
                    if let idx = cue.lightEntries.firstIndex(where: { $0.id == updatedEntry.id }) {
                        cue.lightEntries[idx] = updatedEntry
                    }
                    editingEntry = nil
                }
            }
            .id(entry.id)
        }
    }

    private func commitField() {
        if focusedField == .delay {
            cue.followDelay = Self.parseSeconds(delayText, ceiling: 8)
            delayText = Self.formatSeconds(cue.followDelay)
        } else if focusedField == .duration {
            cue.fadeTime = Self.parseSeconds(durationText, ceiling: 30)
            durationText = Self.formatSeconds(cue.fadeTime)
        }
        focusedField = nil
    }

    private func cancelField() {
        if focusedField == .delay {
            delayText = savedDelayText
        } else if focusedField == .duration {
            durationText = savedDurationText
        }
        focusedField = nil
    }
}

// MARK: - Light Entry Row

private struct LightEntryRow: View {
    let entry: LightCueEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lightbulb.fill")
                .foregroundColor(.yellow)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.lightName)
                    .font(.body)
                    .fontWeight(.medium)
                Text(entry.state.modeSummary)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Power indicator
            Circle()
                .fill(entry.state.isOn ? Color.green : Color.gray)
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
                        Text("All saved lights are already in this cue.")
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

import SwiftUI

struct GroupsView: View {
    @EnvironmentObject var bleManager: BLEManager
    @State private var groups: [LightGroup] = []
    @State private var showingNewGroup = false
    @State private var newGroupName = ""
    @State private var renamingGroup: LightGroup?
    @State private var renameText = ""
    @State private var editingGroup: LightGroup?
    @State private var activeSessionGroup: LightGroup?

    var body: some View {
        NavigationStack {
            Group {
                if groups.isEmpty {
                    emptyState
                } else {
                    groupsList
                }
            }
            .navigationTitle("Groups")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        newGroupName = ""
                        showingNewGroup = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .alert("New Group", isPresented: $showingNewGroup) {
                TextField("Group name", text: $newGroupName)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    guard !newGroupName.isEmpty else { return }
                    let group = LightGroup(name: newGroupName)
                    KeyStorage.shared.addLightGroup(group)
                    reloadGroups()
                    // Open edit sheet immediately so user can add lights
                    editingGroup = groups.first { $0.id == group.id }
                }
            } message: {
                Text("Enter a name for this group.")
            }
            .alert("Rename Group", isPresented: Binding(
                get: { renamingGroup != nil },
                set: { if !$0 { renamingGroup = nil } }
            )) {
                TextField("Group name", text: $renameText)
                Button("Cancel", role: .cancel) { renamingGroup = nil }
                Button("Save") {
                    if var group = renamingGroup, !renameText.isEmpty {
                        group.name = renameText
                        KeyStorage.shared.updateLightGroup(group)
                        reloadGroups()
                    }
                    renamingGroup = nil
                }
            } message: {
                Text("Enter a new name for this group.")
            }
            .sheet(item: $editingGroup) { group in
                GroupEditSheet(group: group) {
                    reloadGroups()
                }
            }
            .fullScreenCover(item: $activeSessionGroup) { group in
                GroupSessionView(group: group)
            }
            .onAppear {
                reloadGroups()
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "rectangle.3.group")
                .font(.system(size: 70))
                .foregroundColor(.secondary)

            Text("No Groups Yet")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Organize lights into groups for quick access")
                .font(.body)
                .foregroundColor(.secondary)

            Button {
                newGroupName = ""
                showingNewGroup = true
            } label: {
                Label("Create Group", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .padding(.horizontal, 40)

            Spacer()
        }
        .padding()
    }

    // MARK: - Groups List

    private var groupsList: some View {
        List {
            ForEach(groups) { group in
                Button {
                    activeSessionGroup = group
                } label: {
                    GroupRow(group: group, onRename: {
                        renameText = group.name
                        renamingGroup = group
                    }, onEditLights: {
                        editingGroup = group
                    }, onDelete: {
                        KeyStorage.shared.removeLightGroup(group)
                        reloadGroups()
                    })
                }
                .tint(.primary)
            }
        }
    }

    // MARK: - Actions

    private func reloadGroups() {
        groups = KeyStorage.shared.lightGroups
    }
}

// MARK: - Group Row

private struct GroupRow: View {
    let group: LightGroup
    var onRename: () -> Void
    var onEditLights: () -> Void
    var onDelete: () -> Void

    private var lightNames: String {
        let allLights = KeyStorage.shared.savedLights
        let names = group.lightIds.compactMap { id in
            allLights.first { $0.id == id }?.name
        }
        if names.isEmpty { return "No lights" }
        return names.joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "rectangle.3.group.fill")
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(group.name)
                    .font(.body)
                    .fontWeight(.medium)

                Text("\(group.lightIds.count) light\(group.lightIds.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(lightNames)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Menu {
                Button {
                    onRename()
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button {
                    onEditLights()
                } label: {
                    Label("Edit Lights", systemImage: "lightbulb.2")
                }
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Group Edit Sheet

private struct GroupEditSheet: View {
    @Environment(\.dismiss) var dismiss
    @State private var group: LightGroup
    @State private var allLights: [SavedLight] = []
    let onSave: () -> Void

    init(group: LightGroup, onSave: @escaping () -> Void) {
        _group = State(initialValue: group)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            List {
                if allLights.isEmpty {
                    Text("No saved lights. Add lights from the Lights tab first.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(allLights) { light in
                        let isSelected = group.lightIds.contains(light.id)
                        Button {
                            if isSelected {
                                group.lightIds.removeAll { $0 == light.id }
                            } else {
                                group.lightIds.append(light.id)
                            }
                            KeyStorage.shared.updateLightGroup(group)
                            onSave()
                        } label: {
                            HStack {
                                Image(systemName: "lightbulb.fill")
                                    .foregroundColor(.yellow)
                                VStack(alignment: .leading) {
                                    Text(light.name)
                                    Text(light.lightType)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if isSelected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.accentColor)
                                } else {
                                    Image(systemName: "circle")
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .tint(.primary)
                    }
                }
            }
            .navigationTitle("Edit \(group.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                allLights = KeyStorage.shared.savedLights
            }
        }
    }
}

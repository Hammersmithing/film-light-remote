import SwiftUI

/// Top-level cue lists view — lists all cue lists with add/rename/delete.
struct CuesView: View {
    @EnvironmentObject var bleManager: BLEManager
    @State private var cueLists: [CueList] = []
    @State private var renamingList: CueList?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            Group {
                if cueLists.isEmpty {
                    emptyState
                } else {
                    listContent
                }
            }
            .navigationTitle("Cues")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        addCueList()
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .alert("Rename Cue List", isPresented: Binding(
                get: { renamingList != nil },
                set: { if !$0 { renamingList = nil } }
            )) {
                TextField("Name", text: $renameText)
                Button("Cancel", role: .cancel) { renamingList = nil }
                Button("Save") {
                    if var list = renamingList {
                        list.name = renameText
                        KeyStorage.shared.updateCueList(list)
                        reloadLists()
                    }
                    renamingList = nil
                }
            }
        }
        .onAppear { reloadLists() }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "list.number")
                .font(.system(size: 50))
                .foregroundColor(.secondary)
            Text("No Cue Lists")
                .font(.title3)
                .fontWeight(.semibold)
            Text("Create a cue list to sequence lighting changes across multiple lights.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("Create Cue List") {
                addCueList()
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 12)
            .background(Color.accentColor)
            .foregroundColor(.white)
            .cornerRadius(10)
            Spacer()
        }
    }

    // MARK: - List Content

    private var listContent: some View {
        List {
            ForEach(cueLists) { list in
                NavigationLink(destination: CueListDetailView(cueList: list, onUpdate: reloadLists)) {
                    CueListRow(cueList: list)
                }
                .contextMenu {
                    Button {
                        renameText = list.name
                        renamingList = list
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        KeyStorage.shared.removeCueList(list)
                        reloadLists()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        KeyStorage.shared.removeCueList(list)
                        reloadLists()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func addCueList() {
        let list = CueList()
        KeyStorage.shared.addCueList(list)
        reloadLists()
    }

    private func reloadLists() {
        cueLists = KeyStorage.shared.cueLists
    }
}

// MARK: - Cue List Row

private struct CueListRow: View {
    let cueList: CueList

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(cueList.name)
                .font(.body)
                .fontWeight(.medium)
            Text("\(cueList.cues.count) cue\(cueList.cues.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

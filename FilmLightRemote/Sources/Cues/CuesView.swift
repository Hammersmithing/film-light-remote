import SwiftUI

/// Top-level cue lists view — lists all cue lists with add/rename/delete.
struct CuesView: View {
    @EnvironmentObject var bleManager: BLEManager
    @State private var cueLists: [CueList] = []
    @State private var timelines: [Timeline] = []
    @State private var renamingList: CueList?
    @State private var renameText = ""
    @State private var renamingTimeline: Timeline?
    @State private var renameTimelineText = ""
    @State private var selectedTab = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $selectedTab) {
                    Text("Cue Lists").tag(0)
                    Text("Timelines").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                if selectedTab == 0 {
                    cueListsContent
                } else {
                    timelinesContent
                }
            }
            .navigationTitle("Cues")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        if selectedTab == 0 {
                            addCueList()
                        } else {
                            addTimeline()
                        }
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
            .alert("Rename Timeline", isPresented: Binding(
                get: { renamingTimeline != nil },
                set: { if !$0 { renamingTimeline = nil } }
            )) {
                TextField("Name", text: $renameTimelineText)
                Button("Cancel", role: .cancel) { renamingTimeline = nil }
                Button("Save") {
                    if var tl = renamingTimeline {
                        tl.name = renameTimelineText
                        KeyStorage.shared.updateTimeline(tl)
                        reloadTimelines()
                    }
                    renamingTimeline = nil
                }
            }
        }
        .onAppear {
            reloadLists()
            reloadTimelines()
        }
    }

    // MARK: - Cue Lists Content

    private var cueListsContent: some View {
        Group {
            if cueLists.isEmpty {
                emptyState
            } else {
                listContent
            }
        }
    }

    // MARK: - Timelines Content

    private var timelinesContent: some View {
        Group {
            if timelines.isEmpty {
                timelinesEmptyState
            } else {
                timelinesListContent
            }
        }
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

    private var timelinesEmptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "timeline.selection")
                .font(.system(size: 50))
                .foregroundColor(.secondary)
            Text("No Timelines")
                .font(.title3)
                .fontWeight(.semibold)
            Text("Create a timeline to place light cues on a visual time axis.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("Create Timeline") {
                addTimeline()
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

    private var timelinesListContent: some View {
        List {
            ForEach(timelines) { tl in
                NavigationLink(destination: TimelineView(timeline: tl, onUpdate: reloadTimelines)) {
                    TimelineRow(timeline: tl)
                }
                .contextMenu {
                    Button {
                        renameTimelineText = tl.name
                        renamingTimeline = tl
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        KeyStorage.shared.removeTimeline(tl)
                        reloadTimelines()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        KeyStorage.shared.removeTimeline(tl)
                        reloadTimelines()
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

    private func addTimeline() {
        let tl = Timeline()
        KeyStorage.shared.addTimeline(tl)
        reloadTimelines()
    }

    private func reloadLists() {
        cueLists = KeyStorage.shared.cueLists
    }

    private func reloadTimelines() {
        timelines = KeyStorage.shared.timelines
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

// MARK: - Timeline Row

private struct TimelineRow: View {
    let timeline: Timeline

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(timeline.name)
                .font(.body)
                .fontWeight(.medium)
            HStack(spacing: 8) {
                Text("\(timeline.tracks.count) track\(timeline.tracks.count == 1 ? "" : "s")")
                Text("\(Int(timeline.totalDuration))s")
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

import SwiftUI

struct DebugLogView: View {
    @EnvironmentObject var bleManager: BLEManager
    @Environment(\.dismiss) var dismiss
    @State private var scrollToBottom = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Debug mode toggle
                Toggle("Debug Mode (Show All Devices)", isOn: $bleManager.debugMode)
                    .padding()
                    .background(Color(.systemGray6))

                // Log view
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(bleManager.debugLog.enumerated()), id: \.offset) { index, entry in
                                Text(entry)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(logColor(for: entry))
                                    .textSelection(.enabled)
                                    .id(index)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                    .background(Color.black)
                    .onChange(of: bleManager.debugLog.count) { _ in
                        if scrollToBottom {
                            withAnimation {
                                proxy.scrollTo(bleManager.debugLog.count - 1, anchor: .bottom)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Debug Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(content: toolbarContent)
        }
    }

    @ToolbarContentBuilder
    private func toolbarContent() -> some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button("Close") {
                dismiss()
            }
        }

        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Button {
                    scrollToBottom.toggle()
                } label: {
                    Label(scrollToBottom ? "Disable Auto-scroll" : "Enable Auto-scroll",
                          systemImage: scrollToBottom ? "arrow.down.circle.fill" : "arrow.down.circle")
                }

                Button {
                    copyLogToClipboard()
                } label: {
                    Label("Copy Log", systemImage: "doc.on.doc")
                }

                Button(role: .destructive) {
                    bleManager.debugLog.removeAll()
                } label: {
                    Label("Clear Log", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private func logColor(for entry: String) -> Color {
        if entry.contains("Error") || entry.contains("error") || entry.contains("Failed") {
            return .red
        } else if entry.contains("Sending") || entry.contains("Write") {
            return .cyan
        } else if entry.contains("Received") {
            return .green
        } else if entry.contains("Connected") {
            return .green
        } else if entry.contains("Disconnected") {
            return .orange
        } else if entry.contains("Service") || entry.contains("Char") {
            return .yellow
        }
        return .white
    }

    private func copyLogToClipboard() {
        let logText = bleManager.debugLog.joined(separator: "\n")
        UIPasteboard.general.string = logText
    }
}

#Preview {
    DebugLogView()
        .environmentObject(BLEManager())
}

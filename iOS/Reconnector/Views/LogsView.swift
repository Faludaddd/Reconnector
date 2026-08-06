import SwiftUI

struct LogsView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""
    @State private var selectedLevel = "ALL"
    @State private var multiSelectMode = false
    @State private var selectedEntries: Set<UUID> = []
    
    var filteredLogs: [LogEntry] {
        var result = appState.logs
        if selectedLevel != "ALL" {
            result = result.filter { $0.text.uppercased().contains("[\(selectedLevel)]") }
        }
        if !searchText.isEmpty {
            result = result.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
        }
        return result
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Filter bar
                HStack {
                    Picker("Level", selection: $selectedLevel) {
                        Text("All").tag("ALL")
                        Text("INFO").tag("INFO")
                        Text("WARNING").tag("WARNING")
                        Text("ERROR").tag("ERROR")
                    }.pickerStyle(.segmented).frame(width: 250)
                    Spacer()
                    Button { 
                        appState.logs.removeAll()
                        appState.clearLogsServer()
                    } label: { Image(systemName: "trash") }.disabled(appState.logs.isEmpty)
                    Button { UIPasteboard.general.string = appState.logs.map { $0.text }.joined(separator: "\n") } label: { Image(systemName: "doc.on.doc") }.disabled(appState.logs.isEmpty)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                
                if filteredLogs.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "doc.text.magnifyingglass").font(.system(size: 40)).foregroundColor(.secondary)
                        Text(appState.logs.isEmpty ? "No logs yet" : "No matching logs").font(.headline)
                        if appState.logs.isEmpty { Text("Logs will appear here in real-time.").font(.subheadline).foregroundColor(.secondary) }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(filteredLogs) { entry in
                                    LogRow(entry: entry, multiSelect: multiSelectMode, isSelected: selectedEntries.contains(entry.id)) {
                                        if multiSelectMode {
                                            if selectedEntries.contains(entry.id) { selectedEntries.remove(entry.id) }
                                            else { selectedEntries.insert(entry.id) }
                                        } else {
                                            UIPasteboard.general.string = entry.text
                                        }
                                    }
                                    .id(entry.id)
                                }
                            }.padding(.vertical, 8)
                        }
                        .onChange(of: appState.logs.count) { _ in
                            if appState.autoScrollLogs { if let last = filteredLogs.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } } }
                        }
                    }
                }
            }
            .navigationTitle("Logs")
            .searchable(text: $searchText, prompt: "Search logs")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(multiSelectMode ? "Done" : "Select") { multiSelectMode.toggle(); if !multiSelectMode { selectedEntries.removeAll() } }
                }
            }
        }.navigationViewStyle(.stack)
    }
}

struct LogRow: View {
    let entry: LogEntry
    let multiSelect: Bool
    let isSelected: Bool
    let onTap: () -> Void
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if multiSelect {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle").foregroundColor(isSelected ? .blue : .gray)
            }
            Text(timeString(entry.timestamp)).font(.system(.caption2, design: .monospaced)).foregroundColor(.secondary)
            Text(entry.text).font(.system(.caption, design: .monospaced)).foregroundColor(colorForLog(entry.text)).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16).padding(.vertical, 2)
        .background(isSelected ? Color.blue.opacity(0.1) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
    
    private func timeString(_ date: Date) -> String { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: date) }
    private func colorForLog(_ log: String) -> Color {
        let l = log.lowercased()
        if l.contains("[error]") || l.contains("crash") || l.contains("failed") { return .red }
        if l.contains("[warning]") { return .yellow }
        if l.contains("[success]") || l.contains("successful") { return .green }
        if l.contains("[startup]") { return .blue }
        return .primary
    }
}

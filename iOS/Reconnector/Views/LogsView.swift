import SwiftUI

struct LogsView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if appState.logs.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("No logs yet")
                            .font(.headline)
                        Text("Logs will appear here in real-time once connected.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                ForEach(appState.logs) { entry in
                                    HStack(alignment: .top, spacing: 8) {
                                        Text(timeString(entry.timestamp))
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundColor(.secondary)
                                        
                                        Text(entry.text)
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundColor(colorForLog(entry.text))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 2)
                                    .id(entry.id)
                                }
                            }
                            .padding(.vertical, 8)
                        }
                        .onChange(of: appState.logs.count) { _ in
                            if let last = appState.logs.last {
                                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Logs")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { appState.logs.removeAll() }) {
                        Image(systemName: "trash")
                    }
                    .disabled(appState.logs.isEmpty)
                }
            }
        }
        .navigationViewStyle(.stack)
    }
    
    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
    
    private func colorForLog(_ log: String) -> Color {
        let lower = log.lowercased()
        if lower.contains("[error]") || lower.contains("crash") || lower.contains("failed") { return .red }
        if lower.contains("[warning]") { return .yellow }
        if lower.contains("[success]") || lower.contains("successful") { return .green }
        if lower.contains("[startup]") { return .blue }
        return .primary
    }
}

import SwiftUI

struct LogsView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        NavigationView {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(appState.logs) { entry in
                            Text(entry.text)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(colorForLog(entry.text))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(entry.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: appState.logs.count) { _ in
                    if let last = appState.logs.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            .navigationTitle("Logs")
            .toolbar {
                Button(action: { appState.logs.removeAll() }) {
                    Image(systemName: "trash")
                }
            }
        }
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

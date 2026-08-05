import SwiftUI

struct LogsView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(appState.logs.indices, id: \.self) { index in
                        Text(appState.logs[index])
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(colorForLog(appState.logs[index]))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
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
        if log.contains("[ERROR]") || log.contains("CRASH") { return .red }
        if log.contains("[WARNING]") { return .yellow }
        if log.contains("[SUCCESS]") { return .green }
        return .primary
    }
}

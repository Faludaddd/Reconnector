import SwiftUI

struct MonitoringView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Crash History
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("Crash History").font(.headline)
                            Spacer()
                            Button("Refresh") { Task { await appState.fetchCrashes() } }
                        }
                        if appState.crashes.isEmpty {
                            Text("No crashes recorded").foregroundColor(.secondary).font(.subheadline)
                        } else {
                            ForEach(appState.crashes.prefix(10)) { crash in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(crash.reason).font(.subheadline).fontWeight(.medium)
                                    Text(Date(timeIntervalSince1970: TimeInterval(crash.timestamp)), style: .relative).font(.caption).foregroundColor(.secondary)
                                }
                                Divider()
                            }
                        }
                    }
                    .padding(20)
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(20)
                    
                    // Session Stats
                    if let status = appState.status {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Session Stats").font(.headline)
                            Divider()
                            InfoRow(label: "Total Crashes", value: "\(status.crashes_today)", color: .red)
                            InfoRow(label: "Total Kicks", value: "\(status.kicks_today)", color: .yellow)
                            InfoRow(label: "Network Drops", value: "\(status.network_drops ?? 0)", color: .orange)
                            InfoRow(label: "Bot Uptime", value: formatUptime(status.bot_uptime ?? 0), color: .blue)
                        }
                        .padding(20)
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(20)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .navigationTitle("Monitor")
            .toolbar { Button { Task { await appState.fetchCrashes() } } label: { Image(systemName: "arrow.clockwise") } }
            .task { await appState.fetchCrashes() }
        }
        .navigationViewStyle(.stack)
    }
    
    private func formatUptime(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        return "\(h)h \(m)m"
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    let color: Color
    
    var body: some View {
        HStack { Text(label).foregroundColor(.secondary); Spacer(); Text(value).foregroundColor(color).fontWeight(.medium) }
    }
}

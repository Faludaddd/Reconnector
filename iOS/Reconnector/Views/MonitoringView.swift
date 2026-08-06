import SwiftUI

struct MonitoringView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: AppTheme.sectionSpacing) {
                    // Crash History
                    AppCard(title: "Crash History", icon: "exclamationmark.bubble") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Recent events")
                                    .font(AppTheme.captionFont)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Button {
                                    appState.fetchCrashes()
                                } label: {
                                    Label("Refresh", systemImage: "arrow.clockwise")
                                        .font(AppTheme.captionFont)
                                }
                                .tint(.accentColor)
                            }

                            if appState.crashes.isEmpty {
                                Text("No crashes recorded")
                                    .foregroundColor(.secondary)
                                    .font(AppTheme.bodyFont)
                                    .padding(.vertical, 8)
                            } else {
                                ForEach(appState.crashes.prefix(10)) { crash in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(crash.reason)
                                            .font(AppTheme.bodyFont)
                                            .fontWeight(.medium)
                                        Text(Date(timeIntervalSince1970: TimeInterval(crash.timestamp)), style: .relative)
                                            .font(AppTheme.captionFont)
                                            .foregroundColor(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    Divider()
                                }
                            }
                        }
                    }

                    // Session Stats
                    if let status = appState.status {
                        AppCard(title: "Session Stats", icon: "chart.bar.fill") {
                            VStack(spacing: 10) {
                                AppInfoRow("Total Crashes", "\(status.crashes_today)", color: .red)
                                AppInfoRow("Total Kicks", "\(status.kicks_today)", color: .yellow)
                                AppInfoRow("Network Drops", "\(status.network_drops ?? 0)", color: .orange)
                                AppInfoRow("Bot Uptime", formatUptime(status.bot_uptime ?? 0), color: .blue)
                            }
                        }
                    }
                }
                .padding(.horizontal, AppTheme.horizontalInset)
                .padding(.top, 6)
                .padding(.bottom, 40)
            }
            .navigationTitle("Monitor")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { appState.fetchCrashes() } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            .task { appState.fetchCrashes() }
        }
        .navigationViewStyle(.stack)
    }

    private func formatUptime(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        return "\(h)h \(m)m"
    }
}

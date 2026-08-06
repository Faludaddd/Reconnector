import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: AppTheme.sectionSpacing) {
                    if let status = appState.status {
                        // Status hero card
                        AppCard {
                            VStack(spacing: 14) {
                                Image(systemName: statusIcon(for: status.roblox_state))
                                    .font(.system(size: 44))
                                    .foregroundColor(statusColor(for: status.roblox_state))
                                Text(status.roblox_state.capitalized)
                                    .font(.title2)
                                    .fontWeight(.bold)
                                Text(status.roblox_running ? "Roblox is running" : "Roblox is not running")
                                    .font(AppTheme.bodyFont)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                        }

                        // Stats grid
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14),
                                            GridItem(.flexible(), spacing: 14)], spacing: 14) {
                            StatCard(title: "Battery",
                                     value: "\(status.battery)%",
                                     icon: "battery.100",
                                     color: .green)
                            StatCard(title: "CPU Temp",
                                     value: status.cpu_temp != nil ? String(format: "%.1f°C", status.cpu_temp!) : "N/A",
                                     icon: "thermometer",
                                     color: .orange)
                            StatCard(title: "Crashes",
                                     value: "\(status.crashes_today)",
                                     icon: "exclamationmark.triangle",
                                     color: .red)
                            StatCard(title: "Kicks",
                                     value: "\(status.kicks_today)",
                                     icon: "hand.raised",
                                     color: .yellow)
                        }

                        // System information
                        AppCard(title: "System Information", icon: "info.circle.fill") {
                            VStack(spacing: 10) {
                                AppInfoRow("Watchdog", status.watchdog_enabled ? "Active" : "Off",
                                            color: status.watchdog_enabled ? .green : .red)
                                AppInfoRow("Interval", "\(status.interval) min", color: .blue)
                                AppInfoRow("Internet", status.internet == true ? "Online" : "Offline",
                                            color: status.internet == true ? .green : .red)
                                if let ram = status.ram_total, let free = status.ram_free {
                                    AppInfoRow("RAM", "\(ram - free)MB / \(ram)MB", color: .purple)
                                }
                                if let uptime = status.uptime {
                                    AppInfoRow("Device Uptime",
                                               "\(uptime / 3600)h \((uptime % 3600) / 60)m",
                                               color: .secondary)
                                }
                                if let lastCrash = status.last_crash_reason, lastCrash != "-" {
                                    Divider()
                                    AppInfoRow("Last Crash", lastCrash, color: .red)
                                }
                            }
                        }
                    } else {
                        // Connecting / error state
                        AppCard {
                            VStack(spacing: 16) {
                                if appState.isConnecting {
                                    ProgressView().scaleEffect(1.3)
                                } else {
                                    Image(systemName: "wifi.exclamationmark")
                                        .font(.system(size: 40))
                                        .foregroundColor(.secondary)
                                }
                                Text(appState.connectionError ?? "Connecting to backend...")
                                    .font(AppTheme.bodyFont)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                                if appState.connectionError != nil {
                                    Button("Retry Connection") { appState.reconnect() }
                                        .buttonStyle(.bordered)
                                        .tint(.accentColor)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                        }
                    }
                    Text("Reconnector v1.1.0")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, AppTheme.horizontalInset)
                .padding(.top, 6)
                .padding(.bottom, 40)
            }
            .navigationTitle("Dashboard")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { appState.reconnect() } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            .refreshable { await appState.fetchStatus() }
        }
        .navigationViewStyle(.stack)
    }

    private func statusColor(for state: String) -> Color {
        switch state {
        case "healthy": return .green
        case "loading": return .yellow
        case "reconnecting", "offline": return .red
        default: return .gray
        }
    }

    private func statusIcon(for state: String) -> String {
        switch state {
        case "healthy": return "checkmark.circle.fill"
        case "loading": return "arrow.clockwise.circle.fill"
        case "reconnecting": return "arrow.triangle.2.circlepath.circle.fill"
        case "offline": return "xmark.circle.fill"
        default: return "questionmark.circle.fill"
        }
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title)
                .foregroundColor(color)
            Text(value)
                .font(.title3)
                .fontWeight(.bold)
            Text(title)
                .font(AppTheme.captionFont)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 96)
        .padding(14)
        .background(AppTheme.cardBackground)
        .cornerRadius(AppTheme.cornerRadius)
    }
}

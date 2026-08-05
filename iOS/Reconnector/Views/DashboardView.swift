import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: appState.compactMode ? 12 : 20) {
                    if let status = appState.status {
                        // Status Card
                        VStack(spacing: appState.compactMode ? 8 : 16) {
                            Image(systemName: statusIcon(for: status.roblox_state))
                                .font(.system(size: appState.compactMode ? 36 : 48))
                                .foregroundColor(statusColor(for: status.roblox_state))
                            Text(status.roblox_state.capitalized).font(.title2).fontWeight(.bold)
                            Text(status.roblox_running ? "Roblox is running" : "Roblox is not running").font(.subheadline).foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, appState.compactMode ? 16 : 32)
                        .padding(.horizontal, 24)
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(20)
                        
                        // Stats Grid
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 16) {
                            StatCard(title: "Battery", value: "\(status.battery)%", icon: "battery.100", color: .green)
                            StatCard(title: "CPU Temp", value: status.cpu_temp != nil ? String(format: "%.1f°C", status.cpu_temp!) : "N/A", icon: "thermometer", color: .orange)
                            StatCard(title: "Crashes", value: "\(status.crashes_today)", icon: "exclamationmark.triangle", color: .red)
                            StatCard(title: "Kicks", value: "\(status.kicks_today)", icon: "hand.raised", color: .yellow)
                        }
                        
                        // System Info
                        VStack(alignment: .leading, spacing: 16) {
                            Text("System Information").font(.headline)
                            Divider()
                            InfoRow(label: "Watchdog", value: status.watchdog_enabled ? "Active" : "Off", color: status.watchdog_enabled ? .green : .red)
                            InfoRow(label: "Interval", value: "\(status.interval) min", color: .blue)
                            InfoRow(label: "Brightness", value: "\(status.brightness)%", color: .yellow)
                            InfoRow(label: "Internet", value: status.internet == true ? "Online" : "Offline", color: status.internet == true ? .green : .red)
                            if let ram = status.ram_total, let free = status.ram_free {
                                InfoRow(label: "RAM", value: "\(ram - free)MB / \(ram)MB", color: .purple)
                            }
                            if let uptime = status.uptime {
                                InfoRow(label: "Device Uptime", value: "\(uptime / 3600)h \((uptime % 3600) / 60)m", color: .secondary)
                            }
                            if let lastCrash = status.last_crash_reason, lastCrash != "-" {
                                Divider()
                                InfoRow(label: "Last Crash", value: lastCrash, color: .red)
                            }
                        }
                        .padding(20)
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(20)
                    } else {
                        VStack(spacing: 20) {
                            Spacer().frame(height: 60)
                            ProgressView().scaleEffect(1.5)
                            Text(appState.connectionError ?? "Connecting to backend...").font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.horizontal, 40)
                            if let _ = appState.connectionError {
                                Button("Retry Connection") { appState.connectWebSocket() }.buttonStyle(.bordered).padding(.top, 8)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    Text("Reconnector v1.0.4").font(.caption2).foregroundColor(.secondary).padding(.top, 8)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .navigationTitle("Dashboard")
            .refreshable { await appState.fetchStatus() }
        }
        .navigationViewStyle(.stack)
        .task { await appState.fetchStatus() }
    }
    
    private func statusColor(for state: String) -> Color {
        switch state { case "healthy": return .green; case "loading": return .yellow; case "reconnecting", "offline": return .red; default: return .gray }
    }
    private func statusIcon(for state: String) -> String {
        switch state { case "healthy": return "checkmark.circle.fill"; case "loading": return "arrow.clockwise.circle.fill"; case "reconnecting": return "arrow.triangle.2.circlepath.circle.fill"; case "offline": return "xmark.circle.fill"; default: return "questionmark.circle.fill" }
    }
}

struct StatCard: View {
    let title: String; let value: String; let icon: String; let color: Color
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.title).foregroundColor(color)
            Text(value).font(.title3).fontWeight(.bold)
            Text(title).font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 100).padding(16)
        .background(Color(UIColor.secondarySystemBackground)).cornerRadius(16)
    }
}

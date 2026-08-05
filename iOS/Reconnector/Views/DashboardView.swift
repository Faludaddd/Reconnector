import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    if let status = appState.status {
                        // Status Card
                        VStack(spacing: 12) {
                            Image(systemName: statusIcon(for: status.roblox_state))
                                .font(.system(size: 40))
                                .foregroundColor(statusColor(for: status.roblox_state))
                            
                            Text(status.roblox_state.capitalized)
                                .font(.title2)
                                .fontWeight(.bold)
                            
                            Text(status.roblox_running ? "Roblox Running" : "Roblox Not Running")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(16)
                        
                        // Stats Grid
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                            StatCard(title: "Battery", value: "\(status.battery)%", icon: "battery.100", color: .green)
                            StatCard(title: "CPU Temp", value: status.cpu_temp != nil ? String(format: "%.1f°C", status.cpu_temp!) : "N/A", icon: "thermometer", color: .orange)
                            StatCard(title: "Crashes", value: "\(status.crashes_today)", icon: "exclamationmark.triangle", color: .red)
                            StatCard(title: "Kicks", value: "\(status.kicks_today)", icon: "hand.raised", color: .yellow)
                        }
                        
                        // System Info
                        VStack(alignment: .leading, spacing: 12) {
                            InfoRow(label: "Watchdog", value: status.watchdog_enabled ? "Active" : "Off", color: status.watchdog_enabled ? .green : .red)
                            InfoRow(label: "Interval", value: "\(status.interval) min", color: .blue)
                            InfoRow(label: "Brightness", value: "\(status.brightness)%", color: .yellow)
                            if let lastCrash = status.last_crash_reason, lastCrash != "-" {
                                InfoRow(label: "Last Crash", value: lastCrash, color: .red)
                            }
                        }
                        .padding()
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(16)
                    } else {
                        VStack(spacing: 16) {
                            ProgressView()
                            Text("Connecting to bot...")
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, 100)
                    }
                }
                .padding()
            }
            .navigationTitle("Dashboard")
            .refreshable { await appState.fetchStatus() }
        }
        .task { await appState.fetchStatus() }
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
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)
            Text(value)
                .font(.headline)
                .fontWeight(.bold)
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    let color: Color
    
    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .foregroundColor(color)
                .fontWeight(.medium)
        }
    }
}

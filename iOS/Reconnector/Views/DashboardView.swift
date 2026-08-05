import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    if let status = appState.status {
                        VStack(spacing: 8) {
                            Text(status.roblox_state.capitalized)
                                .font(.largeTitle)
                                .fontWeight(.bold)
                                .foregroundColor(statusColor(for: status.roblox_state))
                            Text(status.roblox_running ? "Running" : "Not Running")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(16)
                        
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                            StatCard(title: "Battery", value: "\(status.battery)%", icon: "battery.100")
                            StatCard(title: "CPU Temp", value: status.cpu_temp != nil ? String(format: "%.1f°C", status.cpu_temp!) : "N/A", icon: "thermometer")
                            StatCard(title: "Crashes", value: "\(status.crashes_today)", icon: "exclamationmark.triangle")
                            StatCard(title: "Kicks", value: "\(status.kicks_today)", icon: "hand.raised")
                        }
                        
                        VStack(alignment: .leading, spacing: 10) {
                            InfoRow(label: "Watchdog", value: status.watchdog_enabled ? "Active" : "Off")
                            InfoRow(label: "Interval", value: "\(status.interval) min")
                            InfoRow(label: "Brightness", value: "\(status.brightness)%")
                        }
                        .padding()
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(16)
                    } else {
                        ProgressView("Connecting to bot...")
                    }
                }
                .padding()
            }
            .navigationTitle("Dashboard")
            .refreshable { await fetchStatus() }
        }
        .task { await fetchStatus() }
    }
    
    private func fetchStatus() async {
        guard !appState.ipAddress.isEmpty else { return }
        let client = APIClient(ipAddress: appState.ipAddress, authToken: appState.authToken)
        do { appState.status = try await client.getStatus() } catch { print("Failed: \(error)") }
    }
    
    private func statusColor(for state: String) -> Color {
        switch state {
        case "healthy": return .green
        case "loading": return .yellow
        case "reconnecting", "offline": return .red
        default: return .gray
        }
    }
}

struct StatCard: View {
    let title: String; let value: String; let icon: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.title2).foregroundColor(.blue)
            Text(value).font(.headline)
            Text(title).font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity).padding()
        .background(Color(UIColor.secondarySystemBackground)).cornerRadius(12)
    }
}

struct InfoRow: View {
    let label: String; let value: String
    var body: some View {
        HStack { Text(label).foregroundColor(.secondary); Spacer(); Text(value).fontWeight(.medium) }
    }
}

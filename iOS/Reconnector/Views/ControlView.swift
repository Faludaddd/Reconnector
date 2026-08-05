import SwiftUI

struct ControlView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingRestartAlert = false
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    // Actions Section
                    VStack(spacing: 12) {
                        Button(role: .destructive) { showingRestartAlert = true } label: {
                            Label("Force Restart", systemImage: "arrow.clockwise.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        
                        Button { Task { try? await APIClient(ipAddress: appState.ipAddress, authToken: appState.authToken).activateBlackScreen() } } label: {
                            Label("Black Screen", systemImage: "moon.fill")
                        }
                        .buttonStyle(.bordered)
                        
                        Button { Task { try? await APIClient(ipAddress: appState.ipAddress, authToken: appState.authToken).clearAntiLoop() } } label: {
                            Label("Clear Anti-Loop", systemImage: "arrow.uturn.left.circle")
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity)
                    
                    // Brightness Section
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Brightness").font(.headline)
                        HStack {
                            ForEach([0, 50, 100], id: \.self) { level in
                                Button("\(level)%") {
                                    Task { try? await APIClient(ipAddress: appState.ipAddress, authToken: appState.authToken).setBrightness(level: level) }
                                }
                                .buttonStyle(.bordered)
                                .tint(appState.status?.brightness == level ? .blue : .gray)
                            }
                        }
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(16)
                    
                    // Optimizations
                    VStack(alignment: .leading, spacing: 15) {
                        Text("Optimizations").font(.headline)
                        if let opts = appState.status?.optimizations {
                            Toggle("Kill BG Apps", isOn: .constant(opts.kill_bg))
                            Toggle("Process Limit", isOn: .constant(opts.process_limit))
                            Toggle("No Animations", isOn: .constant(opts.no_animations))
                            Toggle("Force GPU", isOn: .constant(opts.force_gpu))
                            Toggle("No Bluetooth", isOn: .constant(opts.no_bluetooth))
                        }
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(16)
                }
                .padding()
            }
            .navigationTitle("Control")
            .alert("Force Restart?", isPresented: $showingRestartAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Restart", role: .destructive) {
                    Task { try? await APIClient(ipAddress: appState.ipAddress, authToken: appState.authToken).restart() }
                }
            }
        }
    }
}

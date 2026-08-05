import SwiftUI

struct ControlView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingRestartAlert = false
    @State private var showingScreenshot = false
    @State private var showingGameLinkEditor = false
    @State private var gameLinkInput = ""
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Actions Section
                    VStack(spacing: 12) {
                        Button(role: .destructive) { showingRestartAlert = true } label: {
                            Label("Force Restart", systemImage: "arrow.clockwise.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        
                        Button { Task { await appState.fetchScreenshot(); showingScreenshot = true } } label: {
                            Label("Screenshot", systemImage: "camera.fill")
                        }
                        .buttonStyle(.bordered)
                        
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
                    
                    // Watchdog Toggle
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Watchdog").font(.headline)
                        HStack {
                            Text(appState.status?.watchdog_enabled == true ? "Active" : "Off")
                                .foregroundColor(appState.status?.watchdog_enabled == true ? .green : .red)
                            Spacer()
                            Button("Toggle") {
                                Task { try? await APIClient(ipAddress: appState.ipAddress, authToken: appState.authToken).toggleWatchdog() }
                            }
                        }
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(16)
                    
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
                            ToggleRow(title: "Kill BG Apps", isOn: opts.kill_bg) {
                                Task { try? await APIClient(ipAddress: appState.ipAddress, authToken: appState.authToken).toggleOptimization(name: "kill_bg", enabled: !opts.kill_bg) }
                            }
                            ToggleRow(title: "Process Limit", isOn: opts.process_limit) {
                                Task { try? await APIClient(ipAddress: appState.ipAddress, authToken: appState.authToken).toggleOptimization(name: "process_limit", enabled: !opts.process_limit) }
                            }
                            ToggleRow(title: "No Animations", isOn: opts.no_animations) {
                                Task { try? await APIClient(ipAddress: appState.ipAddress, authToken: appState.authToken).toggleOptimization(name: "no_animations", enabled: !opts.no_animations) }
                            }
                            ToggleRow(title: "Force GPU", isOn: opts.force_gpu) {
                                Task { try? await APIClient(ipAddress: appState.ipAddress, authToken: appState.authToken).toggleOptimization(name: "force_gpu", enabled: !opts.force_gpu) }
                            }
                            ToggleRow(title: "No Bluetooth", isOn: opts.no_bluetooth) {
                                Task { try? await APIClient(ipAddress: appState.ipAddress, authToken: appState.authToken).toggleOptimization(name: "no_bluetooth", enabled: !opts.no_bluetooth) }
                            }
                        }
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(16)
                    
                    // Game Link
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Game Link").font(.headline)
                        Text(appState.status?.game_link ?? "Not set")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Button("Edit Game Link") {
                            gameLinkInput = appState.status?.game_link ?? ""
                            showingGameLinkEditor = true
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
            .sheet(isPresented: $showingScreenshot) {
                if let image = appState.screenshotImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            }
            .alert("Edit Game Link", isPresented: $showingGameLinkEditor) {
                TextField("Game Link", text: $gameLinkInput)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    Task { try? await APIClient(ipAddress: appState.ipAddress, authToken: appState.authToken).setGameLink(url: gameLinkInput) }
                }
            }
        }
    }
}

struct ToggleRow: View {
    let title: String
    let isOn: Bool
    let action: () -> Void
    
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isOn ? .green : .gray)
        }
        .contentShape(Rectangle())
        .onTapGesture { action() }
    }
}

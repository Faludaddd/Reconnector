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
                VStack(spacing: appState.compactMode ? 12 : 20) {
                    // Action Loading Overlay
                    if appState.isPerformingAction {
                        ActionLoadingCard(name: appState.actionName, progress: appState.actionProgress, remaining: appState.actionTimeRemaining)
                    }
                    
                    // Quick Actions
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Quick Actions").font(.headline)
                        VStack(spacing: 12) {
                            Button(role: .destructive) { showingRestartAlert = true } label: {
                                Label("Force Restart Roblox", systemImage: "arrow.clockwise.circle.fill").frame(maxWidth: .infinity)
                            }.buttonStyle(.borderedProminent).controlSize(.large).disabled(appState.isPerformingAction)
                            
                            Button { Task { await appState.fetchScreenshot(); showingScreenshot = true } } label: {
                                Label("Take Screenshot", systemImage: "camera.fill").frame(maxWidth: .infinity)
                            }.buttonStyle(.bordered).controlSize(.large).disabled(appState.isPerformingAction)
                            
                            Button { Task { try? await APIClient(ipAddress: appState.ipAddress, authToken: appState.authToken).clearAntiLoop() } } label: {
                                Label("Clear Anti-Loop", systemImage: "arrow.uturn.left.circle").frame(maxWidth: .infinity)
                            }.buttonStyle(.bordered).controlSize(.large)
                        }
                    }.padding(20).background(Color(UIColor.secondarySystemBackground)).cornerRadius(20)
                    
                    // Watchdog
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Watchdog").font(.headline)
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Status")
                                Text(appState.status?.watchdog_enabled == true ? "Active" : "Disabled").foregroundColor(appState.status?.watchdog_enabled == true ? .green : .red).fontWeight(.medium)
                            }
                            Spacer()
                            Button("Toggle") { Task { try? await APIClient(ipAddress: appState.ipAddress, authToken: appState.authToken).toggleWatchdog() } }.buttonStyle(.borderedProminent)
                        }
                    }.padding(20).background(Color(UIColor.secondarySystemBackground)).cornerRadius(20)
                    
                    // Optimizations
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Optimizations").font(.headline).foregroundColor(appState.accentColor)
                        if let opts = appState.status?.optimizations {
                            VStack(spacing: 12) {
                                OptimizationRow(title: "Kill Background Apps", isOn: opts.kill_bg, name: "kill_bg", appState: appState)
                                OptimizationRow(title: "Process Limit", isOn: opts.process_limit, name: "process_limit", appState: appState)
                                OptimizationRow(title: "No Animations", isOn: opts.no_animations, name: "no_animations", appState: appState)
                                OptimizationRow(title: "Force GPU Rendering", isOn: opts.force_gpu, name: "force_gpu", appState: appState)
                                OptimizationRow(title: "Disable Bluetooth", isOn: opts.no_bluetooth, name: "no_bluetooth", appState: appState)
                            }
                        }
                    }.padding(20).background(Color(UIColor.secondarySystemBackground)).cornerRadius(20)
                    
                    // Game Link
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Game Link").font(.headline)
                        Text(appState.status?.game_link ?? "Not set").font(.caption).foregroundColor(.secondary).lineLimit(2)
                        Button("Edit Game Link") { gameLinkInput = appState.status?.game_link ?? ""; showingGameLinkEditor = true }.buttonStyle(.bordered)
                    }.padding(20).background(Color(UIColor.secondarySystemBackground)).cornerRadius(20)
                }
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 40)
            }
            .navigationTitle("Control")
            .toolbar { Button { Task { await appState.fetchStatus() } } label: { Image(systemName: "arrow.clockwise") } }
            .alert("Force Restart?", isPresented: $showingRestartAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Restart", role: .destructive) { Task { await appState.restartRoblox() } }
            } message: { Text("This will force-stop Roblox and relaunch it.") }
            .sheet(isPresented: $showingScreenshot) {
                if let image = appState.screenshotImage { Image(uiImage: image).resizable().aspectRatio(contentMode: .fit).padding() }
                else { ProgressView("Loading...") }
            }
            .alert("Edit Game Link", isPresented: $showingGameLinkEditor) {
                TextField("Game Link", text: $gameLinkInput)
                Button("Cancel", role: .cancel) {}
                Button("Save") { Task { try? await APIClient(ipAddress: appState.ipAddress, authToken: appState.authToken).setGameLink(url: gameLinkInput) } }
            }
        }.navigationViewStyle(.stack)
    }
}

struct ActionLoadingCard: View {
    let name: String
    let progress: Double
    let remaining: Int
    
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                ProgressView(value: progress).progressViewStyle(.circular)
                VStack(alignment: .leading) {
                    Text(name).font(.subheadline).fontWeight(.medium)
                    Text("~\(remaining)s remaining").font(.caption).foregroundColor(.secondary)
                }
                Spacer()
            }
        }
        .padding(16)
        .background(Color(UIColor.tertiarySystemBackground))
        .cornerRadius(12)
    }
}

struct OptimizationRow: View {
    let title: String; let isOn: Bool; let name: String; let appState: AppState
    var body: some View {
        HStack {
            Text(title).font(.subheadline)
            Spacer()
            Toggle("", isOn: Binding(get: { isOn }, set: { newValue in Task { try? await APIClient(ipAddress: appState.ipAddress, authToken: appState.authToken).toggleOptimization(name: name, enabled: newValue) } })).labelsHidden()
        }
    }
}

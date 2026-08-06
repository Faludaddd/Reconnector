import SwiftUI

struct ControlView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingRestartAlert = false
    @State private var showingScreenshot = false
    @State private var showingVideo = false
    @State private var showingGameLinkEditor = false
    @State private var gameLinkInput = ""
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Quick Actions
                    ActionCard(title: "Quick Actions") {
                        VStack(spacing: 12) {
                            Button(role: .destructive) { showingRestartAlert = true } label: {
                                Label("Force Restart Roblox", systemImage: "arrow.clockwise.circle.fill").frame(maxWidth: .infinity)
                            }.buttonStyle(.borderedProminent).controlSize(.large).disabled(appState.isPerformingAction)
                            
                            Button { Task { await appState.fetchScreenshot(); showingScreenshot = true } } label: {
                                Label("Take Screenshot", systemImage: "camera.fill").frame(maxWidth: .infinity)
                            }.buttonStyle(.bordered).controlSize(.large).disabled(appState.isPerformingAction)
                            
                            Button { Task { await appState.fetchVideo(); showingVideo = true } } label: {
                                Label("3s Proving Video", systemImage: "video.fill").frame(maxWidth: .infinity)
                            }.buttonStyle(.bordered).controlSize(.large).disabled(appState.isPerformingAction)
                            
                            Button { Task { try? await APIClient(ipAddress: appState.ipAddress, authToken: appState.authToken).clearAntiLoop() } } label: {
                                Label("Clear Anti-Loop", systemImage: "arrow.uturn.left.circle").frame(maxWidth: .infinity)
                            }.buttonStyle(.bordered).controlSize(.large)
                        }
                    }
                    
                    // Watchdog
                    ActionCard(title: "Watchdog") {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Status")
                                Text(appState.watchdogEnabled ? "Active" : "Disabled").foregroundColor(appState.watchdogEnabled ? .green : .red).fontWeight(.medium)
                            }
                            Spacer()
                            Button(appState.watchdogEnabled ? "Disable" : "Enable") { appState.toggleWatchdog() }
                                .buttonStyle(.borderedProminent)
                                .tint(appState.watchdogEnabled ? .red : .green)
                        }
                    }
                    
                    // Optimizations
                    ActionCard(title: "Optimizations") {
                        VStack(spacing: 12) {
                            OptToggle(title: "Kill Background Apps", isOn: appState.optKillBg) { appState.toggleOptimization(name: "kill_bg", current: appState.optKillBg) }
                            OptToggle(title: "Process Limit", isOn: appState.optProcessLimit) { appState.toggleOptimization(name: "process_limit", current: appState.optProcessLimit) }
                            OptToggle(title: "No Animations", isOn: appState.optNoAnimations) { appState.toggleOptimization(name: "no_animations", current: appState.optNoAnimations) }
                            OptToggle(title: "Force GPU Rendering", isOn: appState.optForceGpu) { appState.toggleOptimization(name: "force_gpu", current: appState.optForceGpu) }
                            OptToggle(title: "Disable Bluetooth", isOn: appState.optNoBluetooth) { appState.toggleOptimization(name: "no_bluetooth", current: appState.optNoBluetooth) }
                        }
                    }
                    
                    // Game Link
                    ActionCard(title: "Game Link") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(appState.status?.game_link ?? "Not set").font(.caption).foregroundColor(.secondary).lineLimit(2)
                            Button("Edit Game Link") { gameLinkInput = appState.status?.game_link ?? ""; showingGameLinkEditor = true }.buttonStyle(.bordered)
                        }
                    }
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
            .sheet(isPresented: $showingVideo) {
                if let videoData = appState.videoData {
                    VideoPlayerView(videoData: videoData)
                } else { ProgressView("Loading...") }
            }
            .alert("Edit Game Link", isPresented: $showingGameLinkEditor) {
                TextField("Game Link", text: $gameLinkInput)
                Button("Cancel", role: .cancel) {}
                Button("Save") { Task { try? await APIClient(ipAddress: appState.ipAddress, authToken: appState.authToken).setGameLink(url: gameLinkInput) } }
            }
        }.navigationViewStyle(.stack)
    }
}

struct ActionCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            content
        }
        .padding(20)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(20)
    }
}

struct OptToggle: View {
    let title: String
    let isOn: Bool
    let action: () -> Void
    
    var body: some View {
        HStack {
            Text(title).font(.subheadline)
            Spacer()
            Toggle("", isOn: Binding(get: { isOn }, set: { _ in action() })).labelsHidden()
        }
    }
}

import AVKit
import AVFoundation

struct VideoPlayerView: UIViewControllerRepresentable {
    let videoData: Data
    
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("proving.mp4")
        try? videoData.write(to: tempURL)
        let player = AVPlayer(url: tempURL)
        let controller = AVPlayerViewController()
        controller.player = player
        return controller
    }
    
    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}
}

import SwiftUI
import AVKit
import AVFoundation

struct ControlView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingRestartAlert = false
    @State private var showingScreenshot = false
    @State private var showingVideo = false
    @State private var showingGameLinkEditor = false
    @State private var gameLinkInput = ""
    @State private var showingIntervalPicker = false
    @State private var tempInterval = 1

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: AppTheme.sectionSpacing) {
                    // MARK: - Quick Actions
                    AppCard(title: "Quick Actions", icon: "bolt.fill") {
                        VStack(spacing: 10) {
                            AppActionButton("Force Restart Roblox",
                                            icon: "arrow.clockwise.circle.fill",
                                            style: .destructive,
                                            disabled: appState.isPerformingAction) {
                                showingRestartAlert = true
                            }
                            AppActionButton("Take Screenshot",
                                            icon: "camera.fill",
                                            disabled: appState.isPerformingAction) {
                                appState.fetchScreenshot()
                                showingScreenshot = true
                            }
                            AppActionButton("3s Proving Video",
                                            icon: "video.fill",
                                            disabled: appState.isPerformingAction) {
                                appState.fetchVideo()
                                showingVideo = true
                            }
                            AppActionButton("Clear Anti-Loop",
                                            icon: "arrow.uturn.left.circle",
                                            disabled: appState.isPerformingAction) {
                                appState.clearAntiLoop()
                            }
                        }
                    }

                    // MARK: - Watchdog
                    AppCard(title: "Watchdog", icon: "shield.lefthalf.filled") {
                        VStack(spacing: 10) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Status")
                                        .font(AppTheme.captionFont)
                                        .foregroundColor(.secondary)
                                    Text(appState.watchdogEnabled ? "Active" : "Disabled")
                                        .foregroundColor(appState.watchdogEnabled ? .green : .red)
                                        .fontWeight(.medium)
                                }
                                Spacer()
                                Button(appState.watchdogEnabled ? "Disable" : "Enable") {
                                    appState.toggleWatchdog()
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(appState.watchdogEnabled ? .red : .green)
                            }
                            Divider()
                            HStack {
                                Text("Check Interval")
                                    .font(AppTheme.bodyFont)
                                Spacer()
                                Button {
                                    tempInterval = appState.watchdogInterval
                                    showingIntervalPicker = true
                                } label: {
                                    Text("\(appState.watchdogInterval) min")
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                    }

                    // MARK: - Optimizations
                    AppCard(title: "Optimizations", icon: "wand.and.stars") {
                        VStack(spacing: 4) {
                            AppToggleRow(title: "Kill Background Apps", icon: "xmark.app",
                                         isOn: appState.optKillBg) {
                                appState.toggleOptimization(name: "kill_bg")
                            }
                            AppToggleRow(title: "Process Limit", icon: "gauge",
                                         isOn: appState.optProcessLimit) {
                                appState.toggleOptimization(name: "process_limit")
                            }
                            AppToggleRow(title: "No Animations", icon: "rectangle.dashed",
                                         isOn: appState.optNoAnimations) {
                                appState.toggleOptimization(name: "no_animations")
                            }
                            AppToggleRow(title: "Force GPU Rendering", icon: "cpu",
                                         isOn: appState.optForceGpu) {
                                appState.toggleOptimization(name: "force_gpu")
                            }
                            AppToggleRow(title: "Disable Bluetooth", icon: "antenna.radiowaves.left.and.right",
                                         isOn: appState.optNoBluetooth) {
                                appState.toggleOptimization(name: "no_bluetooth")
                            }
                        }
                    }

                    // MARK: - Game Link (matches the rest of the cards now)
                    AppCard(title: "Game Link", icon: "link.circle") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(appState.gameLink.isEmpty ? "Not set" : appState.gameLink)
                                .font(AppTheme.bodyFont)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            AppActionButton("Edit Game Link", icon: "pencil") {
                                gameLinkInput = appState.gameLink
                                showingGameLinkEditor = true
                            }
                        }
                    }
                }
                .padding(.horizontal, AppTheme.horizontalInset)
                .padding(.top, 6)
                .padding(.bottom, 40)
            }
            .navigationTitle("Control")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { appState.reconnect() } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            .alert("Force Restart?", isPresented: $showingRestartAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Restart", role: .destructive) { appState.restartRoblox() }
            } message: {
                Text("This will force-stop Roblox and relaunch it.")
            }
            .sheet(isPresented: $showingScreenshot) {
                if let image = appState.screenshotImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding()
                } else {
                    ProgressView("Loading...")
                }
            }
            .sheet(isPresented: $showingVideo) {
                if let videoData = appState.videoData {
                    VideoPlayerView(videoData: videoData)
                } else {
                    ProgressView("Loading...")
                }
            }
            .alert("Edit Game Link", isPresented: $showingGameLinkEditor) {
                TextField("Game Link", text: $gameLinkInput)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    let link = gameLinkInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !link.isEmpty else { return }
                    appState.setGameLink(link) { _ in }
                }
            }
            .sheet(isPresented: $showingIntervalPicker) {
                NavigationView {
                    Form {
                        Picker("Check Interval", selection: $tempInterval) {
                            Text("1 min").tag(1)
                            Text("5 min").tag(5)
                            Text("10 min").tag(10)
                            Text("15 min").tag(15)
                            Text("30 min").tag(30)
                        }
                        .pickerStyle(.inline)
                    }
                    .navigationTitle("Interval")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showingIntervalPicker = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") {
                                appState.setInterval(tempInterval)
                                showingIntervalPicker = false
                            }
                        }
                    }
                }
                .presentationDetents([.medium])
            }
        }
        .navigationViewStyle(.stack)
    }
}

struct VideoPlayerView: UIViewControllerRepresentable {
    let videoData: Data

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("proving_\(UUID().uuidString).mp4")
        do {
            try videoData.write(to: tempURL)
        } catch {
            print("[VideoPlayer] Failed to write temp file: \(error)")
        }
        let player = AVPlayer(url: tempURL)
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: AVPlayerViewController, coordinator: ()) {
        uiViewController.player?.pause()
    }
}

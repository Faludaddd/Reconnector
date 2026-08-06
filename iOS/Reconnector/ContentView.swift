import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ZStack {
            TabView {
                DashboardView()
                    .tabItem { Label("Dashboard", systemImage: "house.fill") }
                ControlView()
                    .tabItem { Label("Control", systemImage: "slider.horizontal.3") }
                MonitoringView()
                    .tabItem { Label("Monitor", systemImage: "chart.bar.fill") }
                LogsView()
                    .tabItem { Label("Logs", systemImage: "list.bullet.rectangle") }
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gear") }
            }
            .tint(.accentColor)
            .preferredColorScheme(.dark)

            if appState.isPerformingAction {
                ActionOverlayView()
                    .transition(.opacity)
                    .zIndex(1000)
            }

            // Toast for transient errors (failed toggles, etc.)
            if let error = appState.actionError, !appState.isPerformingAction {
                VStack {
                    Spacer()
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.yellow)
                        Text(error)
                            .font(.subheadline)
                            .foregroundColor(.white)
                        Spacer()
                    }
                    .padding(14)
                    .background(Color.red.opacity(0.92))
                    .cornerRadius(12)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 30)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(999)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: appState.isPerformingAction)
        .animation(.easeInOut(duration: 0.25), value: appState.actionError)
    }
}

struct ActionOverlayView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ZStack {
            Color.black.opacity(0.85)
                .ignoresSafeArea()
                .contentShape(Rectangle())

            VStack(spacing: 22) {
                if appState.actionError != nil {
                    Image(systemName: "xmark.octagon.fill")
                        .font(.system(size: 56))
                        .foregroundColor(.red)
                } else if appState.actionProgress >= 1.0 {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 56))
                        .foregroundColor(.green)
                } else {
                    ProgressView(value: appState.actionProgress)
                        .progressViewStyle(.circular)
                        .scaleEffect(1.6)
                        .tint(.white)
                }

                Text(appState.actionName)
                    .font(.headline)
                    .foregroundColor(.white)

                if appState.actionError == nil && appState.actionProgress < 1.0 {
                    Text("~\(appState.actionTimeRemaining)s remaining")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.75))
                        .monospacedDigit()
                }

                if appState.actionError != nil {
                    Text(appState.actionError ?? "")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.9))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
            }
            .padding(36)
            .background(Color(UIColor.systemBackground).opacity(0.95))
            .cornerRadius(22)
            .padding(.horizontal, 40)
        }
        // Block all interaction while active
        .allowsHitTesting(true)
    }
}

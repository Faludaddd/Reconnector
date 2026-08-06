import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        ZStack {
            TabView {
                DashboardView().tabItem { Label("Dashboard", systemImage: "house.fill") }
                ControlView().tabItem { Label("Control", systemImage: "slider.horizontal.3") }
                MonitoringView().tabItem { Label("Monitor", systemImage: "chart.bar.fill") }
                LogsView().tabItem { Label("Logs", systemImage: "list.bullet.rectangle") }
                SettingsView().tabItem { Label("Settings", systemImage: "gear") }
            }
            .tint(appState.accentColor)
            .preferredColorScheme(.dark)
            
            // Fullscreen loading overlay
            if appState.isPerformingAction {
                ActionOverlayView()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: appState.isPerformingAction)
        .onAppear { appState.requestNotificationPermission() }
    }
}

struct ActionOverlayView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            
            VStack(spacing: 20) {
                ProgressView(value: appState.actionProgress)
                    .progressViewStyle(.circular)
                    .scaleEffect(1.5)
                    .tint(.white)
                
                Text(appState.actionName)
                    .font(.headline)
                    .foregroundColor(.white)
                
                Text("~\(appState.actionTimeRemaining)s remaining")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.7))
            }
            .padding(40)
            .background(Color(UIColor.systemBackground).opacity(0.9))
            .cornerRadius(20)
        }
    }
}

import SwiftUI
import UserNotifications

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView()
                .tabItem { Label("Dashboard", systemImage: "house.fill") }
                .tag(0)
            
            ControlView()
                .tabItem { Label("Control", systemImage: "slider.horizontal.3") }
                .tag(1)
            
            MonitoringView()
                .tabItem { Label("Monitor", systemImage: "chart.bar.fill") }
                .tag(2)
            
            LogsView()
                .tabItem { Label("Logs", systemImage: "list.bullet.rectangle") }
                .tag(3)
            
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
                .tag(4)
        }
        .tint(appState.accentColor)
        .preferredColorScheme(appState.colorScheme)
        .onAppear { appState.requestNotificationPermission() }
    }
}

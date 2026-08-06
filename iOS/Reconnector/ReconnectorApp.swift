import SwiftUI
import UserNotifications

@main
struct ReconnectorApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .preferredColorScheme(.dark)
                .tint(.accentColor)
                .onAppear {
                    // Re-affirm delegate at app launch in case AppState init raced.
                    UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
                }
        }
    }
}

import Foundation
import Combine
import UIKit
import SwiftUI
import UserNotifications

class AppState: ObservableObject {
    @Published var ipAddress: String = UserDefaults.standard.string(forKey: "ipAddress") ?? ""
    @Published var authToken: String = UserDefaults.standard.string(forKey: "authToken") ?? "reconnector123"
    @Published var status: BotStatus?
    @Published var logs: [LogEntry] = []
    @Published var isConnected: Bool = false
    @Published var lastConnectionTime: Date?
    @Published var connectionError: String?
    @Published var screenshotImage: UIImage?
    @Published var crashes: [CrashEntry] = []
    @Published var isPerformingAction: Bool = false
    @Published var actionProgress: Double = 0
    @Published var actionName: String = ""
    @Published var actionTimeRemaining: Int = 0
    
    @Published var colorScheme: ColorScheme? = .dark
    @Published var accentColor: Color = .blue
    @Published var compactMode: Bool = false
    @Published var notifyOnDisconnect: Bool = true
    @Published var notifyOnReconnect: Bool = true
    @Published var notifyOnError: Bool = true
    @Published var logLevel: String = "INFO"
    @Published var autoScrollLogs: Bool = true
    @Published var autoConnect: Bool = true
    
    private var pollTimer: Timer?
    private var logPollTimer: Timer?
    private var isPolling = false
    private var actionTimer: Timer?
    
    init() {
        loadSettings()
        if !ipAddress.isEmpty && autoConnect { startPolling() }
    }
    
    func loadSettings() {
        let d = UserDefaults.standard
        ipAddress = d.string(forKey: "ipAddress") ?? ""
        authToken = d.string(forKey: "authToken") ?? "reconnector123"
        colorScheme = d.string(forKey: "colorScheme") == "light" ? .light : .dark
        accentColor = d.colorForKey("accentColor") ?? .blue
        compactMode = d.bool(forKey: "compactMode")
        notifyOnDisconnect = d.object(forKey: "notifyDisconnect") as? Bool ?? true
        notifyOnReconnect = d.object(forKey: "notifyReconnect") as? Bool ?? true
        notifyOnError = d.object(forKey: "notifyError") as? Bool ?? true
        logLevel = d.string(forKey: "logLevel") ?? "INFO"
        autoScrollLogs = d.object(forKey: "autoScrollLogs") as? Bool ?? true
        autoConnect = d.object(forKey: "autoConnect") as? Bool ?? true
    }
    
    func saveSettings() {
        let d = UserDefaults.standard
        d.set(ipAddress, forKey: "ipAddress")
        d.set(authToken, forKey: "authToken")
        d.set(colorScheme == .light ? "light" : "dark", forKey: "colorScheme")
        d.setColor(accentColor, forKey: "accentColor")
        d.set(compactMode, forKey: "compactMode")
        d.set(notifyOnDisconnect, forKey: "notifyDisconnect")
        d.set(notifyOnReconnect, forKey: "notifyReconnect")
        d.set(notifyOnError, forKey: "notifyError")
        d.set(logLevel, forKey: "logLevel")
        d.set(autoScrollLogs, forKey: "autoScrollLogs")
        d.set(autoConnect, forKey: "autoConnect")
        d.synchronize()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.startPolling() }
    }
    
    func resetSettings() {
        let d = UserDefaults.standard
        for key in d.dictionaryRepresentation().keys { d.removeObject(forKey: key) }
        d.synchronize()
        loadSettings()
    }
    
    func startPolling() {
        stopPolling()
        guard !ipAddress.isEmpty else { connectionError = "No IP address set."; return }
        connectionError = nil
        fetchStatusNow()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in self?.fetchStatusNow() }
        logPollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in self?.fetchLogsNow() }
    }
    
    func stopPolling() { pollTimer?.invalidate(); pollTimer = nil; logPollTimer?.invalidate(); logPollTimer = nil }
    func connectWebSocket() { startPolling() }
    
    // ACTION LOADING SYSTEM
    func startAction(name: String, estimatedSeconds: Int) {
        isPerformingAction = true
        actionName = name
        actionTimeRemaining = estimatedSeconds
        actionProgress = 0
        
        actionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.actionTimeRemaining -= 1
            self.actionProgress = Double(estimatedSeconds - self.actionTimeRemaining) / Double(estimatedSeconds)
            if self.actionTimeRemaining <= 0 { self.endAction() }
        }
    }
    
    func endAction() {
        actionTimer?.invalidate()
        actionTimer = nil
        isPerformingAction = false
        actionProgress = 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.actionProgress = 0 }
    }
    
    // NOTIFICATIONS
    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }
    
    func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
    
    func sendTestNotification() {
        sendNotification(title: "Test Notification", body: "If you can see this, notifications are working!")
    }
    
    // API CALLS
    private func fetchStatusNow() {
        guard !ipAddress.isEmpty, !isPolling else { return }
        isPolling = true
        let client = APIClient(ipAddress: ipAddress, authToken: authToken)
        Task {
            do {
                let s = try await client.getStatus()
                let wasConnected = self.isConnected
                await MainActor.run {
                    self.status = s
                    self.lastConnectionTime = Date()
                    self.isConnected = true
                    self.connectionError = nil
                    self.isPolling = false
                    // Notifications on state change
                    if !wasConnected && self.notifyOnReconnect {
                        self.sendNotification(title: "Reconnected", body: "Backend connection restored.")
                    }
                }
            } catch {
                let wasConnected = self.isConnected
                await MainActor.run {
                    self.isConnected = false
                    self.isPolling = false
                    self.connectionError = "Cannot reach backend"
                    if wasConnected && self.notifyOnDisconnect {
                        self.sendNotification(title: "Disconnected", body: "Lost connection to backend.")
                    }
                }
            }
        }
    }
    
    private func fetchLogsNow() {
        guard !ipAddress.isEmpty else { return }
        let url = URL(string: "http://\(ipAddress):8080/api/logs")!
        var request = URLRequest(url: url); request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let logLines = json["logs"] as? [String] else { return }
            DispatchQueue.main.async { self.logs = logLines.map { LogEntry(text: $0, timestamp: Date()) } }
        }.resume()
    }
    
    func fetchStatus() async { await fetchStatusNow() }
    
    func fetchScreenshot() async {
        guard !ipAddress.isEmpty else { return }
        startAction(name: "Capturing Screenshot", estimatedSeconds: 5)
        let client = APIClient(ipAddress: ipAddress, authToken: authToken)
        do {
            let response = try await client.getScreenshot()
            if let imageData = Data(base64Encoded: response.image), let image = UIImage(data: imageData) {
                DispatchQueue.main.async { self.screenshotImage = image; self.endAction() }
            } else { DispatchQueue.main.async { self.endAction() } }
        } catch { DispatchQueue.main.async { self.endAction() } }
    }
    
    func fetchCrashes() async {
        guard !ipAddress.isEmpty else { return }
        let client = APIClient(ipAddress: ipAddress, authToken: authToken)
        do {
            let response = try await client.getCrashes()
            DispatchQueue.main.async { self.crashes = response.crashes }
        } catch {}
    }
    
    func restartRoblox() async {
        startAction(name: "Restarting Roblox", estimatedSeconds: 15)
        let client = APIClient(ipAddress: ipAddress, authToken: authToken)
        do { _ = try await client.restart() } catch { DispatchQueue.main.async { self.endAction() } }
    }
}

extension UserDefaults {
    func colorForKey(_ key: String) -> Color? {
        guard let data = data(forKey: key), let uiColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: UIColor.self, from: data) else { return nil }
        return Color(uiColor)
    }
    func setColor(_ color: Color, forKey key: String) {
        let uiColor = UIColor(color)
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: uiColor, requiringSecureCoding: false) { set(data, forKey: key) }
    }
}

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
    @Published var videoData: Data?
    @Published var crashes: [CrashEntry] = []
    @Published var isPerformingAction: Bool = false
    @Published var actionName: String = ""
    @Published var actionProgress: Double = 0
    @Published var actionTimeRemaining: Int = 0
    @Published var watchdogEnabled: Bool = false
    @Published var optKillBg: Bool = false
    @Published var optProcessLimit: Bool = false
    @Published var optNoAnimations: Bool = false
    @Published var optForceGpu: Bool = false
    @Published var optNoBluetooth: Bool = false
    
    @Published var accentColor: Color = .blue
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
        accentColor = d.colorForKey("accentColor") ?? .blue
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
        d.setColor(accentColor, forKey: "accentColor")
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
    
    // ACTION LOADING
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.actionProgress = 0 }
    }
    
    // NOTIFICATIONS
    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            if granted { print("[NOTIF] Permission granted") }
            else { print("[NOTIF] Permission denied") }
        }
    }
    
    func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error { print("[NOTIF] Failed: \(error)") }
            else { print("[NOTIF] Sent: \(title)") }
        }
    }
    
    func sendTestNotification() {
        requestNotificationPermission()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.sendNotification(title: "Reconnector Test", body: "Notifications are working!")
        }
    }
    
    // STATUS UPDATES
    private func fetchStatusNow() {
        guard !ipAddress.isEmpty, !isPolling else { return }
        isPolling = true
        let url = URL(string: "http://\(ipAddress):8080/api/status")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        URLSession.shared.dataTask(with: request) { data, _, error in
            DispatchQueue.main.async {
                self.isPolling = false
                if let data = data, let status = try? JSONDecoder().decode(BotStatus.self, from: data) {
                    let wasConnected = self.isConnected
                    self.status = status
                    self.lastConnectionTime = Date()
                    self.isConnected = true
                    self.connectionError = nil
                    self.watchdogEnabled = status.watchdog_enabled
                    self.optKillBg = status.optimizations.kill_bg
                    self.optProcessLimit = status.optimizations.process_limit
                    self.optNoAnimations = status.optimizations.no_animations
                    self.optForceGpu = status.optimizations.force_gpu
                    self.optNoBluetooth = status.optimizations.no_bluetooth
                    if !wasConnected && self.notifyOnReconnect { self.sendNotification(title: "Reconnected", body: "Backend connection restored.") }
                } else {
                    let wasConnected = self.isConnected
                    self.isConnected = false
                    self.connectionError = "Cannot reach backend"
                    if wasConnected && self.notifyOnDisconnect { self.sendNotification(title: "Disconnected", body: "Lost connection to backend.") }
                }
            }
        }.resume()
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
        let url = URL(string: "http://\(ipAddress):8080/api/screenshot")!
        URLSession.shared.dataTask(with: url) { data, _, _ in
            DispatchQueue.main.async {
                if let data = data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let imgStr = json["image"] as? String, let imgData = Data(base64Encoded: imgStr), let image = UIImage(data: imgData) {
                    self.screenshotImage = image
                }
                self.endAction()
            }
        }.resume()
    }
    
    func fetchVideo() async {
        guard !ipAddress.isEmpty else { return }
        startAction(name: "Recording 3s Proving Video", estimatedSeconds: 6)
        let url = URL(string: "http://\(ipAddress):8080/api/video")!
        URLSession.shared.dataTask(with: url) { data, _, _ in
            DispatchQueue.main.async {
                if let data = data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let vidStr = json["video"] as? String, let vidData = Data(base64Encoded: vidStr) {
                    self.videoData = vidData
                }
                self.endAction()
            }
        }.resume()
    }
    
    func fetchCrashes() async {
        guard !ipAddress.isEmpty else { return }
        let url = URL(string: "http://\(ipAddress):8080/api/crashes")!
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data, let response = try? JSONDecoder().decode(CrashResponse.self, from: data) else { return }
            DispatchQueue.main.async { self.crashes = response.crashes }
        }.resume()
    }
    
    func clearLogsServer() {
        guard !ipAddress.isEmpty else { return }
        let url = URL(string: "http://\(ipAddress):8080/api/clear-logs")!
        var request = URLRequest(url: url); request.httpMethod = "GET"
        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }
    
    func toggleWatchdog() {
        // Optimistic update
        watchdogEnabled.toggle()
        let url = URL(string: "http://\(ipAddress):8080/api/watchdog/toggle")!
        var request = URLRequest(url: url); request.httpMethod = "POST"
        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }
    
    func toggleOptimization(name: String, current: Bool) {
        let newValue = !current
        // Optimistic update
        switch name {
        case "kill_bg": optKillBg = newValue
        case "process_limit": optProcessLimit = newValue
        case "no_animations": optNoAnimations = newValue
        case "force_gpu": optForceGpu = newValue
        case "no_bluetooth": optNoBluetooth = newValue
        default: break
        }
        
        let url = URL(string: "http://\(ipAddress):8080/api/optimize/\(name)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["enabled": newValue])
        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }
    
    func restartRoblox() async {
        startAction(name: "Restarting Roblox", estimatedSeconds: 10)
        let url = URL(string: "http://\(ipAddress):8080/api/restart")!
        var request = URLRequest(url: url); request.httpMethod = "POST"
        URLSession.shared.dataTask(with: request) { _, _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self.endAction() }
        }.resume()
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

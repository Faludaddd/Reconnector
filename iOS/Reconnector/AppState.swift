import Foundation
import Combine
import UIKit
import SwiftUI
import UserNotifications

// Single notification delegate so foreground notifications actually show.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Show banner + sound + badge even when app is in foreground
        completionHandler([.banner, .sound, .badge, .list])
    }
}

class AppState: ObservableObject {
    // Connection settings (persisted)
    @Published var ipAddress: String = UserDefaults.standard.string(forKey: "ipAddress") ?? "" {
        didSet { UserDefaults.standard.set(ipAddress, forKey: "ipAddress") }
    }
    @Published var authToken: String = UserDefaults.standard.string(forKey: "authToken") ?? "reconnector123" {
        didSet { UserDefaults.standard.set(authToken, forKey: "authToken") }
    }

    // Live state
    @Published var status: BotStatus?
    @Published var logs: [LogEntry] = []
    @Published var isConnected: Bool = false
    @Published var isConnecting: Bool = false
    @Published var lastConnectionTime: Date?
    @Published var connectionError: String?

    // Media
    @Published var screenshotImage: UIImage?
    @Published var videoData: Data?

    // Crash history
    @Published var crashes: [CrashEntry] = []

    // Loading overlay
    @Published var isPerformingAction: Bool = false
    @Published var actionName: String = ""
    @Published var actionProgress: Double = 0
    @Published var actionTimeRemaining: Int = 0
    @Published var actionError: String? = nil

    // Watchdog
    @Published var watchdogEnabled: Bool = false
    @Published var watchdogInterval: Int = 1

    // Optimizations - kept locally so UI toggles instantly
    @Published var optKillBg: Bool = false
    @Published var optProcessLimit: Bool = false
    @Published var optNoAnimations: Bool = false
    @Published var optForceGpu: Bool = false
    @Published var optNoBluetooth: Bool = false

    // Settings (persisted)
    @Published var notifyOnDisconnect: Bool = UserDefaults.standard.object(forKey: "notifyDisconnect") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notifyOnDisconnect, forKey: "notifyDisconnect") }
    }
    @Published var notifyOnReconnect: Bool = UserDefaults.standard.object(forKey: "notifyReconnect") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notifyOnReconnect, forKey: "notifyReconnect") }
    }
    @Published var notifyOnError: Bool = UserDefaults.standard.object(forKey: "notifyError") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notifyOnError, forKey: "notifyError") }
    }
    @Published var autoScrollLogs: Bool = UserDefaults.standard.object(forKey: "autoScrollLogs") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoScrollLogs, forKey: "autoScrollLogs") }
    }
    @Published var autoConnect: Bool = UserDefaults.standard.object(forKey: "autoConnect") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoConnect, forKey: "autoConnect") }
    }
    @Published var gameLink: String = UserDefaults.standard.string(forKey: "gameLink") ?? "" {
        didSet { UserDefaults.standard.set(gameLink, forKey: "gameLink") }
    }

    // Internal
    private var pollTimer: Timer?
    private var logPollTimer: Timer?
    private var actionTimer: Timer?
    private var consecutiveFailures = 0
    private var lastNotificationState: Bool? = nil

    init() {
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                self.requestNotificationPermission()
            }
        }
        if !ipAddress.isEmpty && autoConnect {
            startPolling()
        }
    }

    // MARK: - Settings
    func saveConnectionSettings() {
        UserDefaults.standard.synchronize()
        startPolling()
    }

    func resetSettings() {
        let keys = ["ipAddress", "authToken", "notifyDisconnect", "notifyReconnect",
                    "notifyError", "autoScrollLogs", "autoConnect", "gameLink"]
        for k in keys { UserDefaults.standard.removeObject(forKey: k) }
        UserDefaults.standard.synchronize()
        ipAddress = ""
        authToken = "reconnector123"
        notifyOnDisconnect = true
        notifyOnReconnect = true
        notifyOnError = true
        autoScrollLogs = true
        autoConnect = true
        gameLink = ""
        stopPolling()
    }

    // MARK: - Polling with backoff
    func startPolling() {
        stopPolling()
        guard !ipAddress.isEmpty else {
            connectionError = "No IP address set."
            return
        }
        connectionError = nil
        isConnecting = true
        fetchStatusNow()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.fetchStatusNow()
        }
        logPollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.fetchLogsNow()
        }
        fetchLogsNow()
    }

    func stopPolling() {
        pollTimer?.invalidate(); pollTimer = nil
        logPollTimer?.invalidate(); logPollTimer = nil
    }

    func reconnect() { startPolling() }

    // MARK: - Notifications
    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("[NOTIF] Permission error: \(error)")
            } else {
                print("[NOTIF] Permission granted: \(granted)")
            }
        }
    }

    func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[NOTIF] Failed: \(error)")
            } else {
                print("[NOTIF] Sent: \(title)")
            }
        }
    }

    func sendTestNotification() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                self.requestNotificationPermission()
                // Wait for user to respond, then send
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.sendNotification(title: "Reconnector Test", body: "Notifications are working!")
                }
            } else if settings.authorizationStatus == .denied {
                DispatchQueue.main.async {
                    self.actionError = "Notifications are blocked. Please enable them in iOS Settings."
                }
            } else {
                self.sendNotification(title: "Reconnector Test", body: "Notifications are working!")
            }
        }
    }

    // MARK: - Status polling
    private func fetchStatusNow() {
        guard !ipAddress.isEmpty else { return }
        let url = URL(string: "http://\(ipAddress):8080/api/status")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        URLSession.shared.dataTask(with: request) { data, _, error in
            DispatchQueue.main.async {
                self.isConnecting = false
                if let data = data,
                   let status = try? JSONDecoder().decode(BotStatus.self, from: data) {
                    self.handleStatusSuccess(status)
                } else {
                    self.handleStatusFailure(error)
                }
            }
        }.resume()
    }

    private func handleStatusSuccess(_ status: BotStatus) {
        let wasConnected = self.isConnected
        self.status = status
        self.lastConnectionTime = Date()
        self.isConnected = true
        self.connectionError = nil
        self.consecutiveFailures = 0
        self.watchdogEnabled = status.watchdog_enabled
        self.watchdogInterval = status.interval
        self.gameLink = status.game_link
        // Pull optimization state from server so we stay in sync after backend restart
        // but only if user is not actively toggling right now.
        if !isPerformingAction {
            self.optKillBg = status.optimizations.kill_bg
            self.optProcessLimit = status.optimizations.process_limit
            self.optNoAnimations = status.optimizations.no_animations
            self.optForceGpu = status.optimizations.force_gpu
            self.optNoBluetooth = status.optimizations.no_bluetooth
        }
        // Notify on reconnect (but avoid spamming on first successful connect)
        if wasConnected == false && lastNotificationState == true && notifyOnReconnect {
            sendNotification(title: "Reconnected", body: "Backend connection restored.")
        }
        lastNotificationState = true
    }

    private func handleStatusFailure(_ error: Error?) {
        consecutiveFailures += 1
        let wasConnected = self.isConnected
        self.isConnected = false
        self.connectionError = "Cannot reach backend (attempt \(consecutiveFailures))"
        // Only notify on the *first* transition from connected -> disconnected
        if wasConnected && lastNotificationState != false && notifyOnDisconnect {
            sendNotification(title: "Disconnected", body: "Lost connection to backend.")
        }
        lastNotificationState = false
    }

    // MARK: - Logs polling
    private func fetchLogsNow() {
        guard !ipAddress.isEmpty else { return }
        let url = URL(string: "http://\(ipAddress):8080/api/logs")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let logLines = json["logs"] as? [String] else { return }
            // If user just cleared logs and the server returns an empty list, keep it empty.
            DispatchQueue.main.async {
                if logLines.isEmpty {
                    self.logs = []
                } else {
                    self.logs = logLines.map { LogEntry(text: $0, timestamp: Date()) }
                }
            }
        }.resume()
    }

    func clearLogs() {
        // 1. Clear local state immediately
        logs.removeAll()
        // 2. Tell backend to flush its file handlers too
        guard !ipAddress.isEmpty else { return }
        let url = URL(string: "http://\(ipAddress):8080/api/clear-logs")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { _, _, _ in
            // Force a fresh fetch to confirm
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.fetchLogsNow()
            }
        }.resume()
    }

    // MARK: - Action overlay
    func startAction(name: String, estimatedSeconds: Int) {
        isPerformingAction = true
        actionName = name
        actionTimeRemaining = estimatedSeconds
        actionProgress = 0
        actionError = nil
        actionTimer?.invalidate()
        let startTime = Date()
        actionTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let elapsed = Date().timeIntervalSince(startTime)
            self.actionProgress = min(0.95, elapsed / Double(estimatedSeconds))
            self.actionTimeRemaining = max(0, estimatedSeconds - Int(elapsed))
        }
    }

    func endAction(error: String? = nil) {
        actionTimer?.invalidate()
        actionTimer = nil
        actionProgress = 1.0
        if let error = error {
            actionError = error
            // Keep overlay visible briefly so the user sees the error
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.isPerformingAction = false
                self?.actionProgress = 0
                self?.actionError = nil
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.isPerformingAction = false
                self?.actionProgress = 0
            }
        }
    }

    // MARK: - Watchdog toggle (optimistic, rollback on failure)
    func toggleWatchdog() {
        let oldValue = watchdogEnabled
        watchdogEnabled.toggle()
        let url = URL(string: "http://\(ipAddress):8080/api/watchdog/toggle")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        URLSession.shared.dataTask(with: request) { data, response, _ in
            DispatchQueue.main.async {
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let enabled = json["enabled"] as? Bool {
                    self.watchdogEnabled = enabled
                } else if (response as? HTTPURLResponse)?.statusCode != 200 {
                    // Rollback
                    self.watchdogEnabled = oldValue
                    self.actionError = "Failed to toggle watchdog."
                }
            }
        }.resume()
    }

    // MARK: - Optimization toggle (optimistic, rollback on failure)
    func toggleOptimization(name: String) {
        let oldValue: Bool
        switch name {
        case "kill_bg": oldValue = optKillBg; optKillBg.toggle()
        case "process_limit": oldValue = optProcessLimit; optProcessLimit.toggle()
        case "no_animations": oldValue = optNoAnimations; optNoAnimations.toggle()
        case "force_gpu": oldValue = optForceGpu; optForceGpu.toggle()
        case "no_bluetooth": oldValue = optNoBluetooth; optNoBluetooth.toggle()
        default: return
        }
        let newValue = !oldValue
        let url = URL(string: "http://\(ipAddress):8080/api/optimize/\(name)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["enabled": newValue])
        request.timeoutInterval = 10
        isPerformingAction = false  // toggles shouldn't show fullscreen overlay
        URLSession.shared.dataTask(with: request) { data, response, _ in
            DispatchQueue.main.async {
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   json["status"] as? String == "ok" {
                    // Server confirmed - state stays as user toggled
                    // Optionally trust server echo:
                    if let opts = json["optimizations"] as? [String: Any] {
                        self.optKillBg = opts["kill_bg"] as? Bool ?? self.optKillBg
                        self.optProcessLimit = opts["process_limit"] as? Bool ?? self.optProcessLimit
                        self.optNoAnimations = opts["no_animations"] as? Bool ?? self.optNoAnimations
                        self.optForceGpu = opts["force_gpu"] as? Bool ?? self.optForceGpu
                        self.optNoBluetooth = opts["no_bluetooth"] as? Bool ?? self.optNoBluetooth
                    }
                } else if (response as? HTTPURLResponse)?.statusCode != 200 {
                    // Rollback on failure
                    switch name {
                    case "kill_bg": self.optKillBg = oldValue
                    case "process_limit": self.optProcessLimit = oldValue
                    case "no_animations": self.optNoAnimations = oldValue
                    case "force_gpu": self.optForceGpu = oldValue
                    case "no_bluetooth": self.optNoBluetooth = oldValue
                    default: break
                    }
                    self.actionError = "Failed to apply \(name.replacingOccurrences(of: "_", with: " "))."
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        if self.actionError?.contains("Failed to apply") == true {
                            self.actionError = nil
                        }
                    }
                }
            }
        }.resume()
    }

    // MARK: - Restart Roblox
    func restartRoblox() {
        startAction(name: "Restarting Roblox", estimatedSeconds: 12)
        let url = URL(string: "http://\(ipAddress):8080/api/restart")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        URLSession.shared.dataTask(with: request) { data, response, error in
            // Backend kicks off restart in background; we poll for completion.
            DispatchQueue.main.async {
                if error != nil || (response as? HTTPURLResponse)?.statusCode != 200 {
                    self.endAction(error: "Failed to initiate restart.")
                    return
                }
            }
            // Poll status until roblox_state is no longer "reconnecting" (max 25s)
            self.waitForRestartCompletion(maxSeconds: 25)
        }.resume()
    }

    private func waitForRestartCompletion(maxSeconds: Int) {
        let start = Date()
        func check() {
            let url = URL(string: "http://\(ipAddress):8080/api/status")!
            var req = URLRequest(url: url)
            req.timeoutInterval = 6
            URLSession.shared.dataTask(with: req) { data, _, _ in
                DispatchQueue.main.async {
                    guard let data = data,
                          let s = try? JSONDecoder().decode(BotStatus.self, from: data) else {
                        if Date().timeIntervalSince(start) >= Double(maxSeconds) {
                            self.endAction()
                        } else {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { check() }
                        }
                        return
                    }
                    self.status = s
                    let elapsed = Int(Date().timeIntervalSince(start))
                    if s.roblox_state != "reconnecting" && elapsed > 4 {
                        // Give it a moment to settle, then dismiss
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            self.endAction(error: s.roblox_state == "offline" ? "Restart failed." : nil)
                        }
                    } else if elapsed >= maxSeconds {
                        self.endAction()
                    } else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { check() }
                    }
                }
            }.resume()
        }
        check()
    }

    // MARK: - Screenshot
    func fetchScreenshot() {
        startAction(name: "Capturing Screenshot", estimatedSeconds: 4)
        let url = URL(string: "http://\(ipAddress):8080/api/screenshot")!
        URLSession.shared.dataTask(with: url) { data, _, _ in
            DispatchQueue.main.async {
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let imgStr = json["image"] as? String,
                   let imgData = Data(base64Encoded: imgStr),
                   let image = UIImage(data: imgData) {
                    self.screenshotImage = image
                    self.endAction()
                } else {
                    self.endAction(error: "Failed to capture screenshot.")
                }
            }
        }.resume()
    }

    // MARK: - 3-second proving video
    func fetchVideo() {
        startAction(name: "Recording 3s Proving Video", estimatedSeconds: 6)
        let url = URL(string: "http://\(ipAddress):8080/api/video")!
        URLSession.shared.dataTask(with: url) { data, _, _ in
            DispatchQueue.main.async {
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let vidStr = json["video"] as? String,
                   !vidStr.isEmpty,
                   let vidData = Data(base64Encoded: vidStr) {
                    self.videoData = vidData
                    self.endAction()
                } else {
                    self.endAction(error: "Failed to record proving video.")
                }
            }
        }.resume()
    }

    // MARK: - Crashes
    func fetchCrashes() {
        guard !ipAddress.isEmpty else { return }
        let url = URL(string: "http://\(ipAddress):8080/api/crashes")!
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data,
                  let response = try? JSONDecoder().decode(CrashResponse.self, from: data) else { return }
            DispatchQueue.main.async { self.crashes = response.crashes }
        }.resume()
    }

    // MARK: - Clear anti-loop
    func clearAntiLoop() {
        guard !ipAddress.isEmpty else { return }
        let url = URL(string: "http://\(ipAddress):8080/api/clear-anti-loop")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }

    // MARK: - Game link
    func setGameLink(_ link: String, completion: @escaping (Bool) -> Void) {
        guard !ipAddress.isEmpty else { completion(false); return }
        let url = URL(string: "http://\(ipAddress):8080/api/game-link")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["url": link])
        request.timeoutInterval = 8
        URLSession.shared.dataTask(with: request) { data, response, _ in
            DispatchQueue.main.async {
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   json["status"] as? String == "ok" {
                    self.gameLink = link
                    self.status?.game_link = link
                    completion(true)
                } else {
                    completion(false)
                }
            }
        }.resume()
    }

    // MARK: - Interval
    func setInterval(_ minutes: Int) {
        guard !ipAddress.isEmpty else { return }
        let oldValue = watchdogInterval
        watchdogInterval = minutes
        let url = URL(string: "http://\(ipAddress):8080/api/interval/\(minutes)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        URLSession.shared.dataTask(with: request) { data, response, _ in
            DispatchQueue.main.async {
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   json["status"] as? String == "ok",
                   let interval = json["interval"] as? Int {
                    self.watchdogInterval = interval
                    self.status?.interval = interval
                } else if (response as? HTTPURLResponse)?.statusCode != 200 {
                    self.watchdogInterval = oldValue
                }
            }
        }.resume()
    }

    // MARK: - Async wrappers for SwiftUI .task
    func fetchStatus() async {
        // Just trigger the synchronous polling fetch; don't block
        fetchStatusNow()
    }
}

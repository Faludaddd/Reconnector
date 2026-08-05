import Foundation
import Combine
import UIKit
import SwiftUI

class AppState: ObservableObject {
    // Connection
    @Published var ipAddress: String = UserDefaults.standard.string(forKey: "ipAddress") ?? ""
    @Published var authToken: String = UserDefaults.standard.string(forKey: "authToken") ?? "reconnector123"
    @Published var status: BotStatus?
    @Published var logs: [LogEntry] = []
    @Published var isConnected: Bool = false
    @Published var lastConnectionTime: Date?
    @Published var connectionError: String?
    @Published var screenshotImage: UIImage?
    @Published var crashes: [CrashEntry] = []
    
    // Appearance Settings
    @Published var colorScheme: ColorScheme? = UserDefaults.standard.object(forKey: "colorScheme") as? String == "light" ? .light : .dark
    @Published var accentColor: Color = UserDefaults.standard.colorForKey("accentColor") ?? .blue
    @Published var compactMode: Bool = UserDefaults.standard.bool(forKey: "compactMode")
    
    // Notification Settings
    @Published var notifyOnDisconnect: Bool = UserDefaults.standard.bool(forKey: "notifyDisconnect")
    @Published var notifyOnReconnect: Bool = UserDefaults.standard.bool(forKey: "notifyReconnect")
    @Published var notifyOnError: Bool = UserDefaults.standard.bool(forKey: "notifyError")
    
    // Log Settings
    @Published var logLevel: String = UserDefaults.standard.string(forKey: "logLevel") ?? "INFO"
    @Published var autoScrollLogs: Bool = UserDefaults.standard.bool(forKey: "autoScrollLogs")
    
    // Connection Settings
    @Published var autoConnect: Bool = UserDefaults.standard.bool(forKey: "autoConnect")
    @Published var connectionTimeout: Int = UserDefaults.standard.integer(forKey: "timeout") == 0 ? 5 : UserDefaults.standard.integer(forKey: "timeout")
    
    private var pollTimer: Timer?
    private var logPollTimer: Timer?
    private var isPolling = false
    
    init() {
        if !ipAddress.isEmpty && autoConnect {
            startPolling()
        }
    }
    
    func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(ipAddress, forKey: "ipAddress")
        defaults.set(authToken, forKey: "authToken")
        defaults.set(colorScheme == .light ? "light" : "dark", forKey: "colorScheme")
        defaults.setColor(accentColor, forKey: "accentColor")
        defaults.set(compactMode, forKey: "compactMode")
        defaults.set(notifyOnDisconnect, forKey: "notifyDisconnect")
        defaults.set(notifyOnReconnect, forKey: "notifyReconnect")
        defaults.set(notifyOnError, forKey: "notifyError")
        defaults.set(logLevel, forKey: "logLevel")
        defaults.set(autoScrollLogs, forKey: "autoScrollLogs")
        defaults.set(autoConnect, forKey: "autoConnect")
        defaults.set(connectionTimeout, forKey: "timeout")
        defaults.synchronize()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.startPolling()
        }
    }
    
    func resetSettings() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys {
            defaults.removeObject(forKey: key)
        }
        defaults.synchronize()
    }
    
    func startPolling() {
        stopPolling()
        guard !ipAddress.isEmpty else {
            connectionError = "No IP address set. Go to Settings to configure."
            return
        }
        connectionError = nil
        fetchStatusNow()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in self?.fetchStatusNow() }
        logPollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in self?.fetchLogsNow() }
    }
    
    func stopPolling() { pollTimer?.invalidate(); pollTimer = nil; logPollTimer?.invalidate(); logPollTimer = nil }
    func connectWebSocket() { startPolling() }
    
    private func fetchStatusNow() {
        guard !ipAddress.isEmpty, !isPolling else { return }
        isPolling = true
        let client = APIClient(ipAddress: ipAddress, authToken: authToken)
        Task {
            do {
                let s = try await client.getStatus()
                await MainActor.run { self.status = s; self.lastConnectionTime = Date(); self.isConnected = true; self.connectionError = nil; self.isPolling = false }
            } catch {
                await MainActor.run { self.isConnected = false; self.isPolling = false; self.connectionError = "Cannot reach backend: \(error.localizedDescription)" }
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
    
    func fetchStatus() async { await fetchStatusNow() } // Wrapper for .task
    func fetchScreenshot() async {
        guard !ipAddress.isEmpty else { return }
        let client = APIClient(ipAddress: ipAddress, authToken: authToken)
        do { let response = try await client.getScreenshot(); if let imageData = Data(base64Encoded: response.image), let image = UIImage(data: imageData) { DispatchQueue.main.async { self.screenshotImage = image } } } catch {}
    }
    func fetchCrashes() async {
        guard !ipAddress.isEmpty else { return }
        let client = APIClient(ipAddress: ipAddress, authToken: authToken)
        do { let response = try await client.getCrashes(); DispatchQueue.main.async { self.crashes = response.crashes } } catch {}
    }
}

extension UserDefaults {
    func colorForKey(_ key: String) -> Color? {
        guard let data = data(forKey: key), let uiColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: UIColor.self, from: data) else { return nil }
        return Color(uiColor)
    }
    func setColor(_ color: Color, forKey key: String) {
        let uiColor = UIColor(color)
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: uiColor, requiringSecureCoding: false) {
            set(data, forKey: key)
        }
    }
}

import Foundation
import Combine
import UIKit

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
    
    private var pollTimer: Timer?
    private var logPollTimer: Timer?
    private var isPolling = false
    
    init() {
        if !ipAddress.isEmpty {
            startPolling()
        }
    }
    
    func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(ipAddress, forKey: "ipAddress")
        defaults.set(authToken, forKey: "authToken")
        defaults.synchronize()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.startPolling()
        }
    }
    
    func startPolling() {
        stopPolling()
        
        guard !ipAddress.isEmpty else {
            connectionError = "No IP address set. Go to Settings to configure."
            return
        }
        
        connectionError = nil
        fetchStatusNow()
        
        // Poll status every 5 seconds
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.fetchStatusNow()
        }
        
        // Poll logs every 3 seconds
        logPollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.fetchLogsNow()
        }
    }
    
    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        logPollTimer?.invalidate()
        logPollTimer = nil
    }
    
    func connectWebSocket() {
        startPolling()
    }
    
    private func fetchStatusNow() {
        guard !ipAddress.isEmpty, !isPolling else { return }
        isPolling = true
        
        let client = APIClient(ipAddress: ipAddress, authToken: authToken)
        Task {
            do {
                let s = try await client.getStatus()
                await MainActor.run {
                    self.status = s
                    self.lastConnectionTime = Date()
                    self.isConnected = true
                    self.connectionError = nil
                    self.isPolling = false
                }
            } catch {
                await MainActor.run {
                    self.isConnected = false
                    self.isPolling = false
                    self.connectionError = "Cannot reach backend: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func fetchLogsNow() {
        guard !ipAddress.isEmpty else { return }
        
        let url = URL(string: "http://\(ipAddress):8080/api/logs")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let logLines = json["logs"] as? [String] else { return }
            
            DispatchQueue.main.async {
                // Only add new logs
                let newEntries = logLines.enumerated().compactMap { index, text -> LogEntry? in
                    let entry = LogEntry(text: text, timestamp: Date())
                    return entry
                }
                
                // Replace logs entirely (server sends last 100)
                self.logs = newEntries
            }
        }.resume()
    }
    
    func fetchStatus() async {
        guard !ipAddress.isEmpty else { return }
        let client = APIClient(ipAddress: ipAddress, authToken: authToken)
        do {
            let s = try await client.getStatus()
            DispatchQueue.main.async {
                self.status = s
                self.lastConnectionTime = Date()
                self.isConnected = true
                self.connectionError = nil
            }
        } catch {
            DispatchQueue.main.async {
                self.connectionError = "Failed: \(error.localizedDescription)"
            }
        }
    }
    
    func fetchScreenshot() async {
        guard !ipAddress.isEmpty else { return }
        let client = APIClient(ipAddress: ipAddress, authToken: authToken)
        do {
            let response = try await client.getScreenshot()
            if let imageData = Data(base64Encoded: response.image), let image = UIImage(data: imageData) {
                DispatchQueue.main.async { self.screenshotImage = image }
            }
        } catch {
            print("Failed to fetch screenshot: \(error)")
        }
    }
    
    func fetchCrashes() async {
        guard !ipAddress.isEmpty else { return }
        let client = APIClient(ipAddress: ipAddress, authToken: authToken)
        do {
            let response = try await client.getCrashes()
            DispatchQueue.main.async { self.crashes = response.crashes }
        } catch {
            print("Failed to fetch crashes: \(error)")
        }
    }
}

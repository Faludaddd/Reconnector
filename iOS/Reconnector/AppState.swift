import SwiftUI
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
    @Published var hasCompletedSetup: Bool = UserDefaults.standard.bool(forKey: "hasCompletedSetup")
    
    private var webSocketTask: URLSessionWebSocketTask?
    private var reconnectAttempts = 0
    
    init() {
        if !ipAddress.isEmpty {
            connectWebSocket()
        }
    }
    
    func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(ipAddress, forKey: "ipAddress")
        defaults.set(authToken, forKey: "authToken")
        defaults.synchronize()
        
        // Small delay to let UserDefaults flush
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.connectWebSocket()
        }
    }
    
    func completeSetup() {
        hasCompletedSetup = true
        UserDefaults.standard.set(true, forKey: "hasCompletedSetup")
        UserDefaults.standard.synchronize()
    }
    
    func connectWebSocket() {
        // Cancel existing connection
        webSocketTask?.cancel()
        webSocketTask = nil
        
        guard !ipAddress.isEmpty else {
            connectionError = "No IP address set. Go to Settings to configure."
            return
        }
        
        connectionError = nil
        
        let urlString = "ws://\(ipAddress):8080/ws"
        guard let url = URL(string: urlString) else {
            connectionError = "Invalid IP address"
            return
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        
        webSocketTask = URLSession.shared.webSocketTask(with: request)
        webSocketTask?.resume()
        
        isConnected = true
        reconnectAttempts = 0
        receiveWebSocket()
        
        // Also fetch status immediately
        Task { await fetchStatus() }
    }
    
    private func receiveWebSocket() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .data(let data):
                    self.handleWebSocketData(data)
                case .string(let text):
                    if let data = text.data(using: .utf8) {
                        self.handleWebSocketData(data)
                    }
                @unknown default:
                    break
                }
                self.receiveWebSocket()
                
            case .failure(let error):
                DispatchQueue.main.async {
                    self.isConnected = false
                    self.connectionError = "Connection lost: \(error.localizedDescription)"
                }
                self.attemptReconnect()
            }
        }
    }
    
    private func handleWebSocketData(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let type = json["type"] as? String ?? ""
        
        if type == "status", let statusData = json["data"] as? [String: Any] {
            if let jsonData = try? JSONSerialization.data(withJSONObject: statusData) {
                let decoded = try? JSONDecoder().decode(BotStatus.self, from: jsonData)
                DispatchQueue.main.async {
                    self.status = decoded
                    self.lastConnectionTime = Date()
                    self.isConnected = true
                    self.connectionError = nil
                }
            }
        } else if type == "log", let logMsg = json["data"] as? String {
            let entry = LogEntry(text: logMsg, timestamp: Date())
            DispatchQueue.main.async {
                self.logs.append(entry)
                // Keep last 500 logs
                if self.logs.count > 500 {
                    self.logs.removeFirst(self.logs.count - 500)
                }
            }
        }
    }
    
    private func attemptReconnect() {
        reconnectAttempts += 1
        let delay = min(5 * reconnectAttempts, 30)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + TimeInterval(delay)) { [weak self] in
            self?.connectWebSocket()
        }
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
                self.connectionError = "Failed to fetch status: \(error.localizedDescription)"
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
    
    func getConnectionStatusText() -> String {
        if !isConnected {
            if let error = connectionError {
                return "Disconnected: \(error)"
            }
            return "Disconnected"
        }
        if let lastTime = lastConnectionTime {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            return "Connected · Last update \(formatter.localizedString(for: lastTime, relativeTo: Date()))"
        }
        return "Connected"
    }
}

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
    
    private var webSocketTask: URLSessionWebSocketTask?
    private var reconnectTimer: Timer?
    private var isConnecting = false
    
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
        
        // Cancel existing connection and reconnect with new settings
        webSocketTask?.cancel()
        webSocketTask = nil
        
        // Use a delay to let UserDefaults flush
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.connectWebSocket()
        }
    }
    
    func connectWebSocket() {
        // Prevent multiple simultaneous connection attempts
        guard !isConnecting else { return }
        
        // Cancel existing connection
        webSocketTask?.cancel()
        webSocketTask = nil
        
        guard !ipAddress.isEmpty else {
            connectionError = "No IP address set. Go to Settings to configure."
            return
        }
        
        isConnecting = true
        connectionError = nil
        
        let urlString = "ws://\(ipAddress):8080/ws"
        guard let url = URL(string: urlString) else {
            connectionError = "Invalid IP address"
            isConnecting = false
            return
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        
        webSocketTask = URLSession.shared.webSocketTask(with: request)
        webSocketTask?.resume()
        
        // Check connection status after 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self = self else { return }
            if !self.isConnected {
                self.isConnecting = false
                self.connectionError = "Failed to connect. Check IP address and that backend is running."
                self.scheduleReconnect()
            }
        }
        
        receiveWebSocket()
    }
    
    private func receiveWebSocket() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                self.isConnecting = false
                
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
                
                // Connection is alive, keep receiving
                self.receiveWebSocket()
                
            case .failure(let error):
                DispatchQueue.main.async {
                    self.isConnected = false
                    self.isConnecting = false
                    self.connectionError = "Connection lost: \(error.localizedDescription)"
                }
                self.scheduleReconnect()
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
                if self.logs.count > 500 {
                    self.logs.removeFirst(self.logs.count - 500)
                }
            }
        }
    }
    
    private func scheduleReconnect() {
        // Cancel any existing reconnect timer
        reconnectTimer?.invalidate()
        
        // Schedule reconnect after 10 seconds (not 5, to avoid spam)
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
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

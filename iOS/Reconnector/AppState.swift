import Foundation
import Combine

class AppState: ObservableObject {
    @Published var ipAddress: String = UserDefaults.standard.string(forKey: "ipAddress") ?? ""
    @Published var authToken: String = UserDefaults.standard.string(forKey: "authToken") ?? ""
    @Published var status: BotStatus?
    @Published var logs: [LogEntry] = []
    @Published var isConnected: Bool = false
    @Published var screenshotImage: UIImage?
    
    private var webSocketTask: URLSessionWebSocketTask?
    private var statusTask: Task<Void, Never>?
    
    init() {
        connectWebSocket()
    }
    
    func saveSettings() {
        UserDefaults.standard.set(ipAddress, forKey: "ipAddress")
        UserDefaults.standard.set(authToken, forKey: "authToken")
        connectWebSocket()
    }
    
    func connectWebSocket() {
        webSocketTask?.cancel()
        guard !ipAddress.isEmpty else { return }
        
        let url = URL(string: "ws://\(ipAddress):8080/ws")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        
        webSocketTask = URLSession.shared.webSocketTask(with: request)
        webSocketTask?.resume()
        isConnected = true
        receiveWebSocket()
    }
    
    private func receiveWebSocket() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .data(let data):
                    self?.handleWebSocketData(data)
                case .string(let text):
                    if let data = text.data(using: .utf8) {
                        self?.handleWebSocketData(data)
                    }
                @unknown default:
                    break
                }
                self?.receiveWebSocket()
            case .failure:
                DispatchQueue.main.async { self?.isConnected = false }
                self?.attemptReconnect()
            }
        }
    }
    
    private func handleWebSocketData(_ data: Data) {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let type = json["type"] as? String ?? ""
            
            if type == "status", let statusData = json["data"] as? [String: Any] {
                if let jsonData = try? JSONSerialization.data(withJSONObject: statusData) {
                    let decoded = try? JSONDecoder().decode(BotStatus.self, from: jsonData)
                    DispatchQueue.main.async { self?.status = decoded }
                }
            } else if type == "log", let logMsg = json["data"] as? String {
                let entry = LogEntry(text: logMsg, timestamp: Date())
                DispatchQueue.main.async { self?.logs.append(entry) }
            }
        }
    }
    
    private func attemptReconnect() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.connectWebSocket()
        }
    }
    
    func fetchStatus() async {
        guard !ipAddress.isEmpty else { return }
        let client = APIClient(ipAddress: ipAddress, authToken: authToken)
        do {
            let s = try await client.getStatus()
            DispatchQueue.main.async { self.status = s }
        } catch {
            print("Failed to fetch status: \(error)")
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
}

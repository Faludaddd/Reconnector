import Foundation
import Combine

class AppState: ObservableObject {
    @Published var ipAddress: String = UserDefaults.standard.string(forKey: "ipAddress") ?? ""
    @Published var authToken: String = UserDefaults.standard.string(forKey: "authToken") ?? ""
    @Published var status: BotStatus?
    @Published var logs: [String] = []
    @Published var isConnected: Bool = false
    
    private var webSocketTask: URLSessionWebSocketTask?
    
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
        
        receiveWebSocket()
    }
    
    private func receiveWebSocket() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .data(let data):
                    if let status = try? JSONDecoder().decode(BotStatus.self, from: data) {
                        DispatchQueue.main.async { self?.status = status }
                    }
                case .string(let text):
                    DispatchQueue.main.async { self?.logs.append(text) }
                @unknown default:
                    break
                }
                self?.receiveWebSocket()
            case .failure:
                DispatchQueue.main.async { self?.isConnected = false }
            }
        }
    }
}

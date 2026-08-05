import Foundation

class APIClient {
    let ipAddress: String
    let authToken: String
    
    init(ipAddress: String, authToken: String) {
        self.ipAddress = ipAddress
        self.authToken = authToken
    }
    
    private func makeRequest(path: String, method: String = "GET") -> URLRequest {
        let url = URL(string: "http://\(ipAddress):8080\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
    
    func getStatus() async throws -> BotStatus {
        let request = makeRequest(path: "/api/status")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(BotStatus.self, from: data)
    }
    
    func restart() async throws {
        let request = makeRequest(path: "/api/restart", method: "POST")
        let (_, _) = try await URLSession.shared.data(for: request)
    }
    
    func toggleWatchdog() async throws {
        let request = makeRequest(path: "/api/watchdog/toggle", method: "POST")
        let (_, _) = try await URLSession.shared.data(for: request)
    }
    
    func clearAntiLoop() async throws {
        let request = makeRequest(path: "/api/clear-anti-loop", method: "POST")
        let (_, _) = try await URLSession.shared.data(for: request)
    }
    
    func activateBlackScreen() async throws {
        let request = makeRequest(path: "/api/black-screen", method: "POST")
        let (_, _) = try await URLSession.shared.data(for: request)
    }
    
    func setBrightness(level: Int) async throws {
        let request = makeRequest(path: "/api/brightness/\(level)", method: "POST")
        let (_, _) = try await URLSession.shared.data(for: request)
    }
    
    func setGameLink(url: String) async throws {
        var request = makeRequest(path: "/api/game-link", method: "POST")
        let body = ["url": url]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, _) = try await URLSession.shared.data(for: request)
    }
    
    func setInterval(minutes: Int) async throws {
        let request = makeRequest(path: "/api/interval/\(minutes)", method: "POST")
        let (_, _) = try await URLSession.shared.data(for: request)
    }
    
    func toggleOptimization(name: String, enabled: Bool) async throws {
        var request = makeRequest(path: "/api/optimize/\(name)?enabled=\(enabled)", method: "POST")
        let (_, _) = try await URLSession.shared.data(for: request)
    }
}

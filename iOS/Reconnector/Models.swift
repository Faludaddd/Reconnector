import Foundation

struct BotStatus: Codable {
    var roblox_state: String
    var roblox_running: Bool
    var battery: Int
    var cpu_temp: Double?
    var ram_total: Int?
    var ram_free: Int?
    var uptime: Int?
    var internet: Bool?
    var crashes_today: Int
    var kicks_today: Int
    var network_drops: Int?
    var watchdog_enabled: Bool
    var is_paused: Bool
    var interval: Int
    var game_link: String
    var brightness: Int
    var last_crash_reason: String?
    var last_reconnect: Int?
    var bot_uptime: Int?
    var optimizations: Optimizations
}

struct Optimizations: Codable {
    var kill_bg: Bool
    var process_limit: Bool
    var no_animations: Bool
    var force_gpu: Bool
    var no_bluetooth: Bool
}

struct LogEntry: Identifiable {
    let id = UUID()
    let text: String
    let timestamp: Date
}

struct CrashEntry: Codable, Identifiable {
    var id: String { "\(timestamp)" }
    let timestamp: Int
    let reason: String
}

struct CrashResponse: Codable {
    let crashes: [CrashEntry]
}

struct ScreenshotResponse: Codable {
    let image: String
    let error: String?
}

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
        request.timeoutInterval = 15
        return request
    }
    
    func getStatus() async throws -> BotStatus {
        let request = makeRequest(path: "/api/status")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(BotStatus.self, from: data)
    }
    
    func getCrashes() async throws -> CrashResponse {
        let request = makeRequest(path: "/api/crashes")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(CrashResponse.self, from: data)
    }
    
    func getScreenshot() async throws -> ScreenshotResponse {
        let request = makeRequest(path: "/api/screenshot")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(ScreenshotResponse.self, from: data)
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
        var request = makeRequest(path: "/api/optimize/\(name)", method: "POST")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["enabled": enabled])
        let (_, _) = try await URLSession.shared.data(for: request)
    }
}

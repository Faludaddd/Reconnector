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
    var brightness: Int?
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

struct VideoResponse: Codable {
    let video: String
    let error: String?
}

struct GenericResponse: Codable {
    let status: String?
    let enabled: Bool?
    let interval: Int?
    let game_link: String?
    let name: String?
    let optimizations: Optimizations?
    let estimated_seconds: Int?
    let error: String?
}

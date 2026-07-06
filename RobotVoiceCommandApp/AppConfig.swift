import Foundation

enum AppConfig {
    static let defaultJetsonIP = "192.168.1.100"
    static let defaultToken = "change_this_token"
    static let defaultPort = 8080
    static let commandPath = "/command"
    static let statusPath = "/status"
    static let commandSource = "iphone"
    static let stopCurrentTaskCommand = "STOP_CURRENT_TASK"
    static let stopCurrentSubtaskCommand = "STOP_CURRENT_SUBTASK"
    static let pauseCurrentSubtaskCommand = "PAUSE_CURRENT_SUBTASK"
}

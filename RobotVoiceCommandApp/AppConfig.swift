import Foundation

enum AppConfig {
    static let defaultJetsonIP = "192.168.8.150"
    static let defaultToken = "2001"
    static let defaultPort = 8080
    static let commandPath = "/command"
    static let batteryPath = "/battery"
    static let statusPath = "/status"
    static let commandSource = "iphone"
    static let stopCurrentTaskCommand = "STOP_CURRENT_TASK"
    static let stopCurrentSubtaskCommand = "STOP_CURRENT_SUBTASK"
    static let pauseCurrentSubtaskCommand = "PAUSE_CURRENT_SUBTASK"
    static let armRelaxCommand = "ARM_RELAX"
    static let armButtonCommand = "ARM_BUTTON"
    static let armPressCommand = "ARM_PRESS"
}

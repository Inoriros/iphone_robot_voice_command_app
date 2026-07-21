import Foundation

enum AppConfig {
    static let defaultJetsonIP = "192.168.8.150"
    static let defaultToken = "2001"
    static let defaultPort = 8080
    static let commandPath = "/command"
    static let batteryPath = "/battery"
    static let manualControlPath = "/manual_control"
    static let manualVelocityPath = "/manual_velocity"
    static let bodyHeightPath = "/body_height"
    static let robotModePath = "/robot_mode"
    static let controlSourcePath = "/control_source"
    static let statusPath = "/status"
    static let commandSource = "iphone"
    static let defaultManualControlAxisRangeMeters = 2.0
    static let minimumManualControlAxisRangeMeters = 2.0
    static let maximumManualControlAxisRangeMeters = 6.0
    static let minimumBodyHeightMeters = -0.20
    static let maximumBodyHeightMeters = 0.20
    static let stopCurrentTaskCommand = "STOP_CURRENT_TASK"
    static let stopCurrentSubtaskCommand = "STOP_CURRENT_SUBTASK"
    static let pauseCurrentSubtaskCommand = "PAUSE_CURRENT_SUBTASK"
    static let armRelaxCommand = "ARM_RELAX"
    static let armButtonCommand = "ARM_BUTTON"
    static let armPressCommand = "ARM_PRESS"
}

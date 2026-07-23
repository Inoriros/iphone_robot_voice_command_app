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
    static let minimumDriveJoystickThrottle = 1.0
    static let defaultDriveJoystickThrottle = 1.5
    static let maximumDriveJoystickThrottle = 2.0
    static let minimumBodyHeightMeters = -0.20
    static let maximumBodyHeightMeters = 0.20
    static let armStatusBufferLimit = 100
    static let armCommandAcceptanceTimeoutSeconds = 10.0
    static let armCommandExecutionTimeoutSeconds = 180.0
    static let stopCurrentTaskCommand = "STOP_CURRENT_TASK"
    static let stopCurrentSubtaskCommand = "STOP_CURRENT_SUBTASK"
    static let pauseCurrentSubtaskCommand = "PAUSE_CURRENT_SUBTASK"
    static let armRelaxCommand = "ARM_RELAX"
    static let armButtonCommand = "ARM_BUTTON"
    static let armPressCommand = "ARM_PRESS"
    static let armObserveHigherCommand = "ARM_OBSERVE_HIGHER"
    static let armObserveBottleCommand = "ARM_OBSERVE_BOTTLE"
    static let armGraspBottleCommand = "ARM_GRASP_BOTTLE"
    static let armReleaseBottleCommand = "ARM_RELEASE_BOTTLE"
    static let armPlaceDownBottleCommand = "ARM_PLACE_DOWN_BOTTLE"

    private static let armActionNamesByCommand = [
        armRelaxCommand: "move_to_relax",
        armButtonCommand: "move_to_button",
        armPressCommand: "move_to_press",
        armObserveHigherCommand: "move_to_high_button",
        armObserveBottleCommand: "move_to_bottle",
        armGraspBottleCommand: "grasp_water_bottle",
        armReleaseBottleCommand: "release_bottle",
        armPlaceDownBottleCommand: "place_down_bottle",
    ]

    static func armActionName(for command: String) -> String? {
        armActionNamesByCommand[command.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()]
    }
}

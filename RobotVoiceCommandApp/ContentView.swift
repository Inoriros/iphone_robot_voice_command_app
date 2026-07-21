import SwiftUI

private enum HeldRobotMotion: Equatable {
    case forward
    case backward
    case left
    case right
    case turnLeft
    case turnRight

    var command: (forward: Double, strafe: Double, yaw: Double) {
        switch self {
        case .forward: return (1, 0, 0)
        case .backward: return (-1, 0, 0)
        case .left: return (0, 1, 0)
        case .right: return (0, -1, 0)
        case .turnLeft: return (0, 0, 1)
        case .turnRight: return (0, 0, -1)
        }
    }
}

private struct DriveJoystickCommand: Equatable {
    let forward: Double
    let yaw: Double

    static let zero = DriveJoystickCommand(forward: 0, yaw: 0)
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var speech = SpeechRecognizer()
    @StateObject private var robot = RobotClient()

    @State private var jetsonIP = AppConfig.defaultJetsonIP
    @State private var token = AppConfig.defaultToken
    @State private var commandText = ""
    @State private var selectedWaypointYawRadians = 0.0
    @State private var heldRobotMotion: HeldRobotMotion?
    @State private var heldMotionTask: Task<Void, Never>?
    @State private var driveJoystickOffset = CGSize.zero
    @State private var driveJoystickCommand = DriveJoystickCommand.zero
    @State private var driveJoystickActive = false
    @State private var driveJoystickRefreshTask: Task<Void, Never>?
    @State private var selectedWaypointLocation: CGPoint?
    @State private var selectedWaypointX = 0.0
    @State private var selectedWaypointY = 0.0
    @State private var selectedBodyHeightMeters = 0.0
    @AppStorage("manualControlAxisRangeMeters") private var waypointRangeMeters =
        AppConfig.defaultManualControlAxisRangeMeters

    private var trimmedCommand: String {
        commandText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSendCommand: Bool {
        !trimmedCommand.isEmpty && !jetsonIP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSendControlCommand: Bool {
        !jetsonIP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canCheckBattery: Bool {
        canSendControlCommand && !robot.isCheckingBattery
    }

    private var canUsePhoneControl: Bool {
        canSendControlCommand
            && robot.connectionState == "Connected"
            && robot.phoneControlEnabled
            && !robot.isSendingManualControl
    }

    private var canUseDirectControl: Bool {
        canSendControlCommand
            && robot.connectionState == "Connected"
            && robot.phoneControlEnabled
    }

    private var canSetBodyHeight: Bool {
        canUsePhoneControl
            && heldRobotMotion == nil
            && !robot.isSendingBodyHeight
            && !driveJoystickActive
    }

    private var canUseWaypointControl: Bool {
        canUsePhoneControl
            && heldRobotMotion == nil
            && !driveJoystickActive
    }

    private var canSwitchControlSource: Bool {
        canSendControlCommand
            && robot.connectionState == "Connected"
            && robot.appSourceControlEnabled
            && !robot.isSendingControlSource
    }

    private var canSwitchRobotMode: Bool {
        canSendControlCommand
            && robot.connectionState == "Connected"
            && robot.appModeControlEnabled
            && !robot.isSendingRobotMode
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    connectionSection
                    batterySection
                    statusSection
                    commandSection
                    taskPlanSection
                    subtaskProofSection
                    stopControlsSection
                    armControlsSection
                    phoneControlSection
                    feedbackSection
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Robot Voice Command")
            .task {
                speech.requestPermissions()
            }
            .onChange(of: speech.transcript) { _, newTranscript in
                if speech.isRecording {
                    commandText = newTranscript
                }
            }
            .onChange(of: robot.phoneControlEnabled) { _, enabled in
                if !enabled {
                    stopAllDirectMotion()
                }
            }
            .onChange(of: robot.bodyHeightMeters) { _, height in
                if !robot.isSendingBodyHeight {
                    selectedBodyHeightMeters = height
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    stopAllDirectMotion()
                }
            }
            .onDisappear {
                stopAllDirectMotion()
            }
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Robot Connection")
                .font(.headline)

            TextField("Jetson IP", text: $jetsonIP)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)

            SecureField("Token", text: $token)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)

            HStack {
                Label(robot.connectionState, systemImage: connectionIconName)
                    .font(.subheadline)
                    .foregroundStyle(connectionColor)

                Spacer()

                Button {
                    robot.connectStatusWebSocket(ip: jetsonIP)
                } label: {
                    Label("Connect", systemImage: "antenna.radiowaves.left.and.right")
                }
                .buttonStyle(.bordered)

                Button {
                    robot.disconnectStatusWebSocket()
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Disconnect")
            }
        }
    }

    private var batterySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Spot Battery")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Label {
                        Text(
                            robot.batteryMessage
                                ?? (robot.isCheckingBattery
                                    ? "Checking Spot battery…"
                                    : "Battery not checked yet")
                        )
                        .font(.body)
                    } icon: {
                        Image(systemName: batteryIconName)
                    }
                    .foregroundStyle(batteryColor)

                    Spacer()

                    Button {
                        robot.checkBattery(ip: jetsonIP, token: token)
                    } label: {
                        HStack(spacing: 6) {
                            if robot.isCheckingBattery {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text(robot.isCheckingBattery ? "Checking…" : "Check Battery")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canCheckBattery)
                }

                if let percentage = robot.batteryPercentage {
                    ProgressView(value: min(max(percentage, 0), 100), total: 100)
                        .tint(batteryColor)
                        .accessibilityLabel("Spot battery level")
                        .accessibilityValue("\(percentage.formatted()) percent")
                }
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Current Task Status")
                .font(.headline)

            VStack(alignment: .leading, spacing: 10) {
                Text(robot.currentStatusText)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let status = robot.lastStatus {
                    metadataRows(for: status)

                    if let progress = status.progress {
                        ProgressView(value: clampedProgress(progress)) {
                            Text("Progress")
                                .font(.caption)
                        }
                    }
                }
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private var commandSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recognized Command")
                    .font(.headline)

                Spacer()

                Label(speech.authorizationStatusText, systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextEditor(text: $commandText)
                .frame(minHeight: 140)
                .padding(6)
                .scrollContentBackground(.hidden)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(.separator), lineWidth: 0.5)
                )

            HStack(spacing: 12) {
                Button {
                    if speech.isRecording {
                        speech.stopRecording()
                    } else {
                        speech.startRecording()
                    }
                } label: {
                    Label(
                        speech.isRecording ? "Stop Listening" : "Start Listening",
                        systemImage: speech.isRecording ? "stop.circle.fill" : "mic.circle.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    robot.sendCommand(ip: jetsonIP, token: token, text: trimmedCommand)
                } label: {
                    Label("Send", systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!canSendCommand)

                Button {
                    speech.stopRecording()
                    speech.resetTranscript()
                    commandText = ""
                } label: {
                    Image(systemName: "trash")
                        .frame(minWidth: 36)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Clear")
            }
        }
    }

    @ViewBuilder
    private var taskPlanSection: some View {
        if let taskPlan = robot.latestTaskPlanText, !taskPlan.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Task Plan")
                    .font(.headline)
                Text(taskPlan)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private var subtaskProofSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Subtask Proof")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Label("Image Proof", systemImage: "photo")
                    .font(.subheadline.weight(.semibold))

                if let imageData = robot.latestEvidenceImageData,
                   let image = UIImage(data: imageData) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    if let format = robot.latestEvidenceImageFormat, !format.isEmpty {
                        Text("Format: \(format)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    proofPlaceholder("Waiting for image proof", systemImage: "clock")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Prompt Proof", systemImage: "text.quote")
                    .font(.subheadline.weight(.semibold))

                if let promptEvidence = robot.latestPromptEvidenceText,
                   !promptEvidence.isEmpty {
                    Text(promptEvidence)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    proofPlaceholder("Waiting for prompt proof", systemImage: "clock")
                }
            }
        }
    }

    private func proofPlaceholder(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var stopControlsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Task Controls")
                .font(.headline)

            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Button(role: .destructive) {
                        sendFixedCommand(AppConfig.stopCurrentTaskCommand)
                    } label: {
                        Label("Stop Task", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(!canSendControlCommand)

                    Button(role: .destructive) {
                        sendFixedCommand(AppConfig.stopCurrentSubtaskCommand)
                    } label: {
                        Label("Stop Subtask", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(!canSendControlCommand)
                }

                GridRow {
                    Button {
                        sendFixedCommand(AppConfig.pauseCurrentSubtaskCommand)
                    } label: {
                        Label("Pause Subtask", systemImage: "pause.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(!canSendControlCommand)
                    .gridCellColumns(2)
                }
            }
        }
    }

    private var armControlsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Robot Arm")
                .font(.headline)

            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Button {
                        sendFixedCommand(AppConfig.armRelaxCommand)
                    } label: {
                        Label("Relax", systemImage: "hand.raised")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(!canSendControlCommand)

                    Button {
                        sendFixedCommand(AppConfig.armButtonCommand)
                    } label: {
                        Label("Move to Button", systemImage: "scope")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(!canSendControlCommand)
                }

                GridRow {
                    Button {
                        sendFixedCommand(AppConfig.armPressCommand)
                    } label: {
                        Label("Press Button", systemImage: "hand.tap")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(!canSendControlCommand)
                    .gridCellColumns(2)
                }
            }
        }
    }

    private var phoneControlSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Phone Robot Control")
                    .font(.headline)

                Spacer()

                Label(phoneControlStatusText, systemImage: phoneControlStatusIcon)
                    .font(.caption)
                    .foregroundStyle(phoneControlStatusColor)
            }

            Text("SBUS owns the control source and robot mode whenever it is available. If it disconnects, the app can temporarily select both; phone motion requires the Phone source and WALK mode.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 16) {
                controlSourceController

                Divider()

                robotModeController

                Divider()

                standingHeightController

                Divider()

                rotationController

                Divider()

                directMovementController

                Divider()

                driveJoystickController

                Divider()

                waypointController

                if let message = robot.manualControlMessage {
                    Label(message, systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.green)
                }

                if let message = robot.bodyHeightMessage {
                    Label(message, systemImage: "arrow.up.and.down.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.green)
                }

                if let message = robot.controlSourceMessage {
                    Label(message, systemImage: "switch.2")
                        .font(.footnote)
                        .foregroundStyle(.green)
                }

                if let message = robot.robotModeMessage {
                    Label(message, systemImage: "switch.2")
                        .font(.footnote)
                        .foregroundStyle(.green)
                }
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private var controlSourceController: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Control Source")
                    .font(.subheadline.weight(.semibold))

                Spacer()

                if robot.isSendingControlSource {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            HStack(spacing: 8) {
                controlSourceButton("waypoint", label: "Navigation", icon: "map.fill")
                controlSourceButton("hold", label: "Stop", icon: "stop.fill")
                controlSourceButton("sbus", label: "Phone", icon: "iphone")
            }

            Text(controlSourceAvailabilityText)
                .font(.caption)
                .foregroundStyle(
                    robot.appSourceControlEnabled ? Color.orange : Color.secondary
                )
        }
    }

    private func controlSourceButton(
        _ sourceMode: String,
        label: String,
        icon: String
    ) -> some View {
        Button {
            robot.sendControlSource(
                ip: jetsonIP,
                token: token,
                sourceMode: sourceMode
            )
        } label: {
            Label(label, systemImage: icon)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(robot.controlSource == sourceMode ? Color.accentColor : Color.secondary)
        .disabled(!canSwitchControlSource)
    }

    private var robotModeController: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Robot Mode")
                    .font(.subheadline.weight(.semibold))

                Spacer()

                if robot.isSendingRobotMode {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            HStack(spacing: 8) {
                robotModeButton("sit", label: "Sit", icon: "arrow.down.to.line")
                robotModeButton("stand", label: "Stand", icon: "figure.stand")
                robotModeButton("walk", label: "Walk", icon: "figure.walk")
            }

            Text(robotModeAvailabilityText)
                .font(.caption)
                .foregroundStyle(
                    robot.appModeControlEnabled ? Color.orange : Color.secondary
                )
        }
    }

    private func robotModeButton(
        _ mode: String,
        label: String,
        icon: String
    ) -> some View {
        Button {
            robot.sendRobotMode(ip: jetsonIP, token: token, mode: mode)
        } label: {
            Label(label, systemImage: icon)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(
            (robot.sbusAvailable || robot.appModeOverrideActive) && robot.robotMode == mode
                ? Color.accentColor : Color.secondary
        )
        .disabled(!canSwitchRobotMode)
    }

    private var standingHeightController: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("1. Standing Height")
                    .font(.subheadline.weight(.semibold))

                Spacer()

                if robot.isSendingBodyHeight {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Text("Set Spot's body-height offset relative to its nominal stand. Applying a height stops active phone motion first.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Text("-20 cm")
                    .font(.caption2.monospacedDigit())

                Slider(
                    value: $selectedBodyHeightMeters,
                    in: AppConfig.minimumBodyHeightMeters...AppConfig.maximumBodyHeightMeters,
                    step: 0.02
                )

                Text("+20 cm")
                    .font(.caption2.monospacedDigit())
            }

            Text("Offset: \((selectedBodyHeightMeters * 100).formatted(.number.precision(.fractionLength(0)))) cm")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button {
                    selectedBodyHeightMeters = 0
                    sendSelectedBodyHeight()
                } label: {
                    Label("Nominal", systemImage: "arrow.uturn.backward")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    sendSelectedBodyHeight()
                } label: {
                    Label("Apply Height", systemImage: "arrow.up.and.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .disabled(!canSetBodyHeight)
            .opacity(canSetBodyHeight ? 1 : 0.45)
        }
    }

    private var rotationController: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("2. Direct Rotation")
                .font(.subheadline.weight(.semibold))

            Text("Press and hold Left or Right. Releasing the button stops rotation.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                deadmanButton(.turnLeft, label: "Left", icon: "rotate.left")
                deadmanButton(.turnRight, label: "Right", icon: "rotate.right")
            }
        }
    }

    private var directMovementController: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("3. Direct Movement")
                .font(.subheadline.weight(.semibold))

            Text("Press and hold an arrow to move. Releasing it stops the robot.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                deadmanButton(.forward, label: "Forward", icon: "arrow.up")
                    .frame(maxWidth: 150)

                HStack(spacing: 12) {
                    deadmanButton(.left, label: "Left", icon: "arrow.left")
                    deadmanButton(.right, label: "Right", icon: "arrow.right")
                }

                deadmanButton(.backward, label: "Backward", icon: "arrow.down")
                    .frame(maxWidth: 150)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func deadmanButton(
        _ motion: HeldRobotMotion,
        label: String,
        icon: String
    ) -> some View {
        Button(action: {}) {
            Label(label, systemImage: icon)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 54)
        }
        .buttonStyle(.borderedProminent)
        .tint(heldRobotMotion == motion ? Color.orange : Color.accentColor)
        .opacity(canUseDirectControl ? 1 : 0.45)
        .onLongPressGesture(
            minimumDuration: 0,
            maximumDistance: .infinity,
            pressing: { isPressing in
                if isPressing {
                    beginHeldMotion(motion)
                } else {
                    endHeldMotion(motion)
                }
            },
            perform: {}
        )
        .disabled(!canUseDirectControl)
        .accessibilityHint("Press and hold to move; release to stop")
    }

    private var driveJoystickController: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("4. Drive Joystick")
                .font(.subheadline.weight(.semibold))

            Text("Drag up or down for throttle and left or right for steering. Diagonal drag moves and turns at the same time; releasing stops Spot.")
                .font(.caption)
                .foregroundStyle(.secondary)

            GeometryReader { geometry in
                let side = min(geometry.size.width, 240.0)
                let maximumTravel = max((side - 66.0) / 2.0, 1.0)

                ZStack {
                    Circle()
                        .fill(Color(.tertiarySystemGroupedBackground))

                    Circle()
                        .strokeBorder(Color.secondary.opacity(0.55), lineWidth: 2)

                    Rectangle()
                        .fill(Color.secondary.opacity(0.22))
                        .frame(width: 1)

                    Rectangle()
                        .fill(Color.secondary.opacity(0.22))
                        .frame(height: 1)

                    Image(systemName: "arrow.up")
                        .foregroundStyle(.secondary)
                        .position(x: side / 2, y: 18)

                    Image(systemName: "arrow.down")
                        .foregroundStyle(.secondary)
                        .position(x: side / 2, y: side - 18)

                    Image(systemName: "arrow.left")
                        .foregroundStyle(.secondary)
                        .position(x: 18, y: side / 2)

                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                        .position(x: side - 18, y: side / 2)

                    Circle()
                        .fill(driveJoystickActive ? Color.orange : Color.accentColor)
                        .frame(width: 66, height: 66)
                        .overlay(
                            Image(systemName: "steeringwheel")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(.white)
                        )
                        .shadow(color: .black.opacity(0.22), radius: 5, y: 3)
                        .offset(driveJoystickOffset)
                }
                .frame(width: side, height: side)
                .contentShape(Circle())
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            updateDriveJoystick(
                                at: value.location,
                                side: side,
                                maximumTravel: maximumTravel
                            )
                        }
                        .onEnded { _ in
                            stopDriveJoystick()
                        }
                )
                .opacity(canUseDirectControl ? 1 : 0.45)
                .allowsHitTesting(canUseDirectControl)
                .position(x: geometry.size.width / 2, y: side / 2)
            }
            .frame(height: 240)

            HStack {
                Label(
                    "Throttle \(Int((driveJoystickCommand.forward * 100).rounded()))%",
                    systemImage: "arrow.up.and.down"
                )

                Spacer()

                Label(
                    "Turn \(Int((driveJoystickCommand.yaw * 100).rounded()))%",
                    systemImage: "arrow.left.and.right"
                )
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            Text("This car-style joystick sends forward and yaw together; lateral strafe remains on the Left/Right buttons above.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var waypointController: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("5. Body-Relative Waypoint")
                .font(.subheadline.weight(.semibold))

            Text("Tap the square. Spot will face along the line from the center to the target.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Stepper(
                value: $waypointRangeMeters,
                in: AppConfig.minimumManualControlAxisRangeMeters...AppConfig.maximumManualControlAxisRangeMeters,
                step: 1
            ) {
                HStack {
                    Label("Waypoint Range", systemImage: "ruler")

                    Spacer()

                    Text("±\(waypointRangeMeters.formatted(.number.precision(.fractionLength(0)))) m")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            GeometryReader { geometry in
                let side = min(geometry.size.width, geometry.size.height)

                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(.tertiarySystemGroupedBackground))

                    Rectangle()
                        .fill(Color.secondary.opacity(0.35))
                        .frame(width: 1)
                    Rectangle()
                        .fill(Color.secondary.opacity(0.35))
                        .frame(height: 1)

                    Text("FORWARD")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .position(x: side / 2, y: 14)

                    if let location = selectedWaypointLocation {
                        Path { path in
                            path.move(to: CGPoint(x: side / 2, y: side / 2))
                            path.addLine(
                                to: CGPoint(x: location.x * side, y: location.y * side)
                            )
                        }
                        .stroke(
                            Color.accentColor.opacity(0.75),
                            style: StrokeStyle(lineWidth: 3, dash: [7, 5])
                        )
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 18, height: 18)
                            .position(x: location.x * side, y: location.y * side)
                    }

                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 42))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: side, height: side)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.secondary.opacity(0.6), lineWidth: 1)
                )
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture()
                        .onEnded { value in
                            sendWaypointTap(at: value.location, side: side)
                        }
                )
                .opacity(robot.phoneControlEnabled ? 1 : 0.45)
                .allowsHitTesting(canUsePhoneControl)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
            .aspectRatio(1, contentMode: .fit)

            Text("Each axis spans the selected ±\(waypointRangeMeters.formatted(.number.precision(.fractionLength(0)))) m")
                .font(.caption)
                .foregroundStyle(.secondary)

            if selectedWaypointLocation != nil {
                Text("Last goal: forward \(selectedWaypointX.formatted(.number.precision(.fractionLength(2)))) m, left \(selectedWaypointY.formatted(.number.precision(.fractionLength(2)))) m, yaw \(selectedWaypointYawDegrees)°")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var feedbackSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let commandMessage = robot.lastCommandMessage {
                Label(commandMessage, systemImage: robot.lastCommandSendSucceeded ? "checkmark.circle.fill" : "info.circle")
                    .foregroundStyle(robot.lastCommandSendSucceeded ? .green : .secondary)
            }

            if let speechError = speech.errorMessage {
                Label(speechError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

            if let robotError = robot.lastError {
                Label(robotError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
        .font(.footnote)
    }

    private var connectionIconName: String {
        switch robot.connectionState {
        case "Connected":
            return "checkmark.circle.fill"
        case "Connecting":
            return "clock"
        case "Error":
            return "exclamationmark.triangle.fill"
        default:
            return "circle"
        }
    }

    private var connectionColor: Color {
        switch robot.connectionState {
        case "Connected":
            return .green
        case "Connecting":
            return .orange
        case "Error":
            return .red
        default:
            return .secondary
        }
    }

    private var batteryIconName: String {
        guard let percentage = robot.batteryPercentage else {
            return "battery.0percent"
        }

        switch percentage {
        case 75...:
            return "battery.100percent"
        case 50..<75:
            return "battery.75percent"
        case 25..<50:
            return "battery.50percent"
        case 1..<25:
            return "battery.25percent"
        default:
            return "battery.0percent"
        }
    }

    private var batteryColor: Color {
        guard let percentage = robot.batteryPercentage else {
            return .secondary
        }

        switch percentage {
        case 50...:
            return .green
        case 20..<50:
            return .orange
        default:
            return .red
        }
    }

    private var phoneControlStatusText: String {
        if robot.phoneControlEnabled {
            return "\(robot.controlAuthority.uppercased()) • WALK"
        }
        if robot.appSourceControlEnabled {
            let modeText = robot.appModeOverrideActive ? robot.robotMode.uppercased() : "NO MODE"
            return "APP • \(robot.controlSource.uppercased()) • \(modeText)"
        }
        if robot.controlSource == "unknown" {
            return "Waiting for status"
        }
        return "\(robot.controlSource.uppercased()) • \(robot.robotMode.uppercased())"
    }

    private var phoneControlStatusIcon: String {
        if robot.phoneControlEnabled {
            return "checkmark.circle.fill"
        }
        return robot.appSourceControlEnabled ? "switch.2" : "lock.fill"
    }

    private var phoneControlStatusColor: Color {
        if robot.phoneControlEnabled {
            return .green
        }
        return robot.appSourceControlEnabled ? .orange : .secondary
    }

    private var controlSourceAvailabilityText: String {
        if robot.connectionState != "Connected" {
            return "Connect the live status stream to check source authority."
        }
        if robot.sbusAvailable {
            return "SBUS is connected; the physical control-source switch has priority."
        }
        if robot.appSourceControlEnabled {
            return "SBUS is unavailable. Select Navigation, Stop, or Phone from the app."
        }
        return "Waiting for control-source authority."
    }

    private var robotModeAvailabilityText: String {
        if robot.connectionState != "Connected" {
            return "Connect the live status stream to check mode authority."
        }
        if robot.sbusAvailable {
            return "SBUS is connected; the physical mode switch has priority."
        }
        if robot.appModeControlEnabled {
            return "SBUS is unavailable. Select SIT, STAND, or WALK from the app."
        }
        return "Waiting for robot mode authority."
    }

    private var selectedWaypointYawDegrees: Int {
        Int((selectedWaypointYawRadians * 180 / Double.pi).rounded())
    }

    private func beginHeldMotion(_ motion: HeldRobotMotion) {
        guard canUseDirectControl, heldRobotMotion != motion else { return }
        if driveJoystickActive || driveJoystickRefreshTask != nil {
            stopDriveJoystick()
        }
        heldMotionTask?.cancel()
        heldRobotMotion = motion
        sendHeldMotion(motion)
        heldMotionTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled,
                      heldRobotMotion == motion,
                      canUseDirectControl else {
                    return
                }
                sendHeldMotion(motion)
            }
        }
    }

    private func endHeldMotion(_ motion: HeldRobotMotion) {
        guard heldRobotMotion == motion else { return }
        stopHeldMotion()
    }

    private func stopHeldMotion() {
        guard heldRobotMotion != nil || heldMotionTask != nil else { return }
        heldMotionTask?.cancel()
        heldMotionTask = nil
        heldRobotMotion = nil
        sendStopVelocity()
    }

    private func sendHeldMotion(_ motion: HeldRobotMotion) {
        let command = motion.command
        robot.sendManualVelocity(
            ip: jetsonIP,
            token: token,
            forward: command.forward,
            strafe: command.strafe,
            yaw: command.yaw
        )
    }

    private func updateDriveJoystick(
        at location: CGPoint,
        side: CGFloat,
        maximumTravel: CGFloat
    ) {
        guard canUseDirectControl, side > 0, maximumTravel > 0 else {
            stopDriveJoystick()
            return
        }

        if heldRobotMotion != nil || heldMotionTask != nil {
            stopHeldMotion()
        }

        let center = side / 2
        var offsetX = location.x - center
        var offsetY = location.y - center
        let distance = (offsetX * offsetX + offsetY * offsetY).squareRoot()
        if distance > maximumTravel {
            let scale = maximumTravel / distance
            offsetX *= scale
            offsetY *= scale
        }

        driveJoystickOffset = CGSize(width: offsetX, height: offsetY)
        driveJoystickCommand = DriveJoystickCommand(
            forward: driveAxisValue(-Double(offsetY / maximumTravel)),
            yaw: driveAxisValue(-Double(offsetX / maximumTravel))
        )
        driveJoystickActive = true
        sendDriveJoystickCommand()
        startDriveJoystickRefresh()
    }

    private func driveAxisValue(_ rawValue: Double) -> Double {
        let clampedValue = min(max(rawValue, -1), 1)
        let deadzone = 0.08
        guard abs(clampedValue) > deadzone else { return 0 }
        let magnitude = (abs(clampedValue) - deadzone) / (1 - deadzone)
        return clampedValue < 0 ? -magnitude : magnitude
    }

    private func startDriveJoystickRefresh() {
        guard driveJoystickRefreshTask == nil else { return }
        driveJoystickRefreshTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled,
                      driveJoystickActive,
                      canUseDirectControl else {
                    return
                }
                sendDriveJoystickCommand()
            }
        }
    }

    private func sendDriveJoystickCommand() {
        robot.sendManualVelocity(
            ip: jetsonIP,
            token: token,
            forward: driveJoystickCommand.forward,
            strafe: 0,
            yaw: driveJoystickCommand.yaw
        )
    }

    private func stopDriveJoystick() {
        guard driveJoystickActive || driveJoystickRefreshTask != nil else { return }
        driveJoystickRefreshTask?.cancel()
        driveJoystickRefreshTask = nil
        driveJoystickActive = false
        driveJoystickOffset = .zero
        driveJoystickCommand = .zero
        sendStopVelocity()
    }

    private func stopAllDirectMotion() {
        let shouldSendStop = heldRobotMotion != nil
            || heldMotionTask != nil
            || driveJoystickActive
            || driveJoystickRefreshTask != nil

        heldMotionTask?.cancel()
        heldMotionTask = nil
        heldRobotMotion = nil
        driveJoystickRefreshTask?.cancel()
        driveJoystickRefreshTask = nil
        driveJoystickActive = false
        driveJoystickOffset = .zero
        driveJoystickCommand = .zero

        if shouldSendStop {
            sendStopVelocity()
        }
    }

    private func sendStopVelocity() {
        robot.sendManualVelocity(
            ip: jetsonIP,
            token: token,
            forward: 0,
            strafe: 0,
            yaw: 0
        )
    }

    private func sendSelectedBodyHeight() {
        robot.sendBodyHeight(
            ip: jetsonIP,
            token: token,
            height: selectedBodyHeightMeters
        )
    }

    private func sendWaypointTap(at location: CGPoint, side: CGFloat) {
        guard side > 0, canUseWaypointControl else { return }

        let clampedX = min(max(location.x, 0), side)
        let clampedY = min(max(location.y, 0), side)
        let half = side / 2
        let range = waypointRangeMeters

        selectedWaypointLocation = CGPoint(
            x: clampedX / side,
            y: clampedY / side
        )
        selectedWaypointX = Double((half - clampedY) / half) * range
        selectedWaypointY = Double((half - clampedX) / half) * range
        selectedWaypointYawRadians = atan2(selectedWaypointY, selectedWaypointX)
        sendManualGoal(
            x: selectedWaypointX,
            y: selectedWaypointY,
            yaw: selectedWaypointYawRadians
        )
    }

    private func sendManualGoal(x: Double, y: Double, yaw: Double) {
        robot.sendManualControl(
            ip: jetsonIP,
            token: token,
            x: x,
            y: y,
            yaw: yaw
        )
    }

    @ViewBuilder
    private func metadataRows(for status: RobotStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let state = status.state, !state.isEmpty {
                labeledValue("State", state)
            }

            if let skill = status.skill, !skill.isEmpty {
                labeledValue("Skill", skill)
            }

            if let subtask = status.subtask, !subtask.isEmpty {
                labeledValue("Task", subtask)
            }

            if let timestamp = status.timestamp {
                labeledValue("Last update", formattedTimestamp(timestamp))
            }

            if let type = status.type, !type.isEmpty {
                labeledValue("Type", type)
            }

            if let topic = status.topic, !topic.isEmpty {
                labeledValue("Topic", topic)
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    private func labeledValue(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(label):")
                .fontWeight(.semibold)
            Text(value)
        }
    }

    private func clampedProgress(_ progress: Double) -> Double {
        min(max(progress, 0), 1)
    }

    private func sendFixedCommand(_ text: String) {
        speech.stopRecording()
        commandText = text
        robot.sendCommand(ip: jetsonIP, token: token, text: text)
    }

    private func formattedTimestamp(_ timestamp: Double) -> String {
        let date = Date(timeIntervalSince1970: timestamp)
        return date.formatted(date: .omitted, time: .standard)
    }
}

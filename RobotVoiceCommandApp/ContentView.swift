import SwiftUI

struct ContentView: View {
    @StateObject private var speech = SpeechRecognizer()
    @StateObject private var robot = RobotClient()

    @State private var jetsonIP = AppConfig.defaultJetsonIP
    @State private var token = AppConfig.defaultToken
    @State private var commandText = ""
    @State private var manualHeadingRadians = 0.0
    @State private var selectedWaypointLocation: CGPoint?
    @State private var selectedWaypointX = 0.0
    @State private var selectedWaypointY = 0.0
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

                rotationController

                Divider()

                waypointController

                if let message = robot.manualControlMessage {
                    Label(message, systemImage: "checkmark.circle.fill")
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

    private var rotationController: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("1. Relative Rotation")
                .font(.subheadline.weight(.semibold))

            Text("Drag around the dial, then send the selected yaw.")
                .font(.caption)
                .foregroundStyle(.secondary)

            GeometryReader { geometry in
                let side = min(geometry.size.width, geometry.size.height)
                let knobRadius = side * 0.37

                ZStack {
                    Circle()
                        .fill(Color(.tertiarySystemGroupedBackground))
                    Circle()
                        .stroke(Color.accentColor.opacity(0.65), lineWidth: 3)

                    ForEach(0..<12, id: \.self) { tick in
                        Capsule()
                            .fill(Color.secondary)
                            .frame(width: 2, height: 9)
                            .offset(y: -side * 0.43)
                            .rotationEffect(.degrees(Double(tick) * 30))
                    }

                    Image(systemName: "location.north.fill")
                        .font(.system(size: side * 0.30, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                        .rotationEffect(.radians(-manualHeadingRadians))

                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 18, height: 18)
                        .offset(
                            x: -CGFloat(sin(manualHeadingRadians)) * knobRadius,
                            y: -CGFloat(cos(manualHeadingRadians)) * knobRadius
                        )
                }
                .frame(width: side, height: side)
                .contentShape(Circle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            updateManualHeading(at: value.location, side: side)
                        }
                )
                .opacity(robot.phoneControlEnabled ? 1 : 0.45)
                .allowsHitTesting(canUsePhoneControl)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
            .frame(height: 190)

            HStack {
                Text("Selected: \(manualHeadingDegrees)°")
                    .font(.subheadline.monospacedDigit())

                Spacer()

                Button {
                    sendManualGoal(x: 0, y: 0, yaw: manualHeadingRadians)
                } label: {
                    Label("Rotate", systemImage: "rotate.right")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canUsePhoneControl)
            }
        }
    }

    private var waypointController: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("2. Body-Relative Waypoint")
                .font(.subheadline.weight(.semibold))

            Text("Tap the square: up is forward and left is the robot's left. The center arrow is Spot.")
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
                Text("Last goal: forward \(selectedWaypointX.formatted(.number.precision(.fractionLength(2)))) m, left \(selectedWaypointY.formatted(.number.precision(.fractionLength(2)))) m, yaw \(manualHeadingDegrees)°")
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

    private var manualHeadingDegrees: Int {
        Int((manualHeadingRadians * 180 / Double.pi).rounded())
    }

    private func updateManualHeading(at location: CGPoint, side: CGFloat) {
        let center = side / 2
        let left = center - location.x
        let forward = center - location.y
        guard (left * left + forward * forward).squareRoot() > 10 else { return }
        manualHeadingRadians = atan2(Double(left), Double(forward))
    }

    private func sendWaypointTap(at location: CGPoint, side: CGFloat) {
        guard side > 0, canUsePhoneControl else { return }

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
        sendManualGoal(
            x: selectedWaypointX,
            y: selectedWaypointY,
            yaw: manualHeadingRadians
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

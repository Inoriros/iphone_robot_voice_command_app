import SwiftUI

struct ContentView: View {
    @StateObject private var speech = SpeechRecognizer()
    @StateObject private var robot = RobotClient()

    @State private var jetsonIP = AppConfig.defaultJetsonIP
    @State private var token = AppConfig.defaultToken
    @State private var commandText = ""

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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    connectionSection
                    batterySection
                    statusSection
                    taskPlanSection
                    subtaskProofSection
                    stopControlsSection
                    armControlsSection
                    commandSection
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

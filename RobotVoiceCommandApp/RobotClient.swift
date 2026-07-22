import Foundation

private struct QueuedManualVelocityCommand {
    let request: URLRequest
    let host: String
    let isStop: Bool
}

@MainActor
final class RobotClient: ObservableObject {
    @Published var connectionState = "Disconnected"
    @Published var currentStatusText = "No status received yet"
    @Published var lastStatus: RobotStatus?
    @Published var latestTaskPlanText: String?
    @Published var latestPromptEvidenceText: String?
    @Published var latestEvidenceImageData: Data?
    @Published var latestEvidenceImageFormat: String?
    @Published var lastError: String?
    @Published var lastCommandMessage: String?
    @Published var lastCommandSendSucceeded = false
    @Published var batteryPercentage: Double?
    @Published var batteryMessage: String?
    @Published var isCheckingBattery = false
    @Published var controlSource = "unknown"
    @Published var physicalControlSource = "unknown"
    @Published var robotMode = "unknown"
    @Published var controlAuthority = "none"
    @Published var sbusAvailable = false
    @Published var appModeControlEnabled = false
    @Published var appModeOverrideActive = false
    @Published var appSourceControlEnabled = false
    @Published var appSourceOverrideActive = false
    @Published var phoneControlEnabled = false
    @Published var manualControlMessage: String?
    @Published var isSendingManualControl = false
    @Published var robotModeMessage: String?
    @Published var isSendingRobotMode = false
    @Published var controlSourceMessage: String?
    @Published var isSendingControlSource = false
    @Published var bodyHeightMeters = 0.0
    @Published var bodyHeightMessage: String?
    @Published var isSendingBodyHeight = false
    @Published var latestArmSkillStatus: ArmSkillStatus?
    @Published var armCommandStatusText = "No arm skill status received yet"
    @Published var isArmCommandActive = false
    @Published var activeArmActionName: String?
    @Published var activeArmCommandID: Int?
    @Published var armCommandTimedOut = false

    private var webSocketTask: URLSessionWebSocketTask?
    private let jsonDecoder = JSONDecoder()
    private let jsonEncoder = JSONEncoder()
    private var manualVelocityTask: URLSessionDataTask?
    private var pendingManualVelocityCommand: QueuedManualVelocityCommand?
    private var armStatusBuffer: [ArmSkillStatus] = []
    private var pendingArmActionName: String?
    private var pendingArmSendStampSec: Double?
    private var armTimeoutTask: Task<Void, Never>?
    private var armCommandGeneration = 0
    private var newestArmCommandID: Int?
    private var latestArmStatusStampSec: Double?
    private var armCommandIDBeforeSend: Int?

    func sendCommand(ip: String, token: String, text: String) {
        sendCommandRequest(ip: ip, token: token, text: text, armActionName: nil)
    }

    func sendArmCommand(
        ip: String,
        token: String,
        text: String,
        actionName: String,
        allowPreemption: Bool = false
    ) {
        guard connectionState == "Connected" else {
            lastError = "Connect the live status stream before sending an arm command."
            return
        }
        if isArmCommandActive {
            guard allowPreemption else {
                lastError = "Wait for the active arm command to finish, or enable one-shot replacement."
                return
            }
            guard activeArmCommandID != nil else {
                lastError = "Wait for the arm controller to identify the active skill before replacing it."
                return
            }
        }
        sendCommandRequest(
            ip: ip,
            token: token,
            text: text,
            armActionName: actionName
        )
    }

    private func sendCommandRequest(
        ip: String,
        token: String,
        text: String,
        armActionName: String?
    ) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedIP = normalizedHost(from: ip)

        lastError = nil
        lastCommandMessage = nil
        lastCommandSendSucceeded = false

        guard !trimmedIP.isEmpty else {
            lastError = "Jetson IP is required."
            return
        }

        guard !trimmedText.isEmpty else {
            lastError = "Empty or invalid command."
            return
        }

        guard let url = commandURL(ip: trimmedIP) else {
            lastError = "Jetson IP is invalid."
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let body = CommandRequest(text: trimmedText, token: token, source: AppConfig.commandSource)
            request.httpBody = try jsonEncoder.encode(body)
        } catch {
            lastError = "Could not encode command: \(error.localizedDescription)"
            return
        }

        let armRequestGeneration = armActionName.map {
            beginArmCommand(actionName: $0)
        }

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let armRequestGeneration,
                   self.armCommandGeneration != armRequestGeneration {
                    return
                }

                if let error {
                    let message = "Cannot reach Jetson at \(trimmedIP):\(AppConfig.defaultPort). \(error.localizedDescription)"
                    self.lastError = message
                    self.lastCommandSendSucceeded = false
                    if let armRequestGeneration {
                        self.failArmCommandRequest(message, generation: armRequestGeneration)
                    }
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    let message = "Jetson returned an invalid response."
                    self.lastError = message
                    self.lastCommandSendSucceeded = false
                    if let armRequestGeneration {
                        self.failArmCommandRequest(message, generation: armRequestGeneration)
                    }
                    return
                }

                switch httpResponse.statusCode {
                case 200:
                    let commandResponse = data.flatMap {
                        try? self.jsonDecoder.decode(CommandResponse.self, from: $0)
                    }

                    if let armActionName, let armRequestGeneration {
                        guard let commandResponse,
                              commandResponse.ok,
                              commandResponse.commandType == "arm",
                              commandResponse.armActionName == armActionName,
                              let sendStampSec = commandResponse.armSendStampSec else {
                            let message = "Jetson returned an incomplete arm-command response."
                            self.lastError = message
                            self.lastCommandSendSucceeded = false
                            self.failArmCommandRequest(
                                message,
                                generation: armRequestGeneration
                            )
                            return
                        }

                        self.lastCommandSendSucceeded = true
                        self.lastCommandMessage = "Command sent: \(commandResponse.text ?? trimmedText)"
                        self.confirmArmCommandSent(
                            actionName: armActionName,
                            sendStampSec: sendStampSec,
                            generation: armRequestGeneration
                        )
                    } else if let commandResponse, commandResponse.ok {
                        self.lastCommandSendSucceeded = true
                        self.lastCommandMessage = "Command sent: \(commandResponse.text ?? trimmedText)"
                    } else {
                        self.lastCommandSendSucceeded = true
                        self.lastCommandMessage = "Command sent."
                    }
                case 400:
                    let message = "Empty or invalid command."
                    self.lastError = message
                    self.lastCommandSendSucceeded = false
                    if let armRequestGeneration {
                        self.failArmCommandRequest(message, generation: armRequestGeneration)
                    }
                case 401:
                    let message = "Invalid token. Please check the token on the Jetson bridge."
                    self.lastError = message
                    self.lastCommandSendSucceeded = false
                    if let armRequestGeneration {
                        self.failArmCommandRequest(message, generation: armRequestGeneration)
                    }
                default:
                    let serverMessage = data.flatMap { String(data: $0, encoding: .utf8) }
                    let message = serverMessage?.isEmpty == false
                        ? "Jetson returned HTTP \(httpResponse.statusCode): \(serverMessage!)"
                        : "Jetson returned HTTP \(httpResponse.statusCode)."
                    self.lastError = message
                    self.lastCommandSendSucceeded = false
                    if let armRequestGeneration {
                        self.failArmCommandRequest(message, generation: armRequestGeneration)
                    }
                }
            }
        }.resume()
    }

    func checkBattery(ip: String, token: String) {
        let trimmedIP = normalizedHost(from: ip)

        lastError = nil
        batteryPercentage = nil
        batteryMessage = nil
        isCheckingBattery = false

        guard !trimmedIP.isEmpty else {
            lastError = "Jetson IP is required."
            return
        }

        guard let url = batteryURL(ip: trimmedIP) else {
            lastError = "Jetson IP is invalid."
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let body = BatteryRequest(token: token, source: AppConfig.commandSource)
            request.httpBody = try jsonEncoder.encode(body)
        } catch {
            lastError = "Could not encode battery request: \(error.localizedDescription)"
            return
        }

        isCheckingBattery = true
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isCheckingBattery = false

                if let error {
                    self.lastError = "Cannot reach Jetson at \(trimmedIP):\(AppConfig.defaultPort). \(error.localizedDescription)"
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    self.lastError = "Jetson returned an invalid battery response."
                    return
                }

                switch httpResponse.statusCode {
                case 200:
                    guard let data,
                          let response = try? self.jsonDecoder.decode(BatteryResponse.self, from: data),
                          response.ok else {
                        self.lastError = "Jetson returned an unreadable battery response."
                        return
                    }
                    self.batteryPercentage = response.percentage
                    self.batteryMessage = response.message
                case 401:
                    self.lastError = "Invalid token. Please check the token on the Jetson bridge."
                default:
                    if let detail = self.bridgeErrorDetail(from: data) {
                        self.lastError = detail
                    } else {
                        self.lastError = "Jetson returned HTTP \(httpResponse.statusCode) while checking the battery."
                    }
                }
            }
        }.resume()
    }

    func sendManualControl(
        ip: String,
        token: String,
        x: Double,
        y: Double,
        yaw: Double
    ) {
        let trimmedIP = normalizedHost(from: ip)

        lastError = nil
        manualControlMessage = nil
        isSendingManualControl = false

        guard phoneControlEnabled else {
            lastError = "Phone motion requires the Phone control source and WALK mode."
            return
        }
        guard !trimmedIP.isEmpty else {
            lastError = "Jetson IP is required."
            return
        }
        guard x.isFinite, y.isFinite, yaw.isFinite else {
            lastError = "Manual control contains an invalid coordinate."
            return
        }
        let axisLimit = AppConfig.maximumManualControlAxisRangeMeters
        guard abs(x) <= axisLimit, abs(y) <= axisLimit, abs(yaw) <= Double.pi else {
            lastError = "Manual control is outside the configured range."
            return
        }
        guard let url = manualControlURL(ip: trimmedIP) else {
            lastError = "Jetson IP is invalid."
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let body = ManualControlRequest(
                x: x,
                y: y,
                yaw: yaw,
                token: token,
                source: AppConfig.commandSource
            )
            request.httpBody = try jsonEncoder.encode(body)
        } catch {
            lastError = "Could not encode manual control: \(error.localizedDescription)"
            return
        }

        isSendingManualControl = true
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isSendingManualControl = false

                if let error {
                    self.lastError = "Cannot reach Jetson at \(trimmedIP):\(AppConfig.defaultPort). \(error.localizedDescription)"
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    self.lastError = "Jetson returned an invalid manual-control response."
                    return
                }

                switch httpResponse.statusCode {
                case 200:
                    guard let data,
                          let response = try? self.jsonDecoder.decode(ManualControlResponse.self, from: data),
                          response.ok else {
                        self.lastError = "Jetson returned an unreadable manual-control response."
                        return
                    }
                    self.manualControlMessage = response.message
                case 401:
                    self.lastError = "Invalid token. Please check the token on the Jetson bridge."
                default:
                    self.lastError = self.bridgeErrorDetail(from: data)
                        ?? "Jetson returned HTTP \(httpResponse.statusCode) for manual control."
                }
            }
        }.resume()
    }

    func sendManualVelocity(
        ip: String,
        token: String,
        forward: Double,
        strafe: Double,
        yaw: Double
    ) {
        let trimmedIP = normalizedHost(from: ip)
        let isStop = max(abs(forward), abs(strafe), abs(yaw)) < 0.001

        guard isStop || phoneControlEnabled else {
            lastError = "Direct motion requires the Phone control source and WALK mode."
            return
        }
        guard !trimmedIP.isEmpty else {
            lastError = "Jetson IP is required."
            return
        }
        guard forward.isFinite, strafe.isFinite, yaw.isFinite else {
            lastError = "Direct motion contains an invalid value."
            return
        }
        guard abs(forward) <= 1, abs(strafe) <= 1, abs(yaw) <= 1 else {
            lastError = "Direct motion is outside the normalized range."
            return
        }
        guard let url = manualVelocityURL(ip: trimmedIP) else {
            lastError = "Jetson IP is invalid."
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 2
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try jsonEncoder.encode(
                ManualVelocityRequest(
                    forward: forward,
                    strafe: strafe,
                    yaw: yaw,
                    token: token,
                    source: AppConfig.commandSource
                )
            )
        } catch {
            lastError = "Could not encode direct motion: \(error.localizedDescription)"
            return
        }

        let command = QueuedManualVelocityCommand(
            request: request,
            host: trimmedIP,
            isStop: isStop
        )
        if manualVelocityTask != nil {
            pendingManualVelocityCommand = command
            return
        }
        startManualVelocityCommand(command)
    }

    private func startManualVelocityCommand(_ command: QueuedManualVelocityCommand) {
        let task = URLSession.shared.dataTask(with: command.request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                defer {
                    self.manualVelocityTask = nil
                    if let pending = self.pendingManualVelocityCommand {
                        self.pendingManualVelocityCommand = nil
                        self.startManualVelocityCommand(pending)
                    }
                }

                if let error {
                    self.lastError = "Cannot reach Jetson at \(command.host):\(AppConfig.defaultPort). \(error.localizedDescription)"
                    return
                }
                guard let httpResponse = response as? HTTPURLResponse else {
                    self.lastError = "Jetson returned an invalid direct-motion response."
                    return
                }

                switch httpResponse.statusCode {
                case 200:
                    guard let data,
                          let response = try? self.jsonDecoder.decode(
                              ManualVelocityResponse.self,
                              from: data
                          ),
                          response.ok else {
                        self.lastError = "Jetson returned an unreadable direct-motion response."
                        return
                    }
                    if command.isStop {
                        self.manualControlMessage = response.message
                    }
                case 401:
                    self.lastError = "Invalid token. Please check the token on the Jetson bridge."
                default:
                    self.lastError = self.bridgeErrorDetail(from: data)
                        ?? "Jetson returned HTTP \(httpResponse.statusCode) for direct motion."
                }
            }
        }
        manualVelocityTask = task
        task.resume()
    }

    func sendBodyHeight(ip: String, token: String, height: Double) {
        let trimmedIP = normalizedHost(from: ip)

        lastError = nil
        bodyHeightMessage = nil
        isSendingBodyHeight = false

        guard connectionState == "Connected" else {
            lastError = "Connect the live status stream before changing body height."
            return
        }
        guard phoneControlEnabled else {
            lastError = "Body-height control requires the Phone control source and WALK mode."
            return
        }
        guard height.isFinite,
              height >= AppConfig.minimumBodyHeightMeters,
              height <= AppConfig.maximumBodyHeightMeters else {
            lastError = "Body height is outside the allowed range."
            return
        }
        guard !trimmedIP.isEmpty else {
            lastError = "Jetson IP is required."
            return
        }
        guard let url = bodyHeightURL(ip: trimmedIP) else {
            lastError = "Jetson IP is invalid."
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try jsonEncoder.encode(
                BodyHeightRequest(
                    height: height,
                    token: token,
                    source: AppConfig.commandSource
                )
            )
        } catch {
            lastError = "Could not encode body height: \(error.localizedDescription)"
            return
        }

        isSendingBodyHeight = true
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isSendingBodyHeight = false

                if let error {
                    self.lastError = "Cannot reach Jetson at \(trimmedIP):\(AppConfig.defaultPort). \(error.localizedDescription)"
                    return
                }
                guard let httpResponse = response as? HTTPURLResponse else {
                    self.lastError = "Jetson returned an invalid body-height response."
                    return
                }

                switch httpResponse.statusCode {
                case 200:
                    guard let data,
                          let response = try? self.jsonDecoder.decode(
                              BodyHeightResponse.self,
                              from: data
                          ),
                          response.ok else {
                        self.lastError = "Jetson returned an unreadable body-height response."
                        return
                    }
                    self.bodyHeightMeters = response.height
                    self.bodyHeightMessage = response.message
                case 401:
                    self.lastError = "Invalid token. Please check the token on the Jetson bridge."
                default:
                    self.lastError = self.bridgeErrorDetail(from: data)
                        ?? "Jetson returned HTTP \(httpResponse.statusCode) while changing body height."
                }
            }
        }.resume()
    }

    func sendRobotMode(ip: String, token: String, mode: String) {
        let trimmedIP = normalizedHost(from: ip)
        let normalizedMode = mode.lowercased()

        lastError = nil
        robotModeMessage = nil
        isSendingRobotMode = false

        guard connectionState == "Connected" else {
            lastError = "Connect the live status stream before changing robot mode."
            return
        }
        guard appModeControlEnabled else {
            lastError = "Robot mode remains owned by the connected SBUS controller."
            return
        }
        guard ["sit", "stand", "walk"].contains(normalizedMode) else {
            lastError = "Unsupported robot mode."
            return
        }
        guard !trimmedIP.isEmpty else {
            lastError = "Jetson IP is required."
            return
        }
        guard let url = robotModeURL(ip: trimmedIP) else {
            lastError = "Jetson IP is invalid."
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let body = RobotModeRequest(
                mode: normalizedMode,
                token: token,
                source: AppConfig.commandSource
            )
            request.httpBody = try jsonEncoder.encode(body)
        } catch {
            lastError = "Could not encode robot mode: \(error.localizedDescription)"
            return
        }

        isSendingRobotMode = true
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isSendingRobotMode = false

                if let error {
                    self.lastError = "Cannot reach Jetson at \(trimmedIP):\(AppConfig.defaultPort). \(error.localizedDescription)"
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    self.lastError = "Jetson returned an invalid robot-mode response."
                    return
                }

                switch httpResponse.statusCode {
                case 200:
                    guard let data,
                          let response = try? self.jsonDecoder.decode(RobotModeResponse.self, from: data),
                          response.ok else {
                        self.lastError = "Jetson returned an unreadable robot-mode response."
                        return
                    }
                    self.robotModeMessage = response.message
                case 401:
                    self.lastError = "Invalid token. Please check the token on the Jetson bridge."
                default:
                    self.lastError = self.bridgeErrorDetail(from: data)
                        ?? "Jetson returned HTTP \(httpResponse.statusCode) while changing robot mode."
                }
            }
        }.resume()
    }

    func sendControlSource(ip: String, token: String, sourceMode: String) {
        let trimmedIP = normalizedHost(from: ip)
        let normalizedSource = sourceMode.lowercased()

        lastError = nil
        controlSourceMessage = nil
        isSendingControlSource = false

        guard connectionState == "Connected" else {
            lastError = "Connect the live status stream before changing control source."
            return
        }
        guard appSourceControlEnabled else {
            lastError = "Control source remains owned by the connected SBUS controller."
            return
        }
        guard ["waypoint", "hold", "sbus"].contains(normalizedSource) else {
            lastError = "Unsupported control source."
            return
        }
        guard !trimmedIP.isEmpty else {
            lastError = "Jetson IP is required."
            return
        }
        guard let url = controlSourceURL(ip: trimmedIP) else {
            lastError = "Jetson IP is invalid."
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let body = ControlSourceRequest(
                sourceMode: normalizedSource,
                token: token,
                source: AppConfig.commandSource
            )
            request.httpBody = try jsonEncoder.encode(body)
        } catch {
            lastError = "Could not encode control source: \(error.localizedDescription)"
            return
        }

        isSendingControlSource = true
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isSendingControlSource = false

                if let error {
                    self.lastError = "Cannot reach Jetson at \(trimmedIP):\(AppConfig.defaultPort). \(error.localizedDescription)"
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    self.lastError = "Jetson returned an invalid control-source response."
                    return
                }

                switch httpResponse.statusCode {
                case 200:
                    guard let data,
                          let response = try? self.jsonDecoder.decode(ControlSourceResponse.self, from: data),
                          response.ok else {
                        self.lastError = "Jetson returned an unreadable control-source response."
                        return
                    }
                    self.controlSourceMessage = response.message
                case 401:
                    self.lastError = "Invalid token. Please check the token on the Jetson bridge."
                default:
                    self.lastError = self.bridgeErrorDetail(from: data)
                        ?? "Jetson returned HTTP \(httpResponse.statusCode) while changing control source."
                }
            }
        }.resume()
    }

    @discardableResult
    private func beginArmCommand(actionName: String) -> Int {
        armCommandIDBeforeSend = activeArmCommandID ?? newestArmCommandID
        armCommandGeneration += 1
        armTimeoutTask?.cancel()
        armTimeoutTask = nil
        armStatusBuffer.removeAll(keepingCapacity: true)
        pendingArmActionName = actionName
        pendingArmSendStampSec = nil
        activeArmActionName = actionName
        activeArmCommandID = nil
        latestArmSkillStatus = nil
        armCommandTimedOut = false
        isArmCommandActive = true
        armCommandStatusText = "Sending \(actionName)…"
        return armCommandGeneration
    }

    private func confirmArmCommandSent(
        actionName: String,
        sendStampSec: Double,
        generation: Int
    ) {
        guard isArmCommandActive,
              armCommandGeneration == generation,
              pendingArmActionName == actionName else {
            return
        }

        pendingArmSendStampSec = sendStampSec
        armCommandStatusText = "Waiting for \(actionName) to be accepted…"
        correlateBufferedArmStatuses()

        if isArmCommandActive, activeArmCommandID == nil {
            scheduleArmTimeout(
                seconds: AppConfig.armCommandAcceptanceTimeoutSeconds,
                message: "Arm acceptance status is delayed for \(actionName); controls remain locked until status recovers."
            )
        }
    }

    private func handleArmSkillStatus(_ status: ArmSkillStatus) {
        armStatusBuffer.append(status)
        if armStatusBuffer.count > AppConfig.armStatusBufferLimit {
            armStatusBuffer.removeFirst(
                armStatusBuffer.count - AppConfig.armStatusBufferLimit
            )
        }

        guard isArmCommandActive else {
            if let newestArmCommandID {
                guard status.commandId >= newestArmCommandID else { return }
                if status.commandId == newestArmCommandID {
                    if let latestArmStatusStampSec,
                       status.stampSec < latestArmStatusStampSec {
                        return
                    }
                    if latestArmSkillStatus?.isTerminal == true, !status.isTerminal {
                        return
                    }
                }
            }

            newestArmCommandID = status.commandId
            latestArmStatusStampSec = status.stampSec
            latestArmSkillStatus = status
            armCommandStatusText = status.displayText
            armCommandTimedOut = false
            return
        }

        if let activeArmCommandID {
            guard status.commandId == activeArmCommandID,
                  let sendStampSec = pendingArmSendStampSec,
                  status.stampSec >= sendStampSec else {
                return
            }
            processActiveArmStatus(status)
            return
        }

        correlateBufferedArmStatuses()
    }

    private func correlateBufferedArmStatuses() {
        guard isArmCommandActive,
              activeArmCommandID == nil,
              let actionName = pendingArmActionName,
              let sendStampSec = pendingArmSendStampSec,
              let correlatedIndex = armStatusBuffer.firstIndex(where: { status in
                  status.actionName == actionName
                      && status.stampSec >= sendStampSec
                      && status.commandId != armCommandIDBeforeSend
                      && status.canEstablishCommandIdentity
              }) else {
            return
        }

        let correlatedStatus = armStatusBuffer[correlatedIndex]
        activeArmCommandID = correlatedStatus.commandId
        newestArmCommandID = correlatedStatus.commandId
        latestArmStatusStampSec = correlatedStatus.stampSec
        processActiveArmStatus(correlatedStatus)

        guard isArmCommandActive else { return }
        for status in armStatusBuffer.suffix(from: armStatusBuffer.index(after: correlatedIndex)) {
            guard status.commandId == correlatedStatus.commandId,
                  status.stampSec >= sendStampSec else {
                continue
            }
            processActiveArmStatus(status)
            if !isArmCommandActive {
                break
            }
        }
    }

    private func processActiveArmStatus(_ status: ArmSkillStatus) {
        guard isArmCommandActive else { return }
        if armCommandTimedOut {
            armCommandTimedOut = false
            lastError = nil
        }
        newestArmCommandID = status.commandId
        latestArmStatusStampSec = status.stampSec

        latestArmSkillStatus = status
        armCommandStatusText = status.displayText

        if status.isTerminal {
            armTimeoutTask?.cancel()
            armTimeoutTask = nil
            isArmCommandActive = false
            pendingArmActionName = nil
            pendingArmSendStampSec = nil
            armCommandIDBeforeSend = nil

            if ["failed", "rejected"].contains(status.normalizedStatus) {
                lastError = "Arm command \(status.normalizedStatus): \(status.displayText)"
            }
            return
        }

        scheduleArmTimeout(
            seconds: AppConfig.armCommandExecutionTimeoutSeconds,
            message: "Arm status is delayed while running \(status.actionName); controls remain locked until status recovers or you explicitly replace it."
        )
    }

    private func failArmCommandRequest(_ message: String, generation: Int) {
        guard isArmCommandActive, armCommandGeneration == generation else { return }

        armTimeoutTask?.cancel()
        armTimeoutTask = nil
        isArmCommandActive = false
        pendingArmActionName = nil
        pendingArmSendStampSec = nil
        activeArmCommandID = nil
        armCommandIDBeforeSend = nil
        armCommandStatusText = message
    }

    private func scheduleArmTimeout(seconds: Double, message: String) {
        armTimeoutTask?.cancel()
        let generation = armCommandGeneration
        let nanoseconds = UInt64(max(seconds, 0) * 1_000_000_000)

        armTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }

            guard let self,
                  self.isArmCommandActive,
                  self.armCommandGeneration == generation else {
                return
            }

            self.armCommandTimedOut = true
            self.armCommandStatusText = message
            self.lastError = message
            self.armTimeoutTask = nil
        }
    }

    func connectStatusWebSocket(ip: String) {
        let trimmedIP = normalizedHost(from: ip)

        lastError = nil

        guard !trimmedIP.isEmpty else {
            connectionState = "Error"
            lastError = "Jetson IP is required."
            return
        }

        guard let url = statusURL(ip: trimmedIP) else {
            connectionState = "Error"
            lastError = "Jetson IP is invalid."
            return
        }

        disconnectStatusWebSocket(updateState: false)
        connectionState = "Connecting"

        let task = URLSession.shared.webSocketTask(with: url)
        webSocketTask = task
        task.resume()

        receiveStatusMessage()
    }

    func disconnectStatusWebSocket() {
        disconnectStatusWebSocket(updateState: true)
    }

    private func disconnectStatusWebSocket(updateState: Bool) {
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        manualVelocityTask?.cancel()
        manualVelocityTask = nil
        pendingManualVelocityCommand = nil
        phoneControlEnabled = false
        bodyHeightMeters = 0.0
        controlSource = "unknown"
        physicalControlSource = "unknown"
        robotMode = "unknown"
        controlAuthority = "none"
        sbusAvailable = false
        appModeControlEnabled = false
        appModeOverrideActive = false
        appSourceControlEnabled = false
        appSourceOverrideActive = false
        if isArmCommandActive {
            armCommandStatusText = "Arm status stream disconnected; controls remain locked until status recovers."
        }

        if updateState {
            connectionState = "Disconnected"
        }
    }

    private func receiveStatusMessage() {
        guard let webSocketTask else { return }

        webSocketTask.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }

                switch result {
                case .success(let message):
                    self.connectionState = "Connected"
                    self.handle(message)
                    self.receiveStatusMessage()
                case .failure(let error):
                    self.connectionState = "Disconnected"
                    self.phoneControlEnabled = false
                    self.bodyHeightMeters = 0.0
                    self.controlSource = "unknown"
                    self.physicalControlSource = "unknown"
                    self.robotMode = "unknown"
                    self.controlAuthority = "none"
                    self.sbusAvailable = false
                    self.appModeControlEnabled = false
                    self.appModeOverrideActive = false
                    self.appSourceControlEnabled = false
                    self.appSourceOverrideActive = false
                    if self.isArmCommandActive {
                        self.armCommandStatusText = "Arm status stream disconnected; controls remain locked until status recovers."
                    }
                    self.lastError = "Status stream disconnected. Tap Reconnect. \(error.localizedDescription)"
                    self.webSocketTask = nil
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            handleStatusText(text)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
                handleStatusText(text)
            } else {
                currentStatusText = "Received binary status message."
                lastStatus = nil
            }
        @unknown default:
            currentStatusText = "Received unsupported status message."
            lastStatus = nil
        }
    }

    private func handleStatusText(_ text: String) {
        guard let data = text.data(using: .utf8) else {
            lastStatus = nil
            currentStatusText = text
            return
        }

        if let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let eventType = event["type"] as? String {
            let eventData = event["data"]
            switch eventType {
            case "task_plan":
                latestTaskPlanText = formattedJSON(eventData)
                latestPromptEvidenceText = nil
                latestEvidenceImageData = nil
                latestEvidenceImageFormat = nil
                return
            case "prompt_evidence":
                latestPromptEvidenceText = formattedJSON(eventData)
                return
            case "image_evidence":
                if let imagePayload = eventData as? [String: Any],
                   let encoded = imagePayload["base64"] as? String,
                   let imageData = Data(
                       base64Encoded: encoded,
                       options: .ignoreUnknownCharacters
                   ) {
                    latestEvidenceImageData = imageData
                    latestEvidenceImageFormat = imagePayload["format"] as? String
                }
                return
            case "arm_skill_status":
                if let nestedData = encodedJSON(eventData),
                   let armStatus = try? jsonDecoder.decode(ArmSkillStatus.self, from: nestedData) {
                    handleArmSkillStatus(armStatus)
                } else {
                    lastError = "Received an unreadable arm skill status."
                }
                return
            case "control_state":
                if let controlState = eventData as? [String: Any] {
                    controlSource = controlState["source"] as? String ?? "unknown"
                    physicalControlSource = controlState["physical_source"] as? String
                        ?? controlSource
                    robotMode = controlState["robot_mode"] as? String ?? "unknown"
                    controlAuthority = controlState["control_authority"] as? String
                        ?? controlSource
                    sbusAvailable = controlState["sbus_available"] as? Bool ?? true
                    appSourceControlEnabled = controlState["app_source_control_enabled"] as? Bool
                        ?? false
                    appSourceOverrideActive = controlState["app_source_override_active"] as? Bool
                        ?? false
                    appModeControlEnabled = controlState["app_mode_control_enabled"] as? Bool
                        ?? false
                    appModeOverrideActive = controlState["app_mode_override_active"] as? Bool
                        ?? false
                    phoneControlEnabled = controlState["phone_control_enabled"] as? Bool
                        ?? (controlSource == "sbus" && robotMode == "walk")
                    bodyHeightMeters = (controlState["body_height_m"] as? NSNumber)?.doubleValue
                        ?? bodyHeightMeters
                } else {
                    appSourceControlEnabled = false
                    appSourceOverrideActive = false
                    appModeControlEnabled = false
                    phoneControlEnabled = false
                }
                return
            default:
                if let nestedData = encodedJSON(eventData),
                   let status = try? jsonDecoder.decode(RobotStatus.self, from: nestedData) {
                    lastStatus = status
                    currentStatusText = status.displayText
                    return
                }
            }
        }

        guard let status = try? jsonDecoder.decode(RobotStatus.self, from: data) else {
            lastStatus = nil
            currentStatusText = text
            return
        }

        lastStatus = status
        currentStatusText = status.displayText
    }

    private func encodedJSON(_ value: Any?) -> Data? {
        guard let value, JSONSerialization.isValidJSONObject(value) else {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: value)
    }

    private func formattedJSON(_ value: Any?) -> String? {
        if let text = value as? String {
            return text
        }
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                  withJSONObject: value,
                  options: [.prettyPrinted, .sortedKeys]
              ) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func commandURL(ip: String) -> URL? {
        URL(string: "http://\(ip):\(AppConfig.defaultPort)\(AppConfig.commandPath)")
    }

    private func batteryURL(ip: String) -> URL? {
        URL(string: "http://\(ip):\(AppConfig.defaultPort)\(AppConfig.batteryPath)")
    }

    private func manualControlURL(ip: String) -> URL? {
        URL(string: "http://\(ip):\(AppConfig.defaultPort)\(AppConfig.manualControlPath)")
    }

    private func manualVelocityURL(ip: String) -> URL? {
        URL(string: "http://\(ip):\(AppConfig.defaultPort)\(AppConfig.manualVelocityPath)")
    }

    private func bodyHeightURL(ip: String) -> URL? {
        URL(string: "http://\(ip):\(AppConfig.defaultPort)\(AppConfig.bodyHeightPath)")
    }

    private func robotModeURL(ip: String) -> URL? {
        URL(string: "http://\(ip):\(AppConfig.defaultPort)\(AppConfig.robotModePath)")
    }

    private func controlSourceURL(ip: String) -> URL? {
        URL(string: "http://\(ip):\(AppConfig.defaultPort)\(AppConfig.controlSourcePath)")
    }

    private func statusURL(ip: String) -> URL? {
        URL(string: "ws://\(ip):\(AppConfig.defaultPort)\(AppConfig.statusPath)")
    }

    private func normalizedHost(from input: String) -> String {
        let hostWithOptionalPort = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "ws://", with: "")
            .replacingOccurrences(of: "wss://", with: "")
            .split(separator: "/")
            .first
            .map(String.init) ?? ""

        if hostWithOptionalPort.contains(":"),
           !hostWithOptionalPort.hasPrefix("["),
           let host = hostWithOptionalPort.split(separator: ":").first {
            return String(host)
        }

        return hostWithOptionalPort
    }

    private func bridgeErrorDetail(from data: Data?) -> String? {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let detail = object["detail"] as? String,
              !detail.isEmpty else {
            return nil
        }
        return detail
    }
}

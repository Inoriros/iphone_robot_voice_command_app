import Foundation

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

    private var webSocketTask: URLSessionWebSocketTask?
    private let jsonDecoder = JSONDecoder()
    private let jsonEncoder = JSONEncoder()

    func sendCommand(ip: String, token: String, text: String) {
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

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }

                if let error {
                    self.lastError = "Cannot reach Jetson at \(trimmedIP):\(AppConfig.defaultPort). \(error.localizedDescription)"
                    self.lastCommandSendSucceeded = false
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    self.lastError = "Jetson returned an invalid response."
                    self.lastCommandSendSucceeded = false
                    return
                }

                switch httpResponse.statusCode {
                case 200:
                    self.lastCommandSendSucceeded = true
                    if let data, let response = try? self.jsonDecoder.decode(CommandResponse.self, from: data), response.ok {
                        self.lastCommandMessage = "Command sent: \(response.text ?? trimmedText)"
                    } else {
                        self.lastCommandMessage = "Command sent."
                    }
                case 400:
                    self.lastError = "Empty or invalid command."
                    self.lastCommandSendSucceeded = false
                case 401:
                    self.lastError = "Invalid token. Please check the token on the Jetson bridge."
                    self.lastCommandSendSucceeded = false
                default:
                    let serverMessage = data.flatMap { String(data: $0, encoding: .utf8) }
                    self.lastError = serverMessage?.isEmpty == false
                        ? "Jetson returned HTTP \(httpResponse.statusCode): \(serverMessage!)"
                        : "Jetson returned HTTP \(httpResponse.statusCode)."
                    self.lastCommandSendSucceeded = false
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

        connectionState = "Connected"
        receiveStatusMessage()
    }

    func disconnectStatusWebSocket() {
        disconnectStatusWebSocket(updateState: true)
    }

    private func disconnectStatusWebSocket(updateState: Bool) {
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil

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

import Foundation

struct CommandRequest: Codable {
    let text: String
    let token: String
    let source: String
}

struct CommandResponse: Codable {
    let ok: Bool
    let publishedTopic: String?
    let commandType: String?
    let text: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case publishedTopic = "published_topic"
        case commandType = "command_type"
        case text
    }
}

struct BatteryRequest: Codable {
    let token: String
    let source: String
}

struct BatteryResponse: Codable {
    let ok: Bool
    let percentage: Double
    let message: String
}

enum JSONValue: Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            self = .array(try container.decode([JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self {
            return value
        }

        return nil
    }

    var plainText: String? {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return value.formatted()
        case .bool(let value):
            return value ? "true" : "false"
        case .object(let value):
            return value.compactSummary
        case .array:
            return nil
        case .null:
            return nil
        }
    }
}

struct RobotStatus: Codable {
    var status: String?
    var state: String?
    var skill: String?
    var subtask: String?
    var instruction: String?
    var message: String?
    var progress: Double?
    var timestamp: Double?
    var type: String?
    var topic: String?
    var data: JSONValue?

    enum CodingKeys: String, CodingKey {
        case status
        case state
        case skill
        case subtask
        case instruction
        case message
        case progress
        case timestamp
        case type
        case topic
        case data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        status = try container.decodeIfPresent(String.self, forKey: .status)
        state = try container.decodeIfPresent(String.self, forKey: .state)
        skill = try container.decodeIfPresent(String.self, forKey: .skill)
        subtask = try container.decodeIfPresent(String.self, forKey: .subtask)
        instruction = try container.decodeIfPresent(String.self, forKey: .instruction)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        progress = try container.decodeIfPresent(Double.self, forKey: .progress)
        timestamp = try container.decodeIfPresent(Double.self, forKey: .timestamp)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        topic = try container.decodeIfPresent(String.self, forKey: .topic)
        data = try container.decodeIfPresent(JSONValue.self, forKey: .data)

        if let object = data?.objectValue {
            status = status ?? object.stringValue(for: "status")
            state = state ?? object.stringValue(for: "state")
            skill = skill ?? object.stringValue(for: "skill")
            subtask = subtask ?? object.stringValue(for: "subtask")
            instruction = instruction ?? object.stringValue(for: "instruction")
            message = message ?? object.stringValue(for: "message")
            progress = progress ?? object.doubleValue(for: "progress")
            timestamp = timestamp ?? object.doubleValue(for: "timestamp")
        }
    }

    var displayText: String {
        if let message, !message.isEmpty {
            return message
        }

        if let status, !status.isEmpty {
            return status
        }

        if let instruction, !instruction.isEmpty {
            return instruction
        }

        if let skill, !skill.isEmpty {
            return "Active skill: \(skill)"
        }

        if let dataText = data?.plainText, !dataText.isEmpty {
            return dataText
        }

        if let type, !type.isEmpty {
            return "\(type) update received"
        }

        return "Status update received"
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    func stringValue(for key: String) -> String? {
        guard let value = self[key] else { return nil }

        switch value {
        case .string(let string):
            return string
        case .number(let number):
            return number.formatted()
        case .bool(let bool):
            return bool ? "true" : "false"
        default:
            return nil
        }
    }

    func doubleValue(for key: String) -> Double? {
        guard let value = self[key] else { return nil }

        switch value {
        case .number(let number):
            return number
        case .string(let string):
            return Double(string)
        default:
            return nil
        }
    }

    var compactSummary: String? {
        if let message = stringValue(for: "message") {
            return message
        }

        if let instruction = stringValue(for: "instruction") {
            return instruction
        }

        if let skill = stringValue(for: "skill") {
            return skill
        }

        if let status = stringValue(for: "status") {
            return status
        }

        if let state = stringValue(for: "state") {
            return state
        }

        return nil
    }
}

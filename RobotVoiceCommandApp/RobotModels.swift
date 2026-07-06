import Foundation

struct CommandRequest: Codable {
    let text: String
    let token: String
    let source: String
}

struct CommandResponse: Codable {
    let ok: Bool
    let publishedTopic: String?
    let text: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case publishedTopic = "published_topic"
        case text
    }
}

struct RobotStatus: Codable {
    var status: String?
    var state: String?
    var skill: String?
    var subtask: String?
    var message: String?
    var progress: Double?
    var timestamp: Double?

    var displayText: String {
        if let message, !message.isEmpty {
            return message
        }

        if let status, !status.isEmpty {
            return status
        }

        return "Status update received"
    }
}

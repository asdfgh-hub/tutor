import Foundation

enum ChatRole: String, Codable {
    case user
    case assistant
}

struct ChatMessage: Identifiable, Codable {
    var id: UUID
    var role: ChatRole
    var text: String
    var speechText: String?
    var createdAt: Date

    init(role: ChatRole, text: String, speechText: String? = nil) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.speechText = speechText
        self.createdAt = Date()
    }
}

struct LessonSession: Identifiable, Codable {
    var id: UUID
    var startedAt: Date
    var endedAt: Date?
    var messages: [ChatMessage]

    var duration: TimeInterval {
        (endedAt ?? Date()).timeIntervalSince(startedAt)
    }
}

struct RouterModel: Identifiable, Decodable, Hashable {
    let id: String
    let name: String?
    let ownedBy: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case ownedBy = "owned_by"
    }

    var displayName: String { name ?? id }
}

struct RouterModelsResponse: Decodable {
    let data: [RouterModel]

    private enum CodingKeys: String, CodingKey {
        case data
        case models
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let standard = try container.decodeIfPresent([RouterModel].self, forKey: .data) {
            data = standard
        } else if let alternate = try container.decodeIfPresent([RouterModel].self, forKey: .models) {
            data = alternate
        } else {
            data = []
        }
    }
}

struct OpenAIChatRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let temperature: Double
    let max_tokens: Int
}

struct OpenAIChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }
        let message: Message
    }
    let choices: [Choice]
}

struct ParsedTutorReply {
    let displayText: String
    let spokenText: String

    static func parse(_ raw: String) -> ParsedTutorReply {
        let reply = extract("reply", from: raw)
        let feedback = extract("feedback_ru", from: raw)
        let phrase = extract("phrase", from: raw)

        guard let reply else {
            // If a model ignores the format, show its answer but do not risk reading
            // Russian feedback aloud. The unparsed answer remains visible to the learner.
            return ParsedTutorReply(displayText: raw.trimmingCharacters(in: .whitespacesAndNewlines),
                                    spokenText: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        var sections = [reply]
        if let feedback, !feedback.isEmpty, feedback.lowercased() != "none" {
            sections.append("Разбор ошибок\n\(feedback)")
        }
        if let phrase, !phrase.isEmpty, phrase.lowercased() != "none" {
            sections.append("Полезная фраза\n\(phrase)")
        }
        let speech = [reply, (phrase?.lowercased() == "none" ? nil : phrase)]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ". ")
        return ParsedTutorReply(displayText: sections.joined(separator: "\n\n"), spokenText: speech)
    }

    private static func extract(_ tag: String, from text: String) -> String? {
        guard let start = text.range(of: "<\(tag)>", options: .caseInsensitive),
              let end = text.range(of: "</\(tag)>", options: .caseInsensitive),
              start.upperBound <= end.lowerBound else { return nil }
        return String(text[start.upperBound..<end.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

import Foundation

enum ChatRole: String, Codable {
    case user
    case assistant
}

enum TrainingMode: String, Codable, CaseIterable, Identifiable {
    case passenger = "passenger"
    case interview = "interview"
    case fullFlight = "fullFlight"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .passenger: return "Сценарии с пассажирами"
        case .interview: return "Собеседование"
        case .fullFlight: return "Полный рейс"
        }
    }
    var subtitle: String {
        switch self {
        case .passenger: return "Отрабатывай отдельные ситуации на борту"
        case .interview: return "Ты кандидат, ИИ — рекрутер авиакомпании"
        case .fullFlight: return "Последовательно пройди этапы работы на рейсе"
        }
    }
}

enum TrainingLevel: String, Codable, CaseIterable, Identifiable {
    case a2 = "A2"
    case b1 = "B1"
    case b1Plus = "B1+"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .a2: return "A2 · с поддержкой"
        case .b1: return "B1 · обычный темп"
        case .b1Plus: return "B1+ · сложнее"
        }
    }
    var instruction: String {
        switch self {
        case .a2: return "Use short, clear sentences and common vocabulary. Ask simple questions. Avoid idioms."
        case .b1: return "Use natural everyday English at B1. Include a few varied sentence structures and realistic follow-up questions."
        case .b1Plus: return "Use confident B1/B1+ English, more varied vocabulary, indirect questions and occasional natural idioms, without becoming academic."
        }
    }
}

enum PassengerPersonality: String, Codable, CaseIterable, Identifiable {
    case friendly
    case confused
    case impatient
    case nervous
    case upset
    case demanding
    case family

    var id: String { rawValue }
    var title: String {
        switch self {
        case .friendly: return "Дружелюбный"
        case .confused: return "Растерянный"
        case .impatient: return "Торопливый"
        case .nervous: return "Взволнованный"
        case .upset: return "Недовольный"
        case .demanding: return "Требовательный"
        case .family: return "Пассажир с семьёй"
        }
    }
    var instruction: String {
        switch self {
        case .friendly: return "Be warm, polite and cooperative."
        case .confused: return "Be genuinely confused and ask for clarification, but remain polite."
        case .impatient: return "Be in a hurry and ask concise questions. Do not become rude."
        case .nervous: return "Sound worried and seek reassurance. Keep the situation realistic."
        case .upset: return "Express clear dissatisfaction and expect a solution, but never insult or threaten the crew."
        case .demanding: return "Be persistent and ask for a specific accommodation. Remain civil."
        case .family: return "Speak as a parent travelling with a child or family member. Ask practical questions."
        }
    }
}

struct TrainingScenario: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    let category: String
    let personality: PassengerPersonality
    let summary: String
    let openingLine: String
    let context: String
}

enum ScenarioCatalog {
    static let scenarios: [TrainingScenario] = [
        TrainingScenario(id: "seat", title: "Поиск места 18A", category: "Посадка", personality: .confused,
                         summary: "Пассажир не может найти своё место.",
                         openingLine: "Excuse me, could you help me, please? I can't find my seat. My boarding pass says 18A.",
                         context: "The passenger cannot find seat 18A and is unsure which side of the cabin to use."),
        TrainingScenario(id: "baggage", title: "Ручная кладь", category: "Багаж", personality: .impatient,
                         summary: "Чемодан не помещается на верхнюю полку.",
                         openingLine: "Excuse me, my suitcase doesn't fit in the overhead compartment. What should I do?",
                         context: "The passenger's carry-on suitcase does not fit in the overhead compartment and wants help."),
        TrainingScenario(id: "seat_change", title: "Смена места", category: "Посадка", personality: .demanding,
                         summary: "Пассажир хочет пересесть к спутнику.",
                         openingLine: "Hello. My wife is sitting several rows behind me. Could we change seats so we can sit together?",
                         context: "The passenger wants to sit next to a family member. The crew member should respond politely and avoid promising availability."),
        TrainingScenario(id: "meal", title: "Еда и напитки", category: "Сервис", personality: .friendly,
                         summary: "Пассажир спрашивает о вегетарианском питании.",
                         openingLine: "Hello! Could you tell me what vegetarian meal options you have today?",
                         context: "The passenger asks about meal options and ingredients. Do not invent ingredient or allergen information; offer to check official information."),
        TrainingScenario(id: "connection", title: "Пересадка", category: "Пересадки", personality: .nervous,
                         summary: "Пассажир боится опоздать на следующий рейс.",
                         openingLine: "I'm worried about my connecting flight. We are arriving late. Will I have enough time?",
                         context: "The passenger is anxious about a connecting flight and needs calm, clear communication without invented guarantees."),
        TrainingScenario(id: "delay", title: "Задержка рейса", category: "Сложные ситуации", personality: .upset,
                         summary: "Пассажир недоволен задержкой.",
                         openingLine: "Why are we still waiting? Nobody has explained what is happening. I need to know when we will leave.",
                         context: "The passenger is frustrated by a delay and wants an update. The crew member must not invent operational information."),
        TrainingScenario(id: "nervous_flyer", title: "Страх полёта", category: "Помощь", personality: .nervous,
                         summary: "Пассажир боится летать.",
                         openingLine: "Excuse me. I feel very nervous about flying. This is my first time on a plane.",
                         context: "The passenger is afraid of flying and asks for reassurance. Stay empathetic and do not make unsupported safety guarantees."),
        TrainingScenario(id: "family", title: "Пассажир с ребёнком", category: "Помощь", personality: .family,
                         summary: "Родителю нужна помощь с ребёнком.",
                         openingLine: "Hello. I'm travelling with my young daughter. Could you help us with our bags and show us where to sit?",
                         context: "A parent travelling with a child needs practical help during boarding."),
        TrainingScenario(id: "complaint", title: "Жалоба на обслуживание", category: "Сложные ситуации", personality: .upset,
                         summary: "Пассажир жалуется на обслуживание.",
                         openingLine: "I'm sorry, but I'm not happy with the service so far. Could I speak to someone about this?",
                         context: "The passenger makes a realistic complaint and expects the crew member to listen and respond professionally."),
        TrainingScenario(id: "assistance", title: "Запрос помощи", category: "Помощь", personality: .confused,
                         summary: "Пассажиру нужна дополнительная помощь.",
                         openingLine: "Excuse me, I need a little extra help getting settled. Could you explain what I should do?",
                         context: "The passenger requests extra assistance. Ask respectful clarifying questions and never make assumptions about their needs.")
    ]

    static func scenario(id: String?) -> TrainingScenario {
        scenarios.first(where: { $0.id == id }) ?? scenarios[0]
    }
}

struct FlightStage: Identifiable {
    let id: String
    let title: String
    let focus: String
    let personality: PassengerPersonality
    let openingLine: String
    let context: String
}

enum FullFlightCatalog {
    static let stages: [FlightStage] = [
        FlightStage(id: "boarding", title: "1. Посадка", focus: "Приветствие, посадочные талоны, поиск мест", personality: .confused,
                    openingLine: "Hello. I think I'm in the wrong place. My seat is 22C. Could you help me?",
                    context: "Boarding is in progress. A passenger is confused about the seat and needs help."),
        FlightStage(id: "baggage", title: "2. Размещение багажа", focus: "Ручная кладь и просьбы пассажиров", personality: .impatient,
                    openingLine: "Excuse me, there is no space above my seat. Where can I put my bag?",
                    context: "Passengers are settling in. A passenger cannot find space for their cabin bag."),
        FlightStage(id: "departure", title: "3. Перед вылетом", focus: "Объяснения и спокойные инструкции", personality: .nervous,
                    openingLine: "I'm a little nervous. Is it normal to feel the aircraft moving like this?",
                    context: "The aircraft is preparing for departure. This is language practice only; do not invent or replace official safety procedures."),
        FlightStage(id: "service", title: "4. Обслуживание", focus: "Еда, напитки, вежливые предложения", personality: .friendly,
                    openingLine: "Hello! Could I have some water, please? And what snacks are available?",
                    context: "The cabin service is taking place. The passenger asks for a drink and information about snacks."),
        FlightStage(id: "issue", title: "5. Ситуация в полёте", focus: "Жалобы, тревога и помощь", personality: .upset,
                    openingLine: "Excuse me, I don't feel comfortable. The passenger next to me is making a lot of noise. Could you help?",
                    context: "During the flight, a passenger raises a concern. Respond calmly and seek appropriate help when required."),
        FlightStage(id: "arrival", title: "6. Прибытие", focus: "Подготовка к прибытию и пересадки", personality: .confused,
                    openingLine: "We are arriving soon, right? Could you tell me where I should go for my connecting flight?",
                    context: "The aircraft is preparing for arrival. The passenger asks about their next steps and a connection. Do not invent gate numbers or operational information.")
    ]
}

struct CorrectionItem: Codable, Identifiable {
    var id: UUID = UUID()
    var original: String
    var corrected: String
    var explanationRU: String

    enum CodingKeys: String, CodingKey { case original, corrected, explanationRU = "explanation_ru" }
}

struct VocabularySuggestion: Codable, Identifiable {
    var id: UUID = UUID()
    var term: String
    var translationRU: String
    var exampleEN: String

    enum CodingKeys: String, CodingKey { case term, translationRU = "translation_ru", exampleEN = "example_en" }
}

struct VocabularyItem: Codable, Identifiable {
    var id: UUID = UUID()
    var term: String
    var translationRU: String
    var exampleEN: String
    var addedAt: Date = Date()
    var isLearned: Bool = false
    var repetitions: Int = 0
}

struct SessionReview: Codable {
    var score: Int
    var communication: String
    var grammar: String
    var vocabulary: String
    var strengths: [String]
    var focusAreas: [String]
    var modelAnswer: String
    var corrections: [CorrectionItem]
    var drillPhrases: [String]
    var vocabularyItems: [VocabularySuggestion]?
}

struct ChatMessage: Identifiable, Codable {
    var id: UUID
    var role: ChatRole
    var text: String
    var speechText: String?
    var createdAt: Date
    var corrections: [CorrectionItem]?
    var vocabulary: [VocabularySuggestion]?
    var phrase: String?
    var score: Int?

    init(role: ChatRole, text: String, speechText: String? = nil,
         corrections: [CorrectionItem]? = nil, vocabulary: [VocabularySuggestion]? = nil,
         phrase: String? = nil, score: Int? = nil) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.speechText = speechText
        self.createdAt = Date()
        self.corrections = corrections
        self.vocabulary = vocabulary
        self.phrase = phrase
        self.score = score
    }
}

struct LessonSession: Identifiable, Codable {
    var id: UUID
    var startedAt: Date
    var endedAt: Date?
    var messages: [ChatMessage]
    // Optional fields preserve compatibility with session-history files created by MVP 0.1–0.3.
    var trainingMode: TrainingMode?
    var trainingLevel: TrainingLevel?
    var scenarioID: String?
    var scenarioTitle: String?
    var personality: PassengerPersonality?
    var flightStageIndex: Int?
    var review: SessionReview?
    // Foreground practice time, accumulated by LessonStore. Optional for older history files.
    var activeDurationSeconds: TimeInterval?

    var duration: TimeInterval {
        if let tracked = activeDurationSeconds {
            return min(10 * 60, max(0, tracked))
        }
        // Legacy migration: never count time spent with the app closed or idle after the last message.
        guard messages.contains(where: { $0.role == .user }) else { return 0 }
        let lastActivity = messages.map(\.createdAt).max() ?? startedAt
        return min(10 * 60, max(0, lastActivity.timeIntervalSince(startedAt)))
    }
}

struct LearningProgress {
    let completedLessons: Int
    let totalMinutes: Int
    let spokenTurns: Int
    let averageScore: Int?
    let vocabularyCount: Int
    let learnedVocabularyCount: Int
    let focusAreas: [String]
}

struct RouterModel: Identifiable, Decodable, Hashable {
    let id: String
    let name: String?
    let ownedBy: String?
    let pricing: RouterPricing?

    enum CodingKeys: String, CodingKey {
        case id, name, pricing
        case ownedBy = "owned_by"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try? c.decode(String.self, forKey: .name)
        ownedBy = try? c.decode(String.self, forKey: .ownedBy)
        pricing = try? c.decode(RouterPricing.self, forKey: .pricing)
    }

    var displayName: String { name ?? id }
}

/// Prices are USD per million tokens when the provider exposes them in /models.
struct RouterPricing: Decodable, Hashable {
    let input: Double?
    let output: Double?
    let cacheReadInput: Double?
    let cacheWriteInput: Double?

    enum CodingKeys: String, CodingKey {
        case input, output, prompt, completion
        case cacheReadInput = "cache_read_input"
        case cacheWriteInput = "cache_write_input"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        input = Self.number(c, [.input, .prompt])
        output = Self.number(c, [.output, .completion])
        cacheReadInput = Self.number(c, [.cacheReadInput])
        cacheWriteInput = Self.number(c, [.cacheWriteInput])
    }

    private static func number(_ c: KeyedDecodingContainer<CodingKeys>, _ keys: [CodingKeys]) -> Double? {
        for key in keys {
            if let value = try? c.decode(Double.self, forKey: key) { return value }
            if let value = try? c.decode(String.self, forKey: key), let parsed = Double(value) { return parsed }
        }
        return nil
    }
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

    struct Usage: Decodable {
        struct PromptDetails: Decodable {
            let cachedTokens: Int?
            enum CodingKeys: String, CodingKey { case cachedTokens = "cached_tokens" }
        }

        let promptTokens: Int?
        let completionTokens: Int?
        let totalTokens: Int?
        let promptTokensDetails: PromptDetails?
        let costUSD: Double?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
            case promptTokensDetails = "prompt_tokens_details"
            case costUSD = "cost"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            promptTokens = try? c.decode(Int.self, forKey: .promptTokens)
            completionTokens = try? c.decode(Int.self, forKey: .completionTokens)
            totalTokens = try? c.decode(Int.self, forKey: .totalTokens)
            promptTokensDetails = try? c.decode(PromptDetails.self, forKey: .promptTokensDetails)
            if let number = try? c.decode(Double.self, forKey: .costUSD) {
                costUSD = number
            } else if let string = try? c.decode(String.self, forKey: .costUSD) {
                costUSD = Double(string)
            } else {
                costUSD = nil
            }
        }
    }

    let choices: [Choice]
    let usage: Usage?
}

struct AIResponsePayload: Decodable {
    let reply: String?
    let feedbackRU: String?
    let corrections: [CorrectionItem]?
    let usefulPhrase: String?
    let vocabulary: [VocabularySuggestion]?
    let score: Int?

    enum CodingKeys: String, CodingKey {
        case reply
        case feedbackRU = "feedback_ru"
        case corrections
        case usefulPhrase = "useful_phrase"
        case vocabulary
        case score
    }
}

struct ParsedTutorReply {
    let displayText: String
    let spokenText: String
    let corrections: [CorrectionItem]
    let vocabulary: [VocabularySuggestion]
    let phrase: String?
    let score: Int?

    static func parse(_ raw: String) -> ParsedTutorReply {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonText: String
        if let first = trimmed.firstIndex(of: "{"), let last = trimmed.lastIndex(of: "}"), first <= last {
            jsonText = String(trimmed[first...last])
        } else {
            jsonText = trimmed
        }

        if let data = jsonText.data(using: .utf8), let payload = try? JSONDecoder().decode(AIResponsePayload.self, from: data),
           let reply = payload.reply, !reply.isEmpty {
            // Backward-compatible guard: even if an older model returns feedback JSON,
            // never display per-turn corrections. Feedback is reserved for end-of-lesson review.
            return ParsedTutorReply(displayText: reply, spokenText: reply,
                                    corrections: [], vocabulary: [], phrase: nil, score: nil)
        }

        // Safe fallback for providers/models that return plain text instead of the requested JSON.
        return ParsedTutorReply(displayText: trimmed, spokenText: trimmed, corrections: [], vocabulary: [], phrase: nil, score: nil)
    }
}


struct GeneratedScenarioBatch: Decodable {
    struct Item: Decodable {
        let title: String
        let category: String
        let personality: String
        let summary: String
        let openingLine: String
        let context: String

        enum CodingKeys: String, CodingKey {
            case title, category, personality, summary, context
            case openingLine = "opening_line"
        }
    }
    let scenarios: [Item]
}

import Foundation
import Combine
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@MainActor
final class TutorService: ObservableObject {
    @Published var isSending = false
    @Published var isLoadingModels = false
    @Published var errorMessage: String?
    @Published var connectionStatus: String?
    @Published private(set) var models: [RouterModel] = []
    let usageStore = APIUsageStore()

    private var responseCache: [String: CachedChatCompletion] = [:]
    private let responseCacheURL: URL = {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("EnglishAITutor", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("api-response-cache.json")
    }()

    init() {
        if let data = try? Data(contentsOf: responseCacheURL),
           let saved = try? JSONDecoder().decode([String: CachedChatCompletion].self, from: data) {
            responseCache = saved.filter { Date().timeIntervalSince($0.value.savedAt) < 48 * 60 * 60 }
        }
    }

    func loadModels(baseURL: String, apiKey: String) async {
        isLoadingModels = true
        connectionStatus = nil
        errorMessage = nil
        defer { isLoadingModels = false }

        do {
            let url = try makeEndpoint(baseURL: baseURL, path: "models")
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 30
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response: response, data: data)
            let decoded = try JSONDecoder().decode(RouterModelsResponse.self, from: data)
            let sorted = decoded.data.sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
            guard !sorted.isEmpty else { throw TutorError.message("API ответил успешно, но список моделей пуст.") }
            models = sorted
            for item in sorted { usageStore.importRates(item.pricing, for: item.id) }
            connectionStatus = "Подключение успешно. Доступно моделей: \(sorted.count)."
        } catch {
            connectionStatus = nil
            errorMessage = error.localizedDescription
        }
    }

    func recommendedModelID() -> String? {
        recommendedReviewModelID()
    }

    func recommendedRoleplayModelID() -> String? {
        let pricedCandidates = models.compactMap { item -> (id: String, score: Double)? in
            guard let rates = usageStore.rates(for: item.id) else { return nil }
            return (item.id, rates.inputPerMillion + rates.outputPerMillion * 2.0)
        }
        if let cheapest = pricedCandidates.min(by: { $0.score < $1.score }) { return cheapest.id }

        let preferredTerms = ["haiku", "flash", "mini", "nano", "small", "fast"]
        if let match = models.first(where: { item in
            let id = item.id.lowercased()
            return preferredTerms.contains(where: { id.contains($0) })
        }) { return match.id }
        return models.first(where: { !$0.id.localizedCaseInsensitiveContains("opus")
            && !$0.id.localizedCaseInsensitiveContains("sonnet") })?.id ?? models.first?.id
    }

    func recommendedReviewModelID() -> String? {
        if let sonnet = models.first(where: {
            $0.id.localizedCaseInsensitiveContains("claude") && $0.id.localizedCaseInsensitiveContains("sonnet")
        }) { return sonnet.id }
        if let claude = models.first(where: { $0.id.localizedCaseInsensitiveContains("claude") }) { return claude.id }
        return models.first?.id
    }

    func reply(to transcript: String, history: [ChatMessage], model: String,
               baseURL: String, apiKey: String, mode: TrainingMode,
               level: TrainingLevel, scenario: TrainingScenario?, flightStage: FlightStage?) async throws -> ParsedTutorReply {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TutorError.message("Добавь API-ключ в настройках.")
        }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TutorError.message("Сначала выбери модель в настройках.")
        }
        isSending = true
        defer { isSending = false }

        let systemPrompt = makeRoleplayPrompt(mode: mode, level: level, scenario: scenario, flightStage: flightStage)
        var messages: [OpenAIChatRequest.Message] = [.init(role: "system", content: systemPrompt)]
        for item in history.suffix(8) {
            let content = item.role == .assistant ? (item.speechText ?? item.text) : item.text
            messages.append(.init(role: item.role == .user ? "user" : "assistant", content: content))
        }
        messages.append(.init(role: "user", content: transcript))
        let raw = try await sendChat(messages: messages, model: model, baseURL: baseURL, apiKey: apiKey,
                                     temperature: 0.55, maxTokens: 420, purpose: "Диалог с пассажиром")
        return ParsedTutorReply.parse(raw)
    }

    func generateLessonReview(for session: LessonSession, model: String,
                              baseURL: String, apiKey: String) async throws -> SessionReview {
        guard !apiKey.isEmpty else { throw TutorError.message("Для итогового разбора нужен API-ключ Router.cheap.") }
        let mode = session.trainingMode ?? .passenger
        let level = session.trainingLevel ?? .a2
        let transcript = session.messages.suffix(24).map { message in
            let role = message.role == .user ? "LEARNER" : "AI ROLE"
            let text = message.role == .assistant ? (message.speechText ?? message.text) : message.text
            return "\(role): \(text)"
        }.joined(separator: "\n")

        let prompt = """
        You are an English teacher assessing a short speaking role-play for cabin-crew work.
        Mode: \(mode.title). Learner level: \(level.rawValue). The target is practical B1 English.
        Assess ONLY communication, grammar, vocabulary, clarity of the written transcript, and suitability of phrases for the situation.
        Do NOT assess pronunciation, accent, phonetics, voice quality, or speaking speed. We do not have reliable pronunciation analysis.
        Be fair: the transcript may contain speech-recognition mistakes. Do not treat an obviously implausible transcription as a definite learner error.
        Return ONLY valid JSON with this exact shape:
        {
          "score": 7,
          "communication": "Brief Russian assessment of how effectively the learner handled the situation.",
          "grammar": "Brief Russian assessment of grammar, with concrete examples.",
          "vocabulary": "Brief Russian assessment of vocabulary and useful cabin-crew language.",
          "strengths": ["..."],
          "focus_areas": ["..."],
          "model_answer": "A concise improved English example the learner could have said.",
          "corrections": [{"original":"...","corrected":"...","explanation_ru":"..."}],
          "drill_phrases": ["...", "..."],
          "vocabulary_items": [{"term":"...", "translation_ru":"...", "example_en":"..."}]
        }
        Score from 1 to 10. Do not invent problems when there are none. No pronunciation advice.
        Include up to 5 genuinely useful cabin-crew words or phrases in vocabulary_items. Do not include basic words.
        Conversation:
        \(transcript)
        """
        let raw = try await sendChat(messages: [.init(role: "system", content: prompt)], model: model,
                                     baseURL: baseURL, apiKey: apiKey, temperature: 0.2, maxTokens: 850, purpose: "Итоговый разбор")
        let dataText = extractJSON(from: raw)
        guard let data = dataText.data(using: .utf8) else { throw TutorError.message("Не удалось прочитать итоговый разбор.") }
        let payload = try JSONDecoder().decode(SessionReviewPayload.self, from: data)
        return SessionReview(
            score: min(10, max(1, payload.score ?? 5)),
            communication: payload.communication ?? "Разбор не получен.",
            grammar: payload.grammar ?? "Нет данных.",
            vocabulary: payload.vocabulary ?? "Нет данных.",
            strengths: payload.strengths ?? [],
            focusAreas: payload.focusAreas ?? [],
            modelAnswer: payload.modelAnswer ?? "",
            corrections: payload.corrections ?? [],
            drillPhrases: payload.drillPhrases ?? [],
            vocabularyItems: payload.vocabularyItems ?? []
        )
    }

    func generateScenarios(model: String, baseURL: String, apiKey: String, count: Int = 4) async throws -> [TrainingScenario] {
        let prompt = """
        Create exactly \(min(max(count, 2), 5)) varied English-learning role-play scenarios for a learner training to become an airline flight attendant.
        The learner is always the cabin crew member; the AI is always a passenger.
        Keep this language practice only. Never write emergency procedures or authoritative airline operational instructions.
        Use passenger personality values from this exact list: friendly, confused, impatient, nervous, upset, demanding, family.
        Each scenario must have a realistic but safe situation, a natural English opening line at A2/B1 level, and a concise context.
        Return ONLY JSON: {"scenarios":[{"title":"...","category":"...","personality":"confused","summary":"...","opening_line":"...","context":"..."}]}
        No markdown, no extra fields.
        """
        let raw = try await sendChat(messages: [.init(role: "system", content: prompt)], model: model,
                                     baseURL: baseURL, apiKey: apiKey, temperature: 0.7,
                                     maxTokens: 1250, purpose: "Генерация сценариев", cacheResponse: false)
        guard let data = extractJSON(from: raw).data(using: .utf8) else {
            throw TutorError.message("Не удалось прочитать сгенерированные сценарии.")
        }
        let batch = try JSONDecoder().decode(GeneratedScenarioBatch.self, from: data)
        let valid = batch.scenarios.compactMap { item -> TrainingScenario? in
            guard let personality = PassengerPersonality(rawValue: item.personality),
                  !item.title.isEmpty, !item.openingLine.isEmpty else { return nil }
            return TrainingScenario(id: "ai-\(UUID().uuidString)", title: item.title,
                                    category: item.category, personality: personality,
                                    summary: item.summary, openingLine: item.openingLine,
                                    context: item.context)
        }
        guard !valid.isEmpty else { throw TutorError.message("Модель не вернула корректных сценариев. Попробуй ещё раз.") }
        return valid
    }

    func checkCorrectionAttempt(_ attempt: String, target: String, model: String,
                                baseURL: String, apiKey: String) async throws -> String {
        let prompt = """
        You are a concise English grammar coach. The learner is practising a corrected sentence.
        Target sentence: "\(target)"
        Learner attempt: "\(attempt)"
        Compare grammar and word choice only. Do NOT assess pronunciation, accent, phonetics or voice quality.
        Speech recognition may have made a transcription error, so be cautious.
        Reply in Russian in 2-4 short sentences. Say whether the attempt is grammatically correct, show the best version if needed, and explain one key point. Do not continue a role-play.
        """
        return try await sendChat(messages: [.init(role: "system", content: prompt),
                                             .init(role: "user", content: attempt)],
                                 model: model, baseURL: baseURL, apiKey: apiKey,
                                 temperature: 0.2, maxTokens: 260, purpose: "Тренировка исправленной фразы")
    }

    private func makeRoleplayPrompt(mode: TrainingMode, level: TrainingLevel,
                                    scenario: TrainingScenario?, flightStage: FlightStage?) -> String {
        let levelInstruction = level.instruction
        let role: String
        let context: String
        switch mode {
        case .passenger:
            let selected = scenario ?? ScenarioCatalog.scenarios[0]
            role = "You are role-playing as an AIRLINE PASSENGER. The learner is the FLIGHT ATTENDANT / CABIN CREW MEMBER. This role assignment is strict and must never be reversed."
            context = "Scenario: \(selected.title). Category: \(selected.category). Passenger personality: \(selected.personality.title). \(selected.personality.instruction) Situation: \(selected.context)"
        case .interview:
            role = "You are an AIRLINE RECRUITER conducting a cabin-crew job interview. The learner is the CANDIDATE. Never reverse these roles."
            context = "Interview mode: ask realistic recruitment questions one at a time about motivation, customer service, teamwork, conflict resolution, flexibility and practical cabin-crew situations. Start with an invitation to introduce themselves. Ask follow-up questions based on the learner's answers. Do not supply a model answer before the learner attempts one."
        case .fullFlight:
            let stage = flightStage ?? FullFlightCatalog.stages[0]
            role = "You are role-playing as a PASSENGER during a simulated airline flight. The learner is a FLIGHT ATTENDANT / CABIN CREW MEMBER. Never reverse these roles."
            context = "Full flight simulation stage: \(stage.title). Focus: \(stage.focus). Passenger personality: \(stage.personality.title). \(stage.personality.instruction) Situation: \(stage.context)"
        }

        return """
        You are a realistic, respectful English role-play partner for a learner preparing for work as an airline cabin crew member.
        \(role)
        Learner's current level: \(level.rawValue). \(levelInstruction)
        \(context)

        ROLE-PLAY RULES:
        - Speak ONLY as your assigned in-character role. The learner is practising a live conversation.
        - Keep each response concise: usually 1-2 natural English sentences, maximum 3.
        - Ask one question or make one request at a time. Let the learner solve the situation.
        - If the learner's answer is unclear, ask a natural follow-up question. Do not teach, correct, grade, translate or explain during the conversation.
        - Never mention grammar mistakes, vocabulary mistakes, scores, corrections or learning feedback in any turn.
        - Never invent airline operating information, gate numbers, delays, seat availability, ingredients, medical advice or official safety procedures. In uncertain situations, allow the learner to say they will check with a colleague or consult official information.
        - Safety-related situations are language practice only. Do not suggest bypassing rules or replacing airline training.

        OUTPUT:
        Return ONLY the next in-character response in English as plain text.
        Do not return JSON, headings, Russian text, corrections, feedback, vocabulary lists or scores.
        This is a role-play turn, NOT a lesson review. A full grammar and vocabulary review will happen only once, after the learner ends the lesson.
        """
    }

    private func sendChat(messages: [OpenAIChatRequest.Message], model: String, baseURL: String,
                          apiKey: String, temperature: Double, maxTokens: Int,
                          purpose: String, cacheResponse: Bool = true) async throws -> String {
        let cacheKey = makeCacheKey(messages: messages, model: model,
                                    temperature: temperature, maxTokens: maxTokens)
        if cacheResponse, let cached = responseCache[cacheKey], Date().timeIntervalSince(cached.savedAt) < 48 * 60 * 60 {
            return cached.content
        }

        let reservationID = try usageStore.reserve(model: model, messages: messages,
                                                   maxOutputTokens: maxTokens, purpose: purpose)
        do {
            let url = try makeEndpoint(baseURL: baseURL, path: "chat/completions")
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 90
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(
                OpenAIChatRequest(model: model, messages: messages, temperature: temperature, max_tokens: maxTokens)
            )
            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response: response, data: data)
            let decoded: OpenAIChatResponse
            do {
                decoded = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)
            } catch {
                // The HTTP request succeeded, so keep a conservative estimate even if the body is malformed.
                usageStore.settle(reservationID, usage: nil)
                throw TutorError.message("Не удалось разобрать ответ API. Расход запроса учтён по резервной оценке.")
            }
            guard let content = decoded.choices.first?.message.content,
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                usageStore.settle(reservationID, usage: decoded.usage)
                throw TutorError.message("Модель вернула пустой ответ. Расход запроса учтён.")
            }
            usageStore.settle(reservationID, usage: decoded.usage)
            if cacheResponse {
                responseCache[cacheKey] = CachedChatCompletion(key: cacheKey, content: content, savedAt: Date())
                if responseCache.count > 80 {
                    let retained = responseCache.sorted { $0.value.savedAt > $1.value.savedAt }.prefix(80)
                    responseCache = Dictionary(uniqueKeysWithValues: retained.map { ($0.key, $0.value) })
                }
                persistResponseCache()
            }
            return content
        } catch {
            usageStore.release(reservationID)
            throw error
        }
    }

    private func makeCacheKey(messages: [OpenAIChatRequest.Message], model: String,
                              temperature: Double, maxTokens: Int) -> String {
        let body = "\(model)|\(temperature)|\(maxTokens)|" + messages.map { "\($0.role):\($0.content)" }.joined(separator: "\n")
        // Stable FNV-1a hash so cached keys survive app restarts without external dependencies.
        var hash: UInt64 = 14695981039346656037
        for byte in Data(body.utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return String(format: "%016llx", hash)
    }

    private func persistResponseCache() {
        guard let data = try? JSONEncoder().encode(responseCache) else { return }
        try? data.write(to: responseCacheURL, options: .atomic)
    }

    private func makeEndpoint(baseURL: String, path: String) throws -> URL {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { throw TutorError.message("Укажи адрес API.") }
        if !base.hasSuffix("/v1") { base += "/v1" }
        guard let url = URL(string: base + "/" + path), url.scheme == "https", url.host != nil else {
            throw TutorError.message("Некорректный HTTPS-адрес API.")
        }
        return url
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw TutorError.message("Сервер не вернул HTTP-ответ.") }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Не удалось прочитать тело ответа."
            throw TutorError.message("HTTP \(http.statusCode): \(body.prefix(700))")
        }
    }

    private func extractJSON(from raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = text.firstIndex(of: "{"), let last = text.lastIndex(of: "}"), first <= last else { return text }
        return String(text[first...last])
    }
}

private struct SessionReviewPayload: Decodable {
    let score: Int?
    let communication: String?
    let grammar: String?
    let vocabulary: String?
    let strengths: [String]?
    let focusAreas: [String]?
    let modelAnswer: String?
    let corrections: [CorrectionItem]?
    let drillPhrases: [String]?
    let vocabularyItems: [VocabularySuggestion]?

    enum CodingKeys: String, CodingKey {
        case score, communication, grammar, vocabulary, strengths, corrections
        case focusAreas = "focus_areas"
        case modelAnswer = "model_answer"
        case drillPhrases = "drill_phrases"
        case vocabularyItems = "vocabulary_items"
    }
}

enum TutorError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return "Неизвестная ошибка."
    }
}

struct ModelTokenRates: Codable, Hashable {
    var inputPerMillion: Double
    var outputPerMillion: Double
    var cacheReadPerMillion: Double?
}

struct APIUsageEntry: Codable, Identifiable {
    let id: UUID
    let date: Date
    let model: String
    let purpose: String
    let inputTokens: Int
    let outputTokens: Int
    let costUSD: Double
    let isEstimate: Bool
}

@MainActor
final class APIUsageStore: ObservableObject {
    @Published private(set) var entries: [APIUsageEntry] = []
    @Published private(set) var ratesByModel: [String: ModelTokenRates] = [:]
    @Published private(set) var dailyBudgetUSD: Double = 1.00

    private struct Reservation {
        let model: String
        let purpose: String
        let inputTokens: Int
        let outputTokens: Int
        let costUSD: Double
    }

    private struct Persisted: Codable {
        var entries: [APIUsageEntry]
        var ratesByModel: [String: ModelTokenRates]
        var dailyBudgetUSD: Double
    }

    private var reservations: [UUID: Reservation] = [:]
    private let fileURL: URL

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("EnglishAITutor", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("api-usage.json")
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode(Persisted.self, from: data) {
            entries = saved.entries
            ratesByModel = saved.ratesByModel
            dailyBudgetUSD = max(0.01, saved.dailyBudgetUSD)
        }
    }

    var spentTodayUSD: Double {
        entries.filter { Calendar.current.isDateInToday($0.date) }.reduce(0) { $0 + $1.costUSD }
    }

    var inputTokensToday: Int {
        entries.filter { Calendar.current.isDateInToday($0.date) }.reduce(0) { $0 + $1.inputTokens }
    }

    var outputTokensToday: Int {
        entries.filter { Calendar.current.isDateInToday($0.date) }.reduce(0) { $0 + $1.outputTokens }
    }

    var reservedTodayUSD: Double { reservations.values.reduce(0) { $0 + $1.costUSD } }

    func setDailyBudget(_ amount: Double) {
        dailyBudgetUSD = min(100, max(0.01, amount))
        persist()
    }

    func rates(for model: String) -> ModelTokenRates? { ratesByModel[model] }

    func setRates(_ rates: ModelTokenRates, for model: String) {
        guard rates.inputPerMillion >= 0, rates.outputPerMillion >= 0 else { return }
        ratesByModel[model] = rates
        persist()
    }

    func importRates(_ pricing: RouterPricing?, for model: String) {
        guard let pricing, let input = pricing.input, let output = pricing.output else { return }
        setRates(ModelTokenRates(inputPerMillion: input, outputPerMillion: output,
                                 cacheReadPerMillion: pricing.cacheReadInput), for: model)
    }

    func reserve(model: String, messages: [OpenAIChatRequest.Message], maxOutputTokens: Int,
                 purpose: String) throws -> UUID {
        guard let rates = ratesByModel[model] else {
            throw TutorError.message("Для модели \(model) не заданы цены. Открой настройки и укажи стоимость входных и выходных токенов за 1 млн — иначе приложение не сможет оценивать расходы и останавливать запросы по бюджету.")
        }
        // Conservative character-based estimate with a 25% safety margin.
        // Actual token counts from the API response replace this estimate after success.
        let characterCount = messages.reduce(0) { $0 + $1.content.count }
        let estimatedInput = Int(ceil(Double(characterCount) / 3.0 * 1.25)) + messages.count * 8 + 32
        let outputReservation = max(1, maxOutputTokens)
        let estimate = (Double(estimatedInput) * rates.inputPerMillion
                        + Double(outputReservation) * rates.outputPerMillion) / 1_000_000
        let alreadyCommitted = spentTodayUSD + reservedTodayUSD
        guard alreadyCommitted + estimate <= dailyBudgetUSD else {
            let remaining = max(0, dailyBudgetUSD - alreadyCommitted)
            throw TutorError.message(String(format: "Дневной лимит API почти исчерпан. Осталось примерно $%.4f, а для следующего запроса нужно зарезервировать около $%.4f. Лимит обновится завтра.", remaining, estimate))
        }
        let id = UUID()
        reservations[id] = Reservation(model: model, purpose: purpose,
                                       inputTokens: estimatedInput, outputTokens: outputReservation,
                                       costUSD: estimate)
        return id
    }

    func release(_ reservationID: UUID) { reservations.removeValue(forKey: reservationID) }

    func settle(_ reservationID: UUID, usage: OpenAIChatResponse.Usage?) {
        guard let reservation = reservations.removeValue(forKey: reservationID) else { return }
        let input = usage?.promptTokens ?? reservation.inputTokens
        let output = usage?.completionTokens ?? reservation.outputTokens
        let rates = ratesByModel[reservation.model]
        let calculated: Double
        if let providerCost = usage?.costUSD, providerCost >= 0 {
            calculated = providerCost
        } else if let rates {
            let cached = min(input, max(0, usage?.promptTokensDetails?.cachedTokens ?? 0))
            let uncached = max(0, input - cached)
            let inputCost = Double(uncached) * rates.inputPerMillion
                + Double(cached) * (rates.cacheReadPerMillion ?? rates.inputPerMillion)
            calculated = (inputCost + Double(output) * rates.outputPerMillion) / 1_000_000
        } else {
            calculated = reservation.costUSD
        }
        let entry = APIUsageEntry(id: UUID(), date: Date(), model: reservation.model,
                                  purpose: reservation.purpose, inputTokens: input,
                                  outputTokens: output, costUSD: max(0, calculated),
                                  isEstimate: usage?.costUSD == nil)
        entries.append(entry)
        if entries.count > 1000 { entries.removeFirst(entries.count - 1000) }
        persist()
    }

    private func persist() {
        let data = Persisted(entries: entries, ratesByModel: ratesByModel,
                             dailyBudgetUSD: dailyBudgetUSD)
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        try? encoded.write(to: fileURL, options: .atomic)
    }
}

private struct CachedChatCompletion: Codable {
    let key: String
    let content: String
    let savedAt: Date
}

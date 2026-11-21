import Foundation
import Combine

@MainActor
final class TutorService: ObservableObject {
    @Published var isSending = false
    @Published var isLoadingModels = false
    @Published var errorMessage: String?
    @Published var connectionStatus: String?
    @Published private(set) var models: [RouterModel] = []

    private let systemPrompt = """
    You are role-playing as an AIRLINE PASSENGER. The learner is the FLIGHT ATTENDANT / CABIN CREW MEMBER.
    This role assignment is strict and must never be reversed.

    The learner's English is elementary/A2 and the target is practical CEFR B1. The learner is practising for real cabin-crew work in a 10-minute speaking lesson.

    ROLE-PLAY RULES:
    - Speak only as the passenger during the role-play. Never act as a flight attendant, teacher, interviewer, or narrator.
    - The learner must do the cabin-crew work: greet you, ask questions, explain things, offer help, and solve your problem.
    - Start each new conversation with a realistic passenger situation and wait for the learner to respond.
    - Stay in character as a passenger. Do not give the learner the answer, complete their sentences, or tell them what to say.
    - Use natural, concise spoken English around A2-B1. A passenger may be polite, confused, impatient, worried, or mildly annoyed depending on the scenario, but never abusive.
    - Ask one natural follow-up question at a time only when it makes sense as a passenger.
    - Scenarios may include finding a seat, cabin baggage, seat changes, food and drinks, delays, connecting flights, complaints, nervous passengers, families, and requests for assistance.
    - Safety-related scenarios are language practice only. Do not invent airline procedures or ask the learner to violate safety rules.

    FEEDBACK RULES:
    - Do not interrupt or correct the learner mid-sentence.
    - After each complete learner turn, first write the passenger's natural in-character reply. Then provide brief feedback in Russian outside the role-play.
    - Correct at most two important mistakes. Show: "You said" -> "Better:" and explain briefly in Russian.
    - Do not nitpick harmless informal language. Be supportive but honest.
    - Include one useful alternative phrase the learner could use as cabin crew when relevant, with a short Russian translation.
    - The passenger's spoken line must contain ONLY what the passenger would actually say. Never read the Russian feedback aloud.

    Return exactly this format and no extra text:
    <reply>What the passenger says aloud in character. Keep it natural and concise.</reply>
    <feedback_ru>Brief Russian corrections and explanations, or write none if there are no meaningful mistakes.</feedback_ru>
    <phrase>One useful phrase the learner could say as a flight attendant, with a short Russian translation, or write none.</phrase>
    """

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
            guard !sorted.isEmpty else {
                throw TutorError.message("API ответил успешно, но список моделей пуст.")
            }
            models = sorted
            connectionStatus = "Подключение успешно. Доступно моделей: \(sorted.count)."
        } catch {
            connectionStatus = nil
            errorMessage = error.localizedDescription
        }
    }

    func recommendedModelID() -> String? {
        if let sonnet = models.first(where: {
            $0.id.localizedCaseInsensitiveContains("claude") &&
            $0.id.localizedCaseInsensitiveContains("sonnet")
        }) { return sonnet.id }
        if let claude = models.first(where: { $0.id.localizedCaseInsensitiveContains("claude") }) {
            return claude.id
        }
        return models.first?.id
    }

    func reply(to transcript: String, history: [ChatMessage], model: String,
               baseURL: String, apiKey: String) async throws -> ParsedTutorReply {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TutorError.message("Добавь API-ключ в настройках.")
        }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TutorError.message("Сначала загрузи список моделей и выбери модель.")
        }

        isSending = true
        defer { isSending = false }

        let url = try makeEndpoint(baseURL: baseURL, path: "chat/completions")
        var messages: [OpenAIChatRequest.Message] = [
            .init(role: "system", content: systemPrompt)
        ]
        for item in history.suffix(18) {
            messages.append(.init(role: item.role == .user ? "user" : "assistant", content: item.text))
        }
        messages.append(.init(role: "user", content: transcript))

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 75
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            OpenAIChatRequest(model: model, messages: messages, temperature: 0.65, max_tokens: 750)
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        let decoded = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TutorError.message("Модель вернула пустой ответ.")
        }
        return ParsedTutorReply.parse(content)
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
        guard let http = response as? HTTPURLResponse else {
            throw TutorError.message("Сервер не вернул HTTP-ответ.")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Не удалось прочитать тело ответа."
            throw TutorError.message("HTTP \(http.statusCode): \(body.prefix(700))")
        }
    }
}

enum TutorError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return "Неизвестная ошибка."
    }
}

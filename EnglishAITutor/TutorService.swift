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
    You are a patient, professional English conversation coach preparing a learner for work as an airline cabin crew member.
    The learner's current English is elementary/A2. The target is practical CEFR B1, gradually progressing toward B2.
    The learner has selected a 10-minute speaking lesson. Speak naturally and keep your spoken replies clear, concise, and around A2-B1.
    Run realistic role-plays: welcoming passengers, finding seats, cabin baggage, food and drinks, delays, complaints, teamwork, job interviews, and safety-related communication.
    Ask ONE question at a time and keep the role-play moving. Do not give the learner a ready-made answer before they try.
    Do not interrupt the learner or correct them mid-sentence. After each complete learner turn, respond to the meaning first, then provide brief feedback in Russian.
    Correct at most two important mistakes per turn. Do not nitpick harmless informal language. Explain why a correction is better in simple Russian.
    Include one useful cabin-crew phrase when it fits naturally. Be supportive but honest; do not claim the learner is fluent or certified.
    For safety situations, teach English wording only. Never invent or replace an airline's official safety procedures.

    Return exactly this format and no extra text:
    <reply>Natural English response that should be spoken aloud. Include a short follow-up question.</reply>
    <feedback_ru>Brief Russian corrections and explanations, or write none if there are no meaningful mistakes.</feedback_ru>
    <phrase>One useful English cabin-crew phrase with a short Russian translation, or write none.</phrase>
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

import Foundation
import Combine

@MainActor
final class LessonStore: ObservableObject {
    static let lessonLength: TimeInterval = 10 * 60

    @Published private(set) var sessions: [LessonSession] = []
    @Published private(set) var activeSessionID: UUID?
    @Published private(set) var vocabulary: [VocabularyItem] = []
    @Published private(set) var customScenarios: [TrainingScenario] = []

    private let fileURL: URL
    private let vocabularyURL: URL
    private let scenariosURL: URL

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("EnglishAITutor", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("lesson-history.json")
        vocabularyURL = directory.appendingPathComponent("vocabulary.json")
        scenariosURL = directory.appendingPathComponent("custom-scenarios.json")
        load()
        loadVocabulary()
        loadScenarios()

        if let active = sessions.last(where: { $0.endedAt == nil }) {
            activeSessionID = active.id
            if Date().timeIntervalSince(active.startedAt) >= Self.lessonLength {
                finishCurrentSession()
                startNewSession()
            }
        } else {
            startNewSession()
        }
    }

    var currentSession: LessonSession? {
        guard let id = activeSessionID else { return nil }
        return sessions.first(where: { $0.id == id })
    }

    var currentMessages: [ChatMessage] { currentSession?.messages ?? [] }

    var availableScenarios: [TrainingScenario] { ScenarioCatalog.scenarios + customScenarios }

    func scenario(id: String?) -> TrainingScenario {
        availableScenarios.first(where: { $0.id == id }) ?? ScenarioCatalog.scenarios[0]
    }

    func addScenarios(_ items: [TrainingScenario]) {
        let existingIDs = Set(availableScenarios.map(\.id))
        customScenarios.append(contentsOf: items.filter { !existingIDs.contains($0.id) })
        persistScenarios()
    }

    var currentScenario: TrainingScenario? {
        guard let session = currentSession, (session.trainingMode ?? .passenger) == .passenger else { return nil }
        return scenario(id: session.scenarioID)
    }

    var currentFlightStage: FlightStage? {
        guard let session = currentSession, (session.trainingMode ?? .passenger) == .fullFlight else { return nil }
        let index = min(max(session.flightStageIndex ?? 0, 0), FullFlightCatalog.stages.count - 1)
        return FullFlightCatalog.stages[index]
    }

    var remainingSeconds: Int {
        guard let session = currentSession else { return 0 }
        return max(0, Int(Self.lessonLength - Date().timeIntervalSince(session.startedAt)))
    }

    var progress: LearningProgress {
        let completed = sessions.filter { $0.endedAt != nil }
        let totalMinutes = completed.reduce(0) { $0 + Int($1.duration / 60) }
        let spokenTurns = sessions.reduce(0) { $0 + $1.messages.filter { $0.role == .user }.count }
        let scores = completed.compactMap { $0.review?.score }
        let focus = completed.flatMap { $0.review?.focusAreas ?? [] }
        var counts: [String: Int] = [:]
        focus.forEach { counts[$0, default: 0] += 1 }
        let mostCommon = counts.sorted { $0.value > $1.value }.prefix(3).map { $0.key }
        return LearningProgress(completedLessons: completed.count,
                                totalMinutes: totalMinutes,
                                spokenTurns: spokenTurns,
                                averageScore: scores.isEmpty ? nil : scores.reduce(0, +) / scores.count,
                                vocabularyCount: vocabulary.count,
                                learnedVocabularyCount: vocabulary.filter { $0.isLearned }.count,
                                focusAreas: Array(mostCommon))
    }

    func session(id: UUID) -> LessonSession? { sessions.first(where: { $0.id == id }) }

    func append(_ message: ChatMessage) {
        guard let id = activeSessionID,
              let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].messages.append(message)
        if sessions[index].messages.count > 120 {
            sessions[index].messages.removeFirst(sessions[index].messages.count - 120)
        }
        persistSessions()
    }

    func finishCurrentSession() -> UUID? {
        guard let id = activeSessionID,
              let index = sessions.firstIndex(where: { $0.id == id }) else { return nil }
        if sessions[index].endedAt == nil {
            sessions[index].endedAt = Date()
            persistSessions()
        }
        activeSessionID = nil
        return id
    }

    func startNewSession(mode: TrainingMode = .passenger,
                         level: TrainingLevel = .a2,
                         scenarioID: String = ScenarioCatalog.scenarios[0].id) {
        if activeSessionID != nil { _ = finishCurrentSession() }

        let stageIndex = 0
        let scenario = self.scenario(id: scenarioID)
        let opening: String
        let selectedPersonality: PassengerPersonality?
        let selectedScenarioID: String?
        let selectedScenarioTitle: String?

        switch mode {
        case .passenger:
            opening = scenario.openingLine
            selectedPersonality = scenario.personality
            selectedScenarioID = scenario.id
            selectedScenarioTitle = scenario.title
        case .interview:
            opening = "Hello, and thank you for coming today. Could you tell me a little about yourself and why you want to become a flight attendant?"
            selectedPersonality = nil
            selectedScenarioID = nil
            selectedScenarioTitle = "Собеседование в авиакомпанию"
        case .fullFlight:
            opening = FullFlightCatalog.stages[stageIndex].openingLine
            selectedPersonality = FullFlightCatalog.stages[stageIndex].personality
            selectedScenarioID = nil
            selectedScenarioTitle = "Полный рейс"
        }

        let session = LessonSession(id: UUID(), startedAt: Date(), endedAt: nil,
                                    messages: [ChatMessage(role: .assistant, text: opening, speechText: opening)],
                                    trainingMode: mode, trainingLevel: level,
                                    scenarioID: selectedScenarioID, scenarioTitle: selectedScenarioTitle,
                                    personality: selectedPersonality,
                                    flightStageIndex: mode == .fullFlight ? stageIndex : nil,
                                    review: nil)
        sessions.append(session)
        if sessions.count > 60 { sessions.removeFirst(sessions.count - 60) }
        activeSessionID = session.id
        persistSessions()
    }

    @discardableResult
    func advanceFlightStage() -> Bool {
        guard let id = activeSessionID,
              let index = sessions.firstIndex(where: { $0.id == id }),
              (sessions[index].trainingMode ?? .passenger) == .fullFlight else { return false }
        let next = (sessions[index].flightStageIndex ?? 0) + 1
        guard next < FullFlightCatalog.stages.count else { return false }
        let stage = FullFlightCatalog.stages[next]
        sessions[index].flightStageIndex = next
        sessions[index].personality = stage.personality
        sessions[index].messages.append(ChatMessage(role: .assistant, text: stage.openingLine, speechText: stage.openingLine))
        persistSessions()
        return true
    }

    func saveReview(_ review: SessionReview, for sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].review = review
        persistSessions()
    }

    func addVocabulary(_ suggestions: [VocabularySuggestion]) {
        for suggestion in suggestions {
            let term = suggestion.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { continue }
            if let index = vocabulary.firstIndex(where: { $0.term.caseInsensitiveCompare(term) == .orderedSame }) {
                if vocabulary[index].exampleEN.isEmpty { vocabulary[index].exampleEN = suggestion.exampleEN }
                if vocabulary[index].translationRU.isEmpty { vocabulary[index].translationRU = suggestion.translationRU }
            } else {
                vocabulary.append(VocabularyItem(term: term,
                                                  translationRU: suggestion.translationRU,
                                                  exampleEN: suggestion.exampleEN))
            }
        }
        if vocabulary.count > 500 { vocabulary.removeFirst(vocabulary.count - 500) }
        persistVocabulary()
    }

    func setVocabularyLearned(_ id: UUID, learned: Bool) {
        guard let index = vocabulary.firstIndex(where: { $0.id == id }) else { return }
        vocabulary[index].isLearned = learned
        if learned { vocabulary[index].repetitions += 1 }
        persistVocabulary()
    }

    func removeVocabulary(_ id: UUID) {
        vocabulary.removeAll { $0.id == id }
        persistVocabulary()
    }

    func clearHistory() {
        sessions = sessions.filter { $0.id == activeSessionID }
        persistSessions()
    }

    private func loadScenarios() {
        guard let data = try? Data(contentsOf: scenariosURL),
              let decoded = try? JSONDecoder().decode([TrainingScenario].self, from: data) else { return }
        customScenarios = decoded
    }

    private func persistScenarios() {
        guard let data = try? JSONEncoder().encode(customScenarios) else { return }
        try? data.write(to: scenariosURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([LessonSession].self, from: data) else { return }
        sessions = decoded.sorted { $0.startedAt < $1.startedAt }
    }

    private func loadVocabulary() {
        guard let data = try? Data(contentsOf: vocabularyURL),
              let decoded = try? JSONDecoder().decode([VocabularyItem].self, from: data) else { return }
        vocabulary = decoded
    }

    private func persistSessions() {
        do {
            let data = try JSONEncoder().encode(sessions)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Local history errors must not interrupt an active speaking lesson.
        }
    }

    private func persistVocabulary() {
        do {
            let data = try JSONEncoder().encode(vocabulary)
            try data.write(to: vocabularyURL, options: .atomic)
        } catch {
            // Vocabulary persistence is isolated from the lesson flow.
        }
    }
}

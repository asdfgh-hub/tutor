import Foundation
import Combine

@MainActor
final class LessonStore: ObservableObject {
    static let lessonLength: TimeInterval = 10 * 60

    @Published private(set) var sessions: [LessonSession] = []
    @Published private(set) var activeSessionID: UUID?

    private let fileURL: URL
    private let openingLine = "Excuse me, could you help me, please? I can't find my seat. My boarding pass says 18A, but I don't know where to go."

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("EnglishAITutor", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("lesson-history.json")
        load()

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

    var currentMessages: [ChatMessage] {
        currentSession?.messages ?? []
    }

    var remainingSeconds: Int {
        guard let session = currentSession else { return 0 }
        return max(0, Int(Self.lessonLength - Date().timeIntervalSince(session.startedAt)))
    }

    func append(_ message: ChatMessage) {
        guard let id = activeSessionID,
              let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].messages.append(message)
        if sessions[index].messages.count > 100 {
            sessions[index].messages.removeFirst(sessions[index].messages.count - 100)
        }
        persist()
    }

    func finishCurrentSession() {
        guard let id = activeSessionID,
              let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        if sessions[index].endedAt == nil {
            sessions[index].endedAt = Date()
            persist()
        }
        activeSessionID = nil
    }

    func startNewSession() {
        if activeSessionID != nil { finishCurrentSession() }
        let session = LessonSession(
            id: UUID(),
            startedAt: Date(),
            endedAt: nil,
            messages: [ChatMessage(role: .assistant, text: openingLine, speechText: openingLine)]
        )
        sessions.append(session)
        if sessions.count > 40 { sessions.removeFirst(sessions.count - 40) }
        activeSessionID = session.id
        persist()
    }

    func clearHistory() {
        sessions = sessions.filter { $0.id == activeSessionID }
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([LessonSession].self, from: data) else { return }
        sessions = decoded.sorted { $0.startedAt < $1.startedAt }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(sessions)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // A failed local history write should not interrupt a speaking lesson.
        }
    }
}

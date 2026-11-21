import SwiftUI

struct ContentView: View {
    @StateObject private var speech = SpeechManager()
    @StateObject private var tutor = TutorService()
    @StateObject private var lessonStore = LessonStore()

    @AppStorage("tutor.model") private var model = ""
    @AppStorage("tutor.apiBase") private var apiBase = "https://router.cheap/v1"

    @State private var apiKey = KeychainStore.read() ?? ""
    @State private var showSettings = false
    @State private var showHistory = false
    @State private var showTranscript = true
    @State private var isSendingTranscript = false
    @State private var lessonFinishedAlert = false

    private var timerText: String {
        let seconds = lessonStore.remainingSeconds
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            ForEach(lessonStore.currentMessages) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                            }
                            if tutor.isSending {
                                HStack(spacing: 8) {
                                    ProgressView()
                                    Text("The passenger is thinking…")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                }
                                .padding(.horizontal)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: lessonStore.currentMessages.count) { _ in
                        if let last = lessonStore.currentMessages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }

                if showTranscript && (speech.isRecording || !speech.transcript.isEmpty) {
                    transcriptionPanel
                }

                controls
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }
                    .accessibilityLabel("Lesson history")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(apiKey: $apiKey, model: $model, apiBase: $apiBase, tutor: tutor)
            }
            .sheet(isPresented: $showHistory) {
                HistoryView(sessions: lessonStore.sessions)
            }
            .alert("English practice", isPresented: Binding(
                get: { tutor.errorMessage != nil || speech.permissionMessage != nil },
                set: { if !$0 { tutor.errorMessage = nil; speech.permissionMessage = nil } }
            )) {
                Button("OK", role: .cancel) { tutor.errorMessage = nil; speech.permissionMessage = nil }
            } message: {
                Text(tutor.errorMessage ?? speech.permissionMessage ?? "")
            }
            .alert("10-minute lesson complete", isPresented: $lessonFinishedAlert) {
                Button("Start next lesson") { lessonStore.startNewSession() }
                Button("Later", role: .cancel) { }
            } message: {
                Text("Хорошая работа! Урок сохранён в истории. Можно продолжить позже.")
            }
            .task(id: lessonStore.activeSessionID) {
                guard lessonStore.activeSessionID != nil else { return }
                while !Task.isCancelled {
                    if lessonStore.remainingSeconds <= 0 {
                        if speech.isRecording { _ = await speech.stopRecordingAndWait() }
                        speech.stopSpeaking()
                        lessonStore.finishCurrentSession()
                        lessonFinishedAlert = true
                        break
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
        .tint(Color(red: 0.48, green: 0.56, blue: 1.0))
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.indigo.gradient).frame(width: 46, height: 46)
                Image(systemName: "airplane").font(.title3).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("English AI Tutor").font(.headline)
                Text("CABIN CREW ENGLISH  ·  B1 GOAL")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(timerText).font(.system(.headline, design: .rounded).monospacedDigit())
                Text("10 MIN LESSON").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .padding()
    }

    private var transcriptionPanel: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("LIVE TRANSCRIPTION")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Apple Speech · en-US")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(speech.transcript.isEmpty ? "Listening…" : speech.transcript)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Text("Apple Speech может нормализовать или неверно распознать слова. Оригинальная запись хранится локально на iPhone.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if speech.lastRecordingURL != nil && !speech.isRecording {
                    Button {
                        if speech.isPlayingRecording { speech.stopPlayback() }
                        else { speech.playLastRecording() }
                    } label: {
                        Image(systemName: speech.isPlayingRecording ? "stop.fill" : "play.fill")
                    }
                    .accessibilityLabel("Play original voice recording")
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
    }

    private var controls: some View {
        VStack(spacing: 11) {
            if isSendingTranscript || tutor.isSending {
                ProgressView("Preparing your lesson…")
                    .frame(maxWidth: .infinity)
            }
            HStack(spacing: 12) {
                Button { showTranscript.toggle() } label: {
                    Image(systemName: showTranscript ? "captions.bubble" : "captions.bubble.fill")
                        .font(.title3)
                        .frame(width: 50, height: 56)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
                .accessibilityLabel("Toggle transcription")

                Button {
                    Task {
                        if speech.isRecording {
                            isSendingTranscript = true
                            let finalText = await speech.stopRecordingAndWait()
                            await sendTranscript(finalText)
                            isSendingTranscript = false
                        } else {
                            await speech.startRecording()
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: speech.isRecording ? "stop.fill" : "mic.fill")
                        Text(speech.isRecording ? "Finish speaking" : "Tap to speak")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .foregroundStyle(.white)
                    .background(speech.isRecording ? Color.red : Color.indigo, in: RoundedRectangle(cornerRadius: 16))
                }
                .disabled(tutor.isSending || isSendingTranscript || lessonStore.activeSessionID == nil)
            }
            HStack {
                Button { speech.stopSpeaking() } label: {
                    Label("Stop voice", systemImage: "speaker.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    speech.stopSpeaking()
                    lessonStore.finishCurrentSession()
                    lessonStore.startNewSession()
                } label: {
                    Label("New lesson", systemImage: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(tutor.isSending || isSendingTranscript)
            }
        }
        .padding()
        .background(.bar)
    }

    @MainActor
    private func sendTranscript(_ text: String) async {
        let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else {
            tutor.errorMessage = "Я не расслышал ответ. Попробуй ещё раз."
            return
        }
        guard !model.isEmpty else {
            tutor.errorMessage = "Открой настройки, подключись к Router.cheap и выбери модель."
            return
        }

        let previousMessages = lessonStore.currentMessages
        lessonStore.append(ChatMessage(role: .user, text: spoken))
        do {
            let result = try await tutor.reply(
                to: spoken,
                history: previousMessages,
                model: model,
                baseURL: apiBase,
                apiKey: apiKey
            )
            lessonStore.append(ChatMessage(role: .assistant, text: result.displayText, speechText: result.spokenText))
            speech.speak(result.spokenText)
        } catch {
            tutor.errorMessage = error.localizedDescription
        }
    }
}

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 45) }
            Text(message.text)
                .font(.body)
                .padding(13)
                .foregroundStyle(message.role == .user ? .white : .primary)
                .background(
                    message.role == .user ? Color.indigo : Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 18)
                )
            if message.role == .assistant { Spacer(minLength: 35) }
        }
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var apiKey: String
    @Binding var model: String
    @Binding var apiBase: String
    @ObservedObject var tutor: TutorService

    @State private var saveStatus: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Router.cheap API") {
                    SecureField("API key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("API base URL", text: $apiBase)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button("Save API key securely") {
                        do {
                            try KeychainStore.save(apiKey)
                            saveStatus = "Ключ сохранён в iPhone Keychain."
                        } catch {
                            saveStatus = error.localizedDescription
                        }
                    }
                    if let saveStatus {
                        Text(saveStatus).font(.caption).foregroundStyle(.secondary)
                    }
                    Button {
                        Task {
                            await tutor.loadModels(baseURL: apiBase, apiKey: apiKey)
                            if !tutor.models.contains(where: { $0.id == model }),
                               let recommended = tutor.recommendedModelID() {
                                model = recommended
                            }
                        }
                    } label: {
                        HStack {
                            if tutor.isLoadingModels { ProgressView() }
                            Text(tutor.isLoadingModels ? "Loading models…" : "Check connection and load models")
                        }
                    }
                    .disabled(tutor.isLoadingModels || apiKey.isEmpty)
                    if let status = tutor.connectionStatus {
                        Label(status, systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    if let error = tutor.errorMessage {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }

                Section("Choose AI model") {
                    if tutor.models.isEmpty {
                        Text("Сначала нажми «Check connection and load models».")
                            .font(.footnote).foregroundStyle(.secondary)
                        TextField("Model ID (manual fallback)", text: $model)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } else {
                        Picker("Model", selection: $model) {
                            ForEach(tutor.models) { item in
                                Text(item.displayName).tag(item.id)
                            }
                        }
                        .pickerStyle(.menu)
                        Text("Доступно моделей: \(tutor.models.count). Список загружается напрямую из Router.cheap.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Use recommended Claude model") {
                            if let recommended = tutor.recommendedModelID() { model = recommended }
                        }
                    }
                    if !model.isEmpty {
                        LabeledContent("Selected ID", value: model)
                            .font(.caption)
                    }
                }

                Section("Learning profile") {
                    LabeledContent("Current level", value: "A2 / Elementary")
                    LabeledContent("Goal", value: "Practical B1 cabin-crew English")
                    LabeledContent("Lesson length", value: "10 minutes")
                    LabeledContent("Corrections", value: "After each answer")
                    LabeledContent("Passenger voice", value: "English · female-preferred iOS voice")
                }

                Section {
                    Text("Важно: Apple Speech может менять распознанный текст. Оригинальная запись сохраняется локально для последующего анализа; в Claude сейчас отправляется транскрипция, а не аудиофайл.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                if let stored = KeychainStore.read(), apiKey.isEmpty { apiKey = stored }
            }
        }
    }
}

struct HistoryView: View {
    @Environment(\.dismiss) private var dismiss
    let sessions: [LessonSession]

    var body: some View {
        NavigationStack {
            List {
                if sessions.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "book.closed").font(.largeTitle).foregroundStyle(.secondary)
                        Text("No lessons yet").font(.headline)
                        Text("Завершённые занятия появятся здесь.").font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                } else {
                    ForEach(sessions.sorted(by: { $0.startedAt > $1.startedAt })) { session in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.headline)
                                Spacer()
                                Text(session.endedAt == nil ? "In progress" : "Saved")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(session.endedAt == nil ? .green : .secondary)
                            }
                            Text("\(session.messages.filter { $0.role == .user }.count) spoken answers · \(max(1, Int(session.duration / 60))) min")
                                .font(.caption).foregroundStyle(.secondary)
                            if let lastUser = session.messages.last(where: { $0.role == .user }) {
                                Text(lastUser.text).font(.subheadline).lineLimit(2)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Lesson history")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

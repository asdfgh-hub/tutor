import SwiftUI

struct ContentView: View {
    @StateObject private var speech = SpeechManager()
    @StateObject private var tutor = TutorService()
    @StateObject private var lessonStore = LessonStore()

    @AppStorage("tutor.model") private var model = ""
    @AppStorage("tutor.reviewModel") private var reviewModel = ""
    @AppStorage("tutor.apiBase") private var apiBase = "https://router.cheap/v1"

    @State private var apiKey = KeychainStore.read() ?? ""
    @State private var showSettings = false
    @State private var showHistory = false
    @State private var showVocabulary = false
    @State private var showProgress = false
    @State private var showNewLesson = false
    @State private var showReview = false
    @State private var showCorrectionPractice = false
    @State private var showTranscript = true
    @State private var isSendingTranscript = false
    @State private var isGeneratingReview = false
    @State private var reviewedSession: LessonSession?
    @State private var selectedCorrection: CorrectionItem?

    private var timerText: String {
        guard lessonStore.activeSessionID != nil else { return "--:--" }
        let seconds = lessonStore.remainingSeconds
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private var currentMode: TrainingMode { lessonStore.currentSession?.trainingMode ?? .passenger }
    private var currentLevel: TrainingLevel { lessonStore.currentSession?.trainingLevel ?? .a2 }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                if let stage = lessonStore.currentFlightStage {
                    flightStageBanner(stage)
                } else if let session = lessonStore.currentSession {
                    sessionBanner(session)
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            ForEach(lessonStore.currentMessages) { message in
                                MessageBubble(message: message) { correction in
                                    selectedCorrection = correction
                                    showCorrectionPractice = true
                                }
                                .id(message.id)
                            }
                            if tutor.isSending || isSendingTranscript {
                                HStack(spacing: 8) {
                                    ProgressView()
                                    Text(currentMode == .interview ? "The recruiter is thinking…" : "The passenger is thinking…")
                                        .font(.footnote).foregroundStyle(.secondary)
                                    Spacer()
                                }
                                .padding(.horizontal)
                            }
                            if isGeneratingReview {
                                ProgressView("Подготавливаю итоговый разбор урока…")
                                    .padding()
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
                    Menu {
                        Button { showNewLesson = true } label: { Label("Новое занятие", systemImage: "plus.circle") }
                        Button { showVocabulary = true } label: { Label("Мой словарь", systemImage: "book.closed") }
                        Button { showProgress = true } label: { Label("Мой прогресс", systemImage: "chart.bar") }
                        Button { showHistory = true } label: { Label("История уроков", systemImage: "clock.arrow.circlepath") }
                    } label: { Image(systemName: "line.3.horizontal") }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(apiKey: $apiKey, model: $model, reviewModel: $reviewModel,
                             apiBase: $apiBase, tutor: tutor, usageStore: tutor.usageStore)
            }
            .sheet(isPresented: $showNewLesson) {
                NewLessonView(store: lessonStore, tutor: tutor, model: model,
                              baseURL: apiBase, apiKey: apiKey) { mode, level, scenarioID in
                    speech.stopSpeaking()
                    lessonStore.startNewSession(mode: mode, level: level, scenarioID: scenarioID)
                    showNewLesson = false
                    if let opening = lessonStore.currentMessages.last?.speechText {
                        speech.speak(opening)
                    }
                }
            }
            .sheet(isPresented: $showVocabulary) {
                VocabularyView(store: lessonStore)
            }
            .sheet(isPresented: $showProgress) {
                LearningProgressView(store: lessonStore)
            }
            .sheet(isPresented: $showHistory) {
                HistoryView(sessions: lessonStore.sessions) { session in
                    reviewedSession = session
                    showHistory = false
                    showReview = true
                }
            }
            .sheet(isPresented: $showReview) {
                if let session = reviewedSession {
                    SessionReviewView(session: session) { correction in
                        selectedCorrection = correction
                        showReview = false
                        showCorrectionPractice = true
                    }
                }
            }
            .sheet(isPresented: $showCorrectionPractice) {
                if let correction = selectedCorrection {
                    CorrectionPracticeView(correction: correction, speech: speech, tutor: tutor,
                                           model: model, baseURL: apiBase, apiKey: apiKey)
                }
            }
            .alert("English practice", isPresented: Binding(
                get: { tutor.errorMessage != nil || speech.permissionMessage != nil },
                set: { if !$0 { tutor.errorMessage = nil; speech.permissionMessage = nil } }
            )) {
                Button("OK", role: .cancel) { tutor.errorMessage = nil; speech.permissionMessage = nil }
            } message: {
                Text(tutor.errorMessage ?? speech.permissionMessage ?? "")
            }
            .task {
                while !Task.isCancelled {
                    if lessonStore.activeSessionID != nil && lessonStore.remainingSeconds <= 0 {
                        await finishLessonAndReview()
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
                Image(systemName: currentMode == .interview ? "person.crop.rectangle.stack" : "airplane")
                    .font(.title3).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("English AI Tutor").font(.headline)
                Text("\(currentMode.title.uppercased()) · \(currentLevel.rawValue) GOAL")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(timerText).font(.system(.headline, design: .rounded).monospacedDigit())
                Text("10 MIN LESSON").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private func sessionBanner(_ session: LessonSession) -> some View {
        HStack(spacing: 8) {
            Image(systemName: currentMode == .interview ? "person.crop.rectangle.stack" : "person.fill")
                .foregroundStyle(.indigo)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.scenarioTitle ?? currentMode.title).font(.subheadline.weight(.semibold))
                Text(currentMode == .interview ? "Ты — кандидат · ИИ — рекрутер" : "Ты — бортпроводник · ИИ — пассажир")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(session.personality?.title ?? (currentMode == .interview ? "Recruiter" : "Role-play"))
                .font(.caption2.weight(.medium)).padding(.horizontal, 8).padding(.vertical, 5)
                .background(.thinMaterial, in: Capsule())
            Button {
                if let line = lessonStore.currentMessages.last(where: { $0.role == .assistant })?.speechText { speech.speak(line) }
            } label: { Image(systemName: "speaker.wave.2.fill").font(.subheadline) }
            .accessibilityLabel("Прослушать реплику персонажа")
        }
        .padding(.horizontal)
        .padding(.vertical, 9)
        .background(Color.indigo.opacity(0.08))
    }

    private func flightStageBanner(_ stage: FlightStage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("ПОЛНЫЙ РЕЙС · ЭТАП \((lessonStore.currentSession?.flightStageIndex ?? 0) + 1)/\(FullFlightCatalog.stages.count)")
                    .font(.caption2.weight(.bold)).foregroundStyle(.indigo)
                Spacer()
                Text(stage.personality.title).font(.caption2).foregroundStyle(.secondary)
                Button {
                    if let line = lessonStore.currentMessages.last(where: { $0.role == .assistant })?.speechText { speech.speak(line) }
                } label: { Image(systemName: "speaker.wave.2.fill").font(.subheadline) }
                .accessibilityLabel("Прослушать реплику пассажира")
            }
            Text(stage.title).font(.subheadline.weight(.semibold))
            Text(stage.focus).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ForEach(FullFlightCatalog.stages.indices, id: \.self) { index in
                    Capsule().fill(index <= (lessonStore.currentSession?.flightStageIndex ?? 0) ? Color.indigo : Color.secondary.opacity(0.2))
                        .frame(height: 4)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 9)
        .background(Color.indigo.opacity(0.08))
    }

    private var transcriptionPanel: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("LIVE TRANSCRIPTION").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                Spacer()
                Text("Apple Speech · en-US").font(.caption2).foregroundStyle(.secondary)
            }
            Text(speech.transcript.isEmpty ? "Listening…" : speech.transcript)
                .font(.body).frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Text("Транскрипция может ошибаться. Оригинальная запись хранится локально на iPhone.")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if speech.lastRecordingURL != nil && !speech.isRecording {
                    Button {
                        if speech.isPlayingRecording { speech.stopPlayback() } else { speech.playLastRecording() }
                    } label: { Image(systemName: speech.isPlayingRecording ? "stop.fill" : "play.fill") }
                    .accessibilityLabel("Play original voice recording")
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            if isSendingTranscript || tutor.isSending {
                ProgressView("Обрабатываю ответ…").frame(maxWidth: .infinity)
            }
            HStack(spacing: 12) {
                Button { showTranscript.toggle() } label: {
                    Image(systemName: showTranscript ? "captions.bubble" : "captions.bubble.fill")
                        .font(.title3).frame(width: 50, height: 56)
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
                        Text(speech.isRecording ? "Finish speaking" : "Tap to speak").fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity).frame(height: 56).foregroundStyle(.white)
                    .background(speech.isRecording ? Color.red : Color.indigo, in: RoundedRectangle(cornerRadius: 16))
                }
                .disabled(tutor.isSending || isSendingTranscript || lessonStore.activeSessionID == nil)
            }
            HStack {
                Button { speech.stopSpeaking() } label: {
                    Label("Stop voice", systemImage: "speaker.slash").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if currentMode == .fullFlight && (lessonStore.currentSession?.flightStageIndex ?? 0) < FullFlightCatalog.stages.count - 1 {
                    Button {
                        speech.stopSpeaking()
                        if lessonStore.advanceFlightStage(), let line = lessonStore.currentMessages.last?.speechText {
                            speech.speak(line)
                        }
                    } label: {
                        Label("Следующий этап", systemImage: "arrow.right.circle").font(.caption.weight(.semibold))
                    }
                    .disabled(tutor.isSending || isSendingTranscript)
                }
                Button {
                    Task { await finishLessonAndReview() }
                } label: {
                    Label("Завершить и разобрать", systemImage: "checkmark.circle")
                        .font(.caption.weight(.semibold))
                }
                .disabled(tutor.isSending || isSendingTranscript || isGeneratingReview || lessonStore.activeSessionID == nil)
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
        guard let session = lessonStore.currentSession else { return }

        let previousMessages = lessonStore.currentMessages
        lessonStore.append(ChatMessage(role: .user, text: spoken))
        do {
            let mode = session.trainingMode ?? .passenger
            let level = session.trainingLevel ?? .a2
            let scenario = mode == .passenger ? lessonStore.scenario(id: session.scenarioID) : nil
            let stage: FlightStage? = mode == .fullFlight
                ? FullFlightCatalog.stages[min(max(session.flightStageIndex ?? 0, 0), FullFlightCatalog.stages.count - 1)]
                : nil
            let result = try await tutor.reply(to: spoken, history: previousMessages, model: model,
                                               baseURL: apiBase, apiKey: apiKey, mode: mode,
                                               level: level, scenario: scenario, flightStage: stage)
            lessonStore.append(ChatMessage(role: .assistant, text: result.displayText, speechText: result.spokenText,
                                           corrections: result.corrections, vocabulary: result.vocabulary,
                                           phrase: result.phrase, score: result.score))
            lessonStore.addVocabulary(result.vocabulary)
            speech.speak(result.spokenText)
        } catch {
            tutor.errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func finishLessonAndReview() async {
        guard lessonStore.activeSessionID != nil else { return }
        if speech.isRecording { _ = await speech.stopRecordingAndWait() }
        speech.stopSpeaking()
        guard let finishedID = lessonStore.finishCurrentSession() else { return }
        isGeneratingReview = true
        if !model.isEmpty, !apiKey.isEmpty, let session = lessonStore.session(id: finishedID) {
            do {
                let selectedReviewModel = reviewModel.isEmpty ? model : reviewModel
                let review = try await tutor.generateLessonReview(for: session, model: selectedReviewModel,
                                                                  baseURL: apiBase, apiKey: apiKey)
                lessonStore.saveReview(review, for: finishedID)
            } catch {
                tutor.errorMessage = "Урок сохранён, но итоговый разбор не получен: \(error.localizedDescription)"
            }
        }
        reviewedSession = lessonStore.session(id: finishedID)
        isGeneratingReview = false
        showReview = reviewedSession != nil
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    var onPractice: ((CorrectionItem) -> Void)?

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 45) }
            VStack(alignment: .leading, spacing: 10) {
                Text(message.text).font(.body)
                if let corrections = message.corrections, !corrections.isEmpty {
                    Divider().overlay(Color.white.opacity(0.12))
                    ForEach(corrections) { correction in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(correction.original).strikethrough().foregroundStyle(.secondary)
                            Text(correction.corrected).fontWeight(.semibold)
                            Text(correction.explanationRU).font(.caption).foregroundStyle(.secondary)
                            Button { onPractice?(correction) } label: {
                                Label("Отработать фразу", systemImage: "repeat")
                                    .font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .padding(13)
            .foregroundStyle(message.role == .user ? .white : .primary)
            .background(message.role == .user ? Color.indigo : Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 18))
            if message.role == .assistant { Spacer(minLength: 32) }
        }
    }
}

struct NewLessonView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: LessonStore
    @ObservedObject var tutor: TutorService
    let model: String
    let baseURL: String
    let apiKey: String
    @State private var mode: TrainingMode = .passenger
    @State private var level: TrainingLevel = .a2
    @State private var scenarioID = ScenarioCatalog.scenarios[0].id
    @State private var isGeneratingScenarios = false
    @State private var generationMessage: String?
    let onStart: (TrainingMode, TrainingLevel, String) -> Void

    private var selectedScenario: TrainingScenario { store.scenario(id: scenarioID) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Формат занятия") {
                    Picker("Режим", selection: $mode) {
                        ForEach(TrainingMode.allCases) { item in Text(item.title).tag(item) }
                    }
                    Text(mode.subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Section("Сложность английского") {
                    Picker("Уровень", selection: $level) {
                        ForEach(TrainingLevel.allCases) { item in Text(item.title).tag(item) }
                    }
                    Text("Уровень можно менять от занятия к занятию. Цель — уверенный практический B1.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if mode == .passenger {
                    Section("Ситуация") {
                        Picker("Сценарий", selection: $scenarioID) {
                            ForEach(store.availableScenarios) { item in
                                Text("\(item.category): \(item.title)").tag(item.id)
                            }
                        }
                        Text(selectedScenario.summary).font(.caption).foregroundStyle(.secondary)
                        Label("Пассажир: \(selectedScenario.personality.title)", systemImage: "person")
                            .font(.caption)
                        Button {
                            Task { await generateMoreScenarios() }
                        } label: {
                            HStack {
                                if isGeneratingScenarios { ProgressView() }
                                Text(isGeneratingScenarios ? "Генерирую сценарии…" : "Сгенерировать 4 новых сценария")
                            }
                        }
                        .disabled(isGeneratingScenarios || model.isEmpty || apiKey.isEmpty)
                        Text("Новые сценарии сохраняются на iPhone и доступны в следующих занятиях без повторной генерации.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let generationMessage {
                            Text(generationMessage).font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Сценариев в библиотеке: \(store.availableScenarios.count)")
                            .font(.caption.weight(.medium))
                    }
                }
                if mode == .fullFlight {
                    Section("Этапы полного рейса") {
                        ForEach(FullFlightCatalog.stages) { stage in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(stage.title).font(.subheadline.weight(.semibold))
                                Text(stage.focus).font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
                if mode == .interview {
                    Section("Что тренируем") {
                        Text("Рассказ о себе, мотивацию, клиентский сервис, командную работу, конфликтные ситуации и вопросы рекрутера.")
                    }
                }
            }
            .navigationTitle("Новое занятие")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Начать") { onStart(mode, level, scenarioID); dismiss() }.fontWeight(.semibold)
                }
            }
        }
    }

    @MainActor
    private func generateMoreScenarios() async {
        isGeneratingScenarios = true
        generationMessage = nil
        defer { isGeneratingScenarios = false }
        do {
            let newItems = try await tutor.generateScenarios(model: model, baseURL: baseURL, apiKey: apiKey, count: 4)
            store.addScenarios(newItems)
            scenarioID = newItems.first?.id ?? scenarioID
            generationMessage = "Добавлено сценариев: \(newItems.count). Они сохранены локально."
        } catch {
            generationMessage = error.localizedDescription
        }
    }
}

struct SettingsView: View {
    @AppStorage("tutor.balancedModelsConfigured") private var balancedModelsConfigured = false
    @Environment(\.dismiss) private var dismiss
    @Binding var apiKey: String
    @Binding var model: String
    @Binding var reviewModel: String
    @Binding var apiBase: String
    @ObservedObject var tutor: TutorService
    @ObservedObject var usageStore: APIUsageStore

    @State private var saveStatus: String?
    @State private var dailyBudgetText = "1.00"
    @State private var roleplayInputRate = ""
    @State private var roleplayOutputRate = ""
    @State private var reviewInputRate = ""
    @State private var reviewOutputRate = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Router.cheap API") {
                    SecureField("API key", text: $apiKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("API base URL", text: $apiBase).textInputAutocapitalization(.never)
                        .autocorrectionDisabled().keyboardType(.URL)
                    Button("Save API key securely") {
                        do { try KeychainStore.save(apiKey); saveStatus = "Ключ сохранён в iPhone Keychain." }
                        catch { saveStatus = error.localizedDescription }
                    }
                    if let saveStatus { Text(saveStatus).font(.caption).foregroundStyle(.secondary) }
                    Button {
                        Task {
                            await tutor.loadModels(baseURL: apiBase, apiKey: apiKey)
                            if !balancedModelsConfigured || !tutor.models.contains(where: { $0.id == model }),
                               let recommended = tutor.recommendedRoleplayModelID() { model = recommended }
                            if reviewModel.isEmpty || !tutor.models.contains(where: { $0.id == reviewModel }),
                               let recommended = tutor.recommendedReviewModelID() { reviewModel = recommended }
                            balancedModelsConfigured = true
                            loadRatesForSelectedModels()
                        }
                    } label: {
                        HStack { if tutor.isLoadingModels { ProgressView() }; Text(tutor.isLoadingModels ? "Loading models…" : "Check connection and load models") }
                    }
                    .disabled(tutor.isLoadingModels || apiKey.isEmpty)
                    if let status = tutor.connectionStatus {
                        Label(status, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                    }
                    if let error = tutor.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
                }
                Section("Balanced · выбор моделей") {
                    modelPicker(title: "Диалог с пассажиром", selection: $model)
                    Text("Для диалога выбирается быстрая и недорогая модель. История запроса ограничена последними 8 сообщениями.")
                        .font(.caption).foregroundStyle(.secondary)
                    modelPicker(title: "Итоговый разбор", selection: $reviewModel)
                    Text("Более сильная модель вызывается один раз в конце занятия. Если поле пустое, используется модель диалога.")
                        .font(.caption).foregroundStyle(.secondary)
                    if tutor.models.isEmpty {
                        Text("Сначала загрузи список моделей или введи их ID вручную ниже.").font(.footnote).foregroundStyle(.secondary)
                        TextField("ID модели диалога", text: $model).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("ID модели разбора", text: $reviewModel).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                }
                Section("Дневной бюджет API") {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(String(format: "$%.4f из $%.2f", usageStore.spentTodayUSD, usageStore.dailyBudgetUSD))
                                .font(.headline.monospacedDigit())
                            Text("Расход сегодня · локальная оценка по токенам")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: usageStore.spentTodayUSD >= usageStore.dailyBudgetUSD ? "exclamationmark.circle.fill" : "chart.pie.fill")
                            .foregroundStyle(usageStore.spentTodayUSD >= usageStore.dailyBudgetUSD ? .red : .indigo)
                    }
                    ProgressView(value: min(1, usageStore.spentTodayUSD / max(usageStore.dailyBudgetUSD, 0.01)))
                    LabeledContent("Входные токены сегодня", value: usageStore.inputTokensToday.formatted())
                    LabeledContent("Выходные токены сегодня", value: usageStore.outputTokensToday.formatted())
                    TextField("Лимит в USD за день", text: $dailyBudgetText).keyboardType(.decimalPad)
                    Button("Сохранить дневной лимит") {
                        if let amount = parsePrice(dailyBudgetText), amount > 0 {
                            usageStore.setDailyBudget(amount)
                            saveStatus = "Дневной лимит обновлён."
                        } else {
                            saveStatus = "Введи положительное число, например 1.00."
                        }
                    }
                    Text("Приложение заранее резервирует примерную стоимость запроса и блокирует новые запросы при достижении лимита. Это локальная защита, а не точный биллинг провайдера. Для дополнительной защиты используй отдельный API-ключ с лимитом расходов в панели Router.cheap.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Последние запросы") {
                    if usageStore.entries.isEmpty {
                        Text("Пока нет записанных API-запросов.").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(usageStore.entries.suffix(6).reversed())) { entry in
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.purpose).font(.subheadline.weight(.medium))
                                    Text("\(entry.model) · \(entry.inputTokens + entry.outputTokens) токенов · \(entry.date.formatted(date: .omitted, time: .shortened))")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(String(format: "\(entry.isEstimate ? "≈" : "")$%.5f", entry.costUSD))
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Цены моделей · USD за 1 млн токенов") {
                    Text("Цены автоматически импортируются из каталога, если Router.cheap передаёт их в /models. Иначе укажи их вручную на странице цен провайдера. Без цен запросы блокируются, чтобы не обходить бюджет вслепую.")
                        .font(.caption).foregroundStyle(.secondary)
                    rateEditor(title: "Модель диалога · \(model.isEmpty ? "не выбрана" : model)", input: $roleplayInputRate, output: $roleplayOutputRate)
                    rateEditor(title: "Модель разбора · \(reviewModel.isEmpty ? model : reviewModel)", input: $reviewInputRate, output: $reviewOutputRate)
                    Button("Сохранить цены моделей") { saveRates() }
                }
                Section("Learning profile") {
                    LabeledContent("Current level", value: "A2 / Elementary")
                    LabeledContent("Goal", value: "Practical B1 cabin-crew English")
                    LabeledContent("Lesson length", value: "10 minutes")
                    LabeledContent("Corrections", value: "After each answer")
                    LabeledContent("Practice modes", value: "Passengers · Interview · Full flight")
                    LabeledContent("Pronunciation scoring", value: "Not included")
                }
                Section {
                    Text("Apple Speech транскрибирует речь, но может ошибаться. Итоговый разбор оценивает грамматику, лексику и коммуникацию — не произношение. Повторные идентичные запросы могут быть взяты из локального кэша без обращения к API.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } } }
            .onAppear {
                if let stored = KeychainStore.read(), apiKey.isEmpty { apiKey = stored }
                dailyBudgetText = String(format: "%.2f", usageStore.dailyBudgetUSD)
                loadRatesForSelectedModels()
            }
            .onChange(of: model) { _ in loadRatesForSelectedModels() }
            .onChange(of: reviewModel) { _ in loadRatesForSelectedModels() }
        }
    }

    @ViewBuilder
    private func modelPicker(title: String, selection: Binding<String>) -> some View {
        if !tutor.models.isEmpty {
            Picker(title, selection: selection) {
                ForEach(tutor.models) { item in Text(item.displayName).tag(item.id) }
            }
            .pickerStyle(.menu)
        }
    }

    private func rateEditor(title: String, input: Binding<String>, output: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            HStack {
                TextField("Input $/1M", text: input).keyboardType(.decimalPad)
                TextField("Output $/1M", text: output).keyboardType(.decimalPad)
            }
            .font(.footnote)
        }
        .padding(.vertical, 3)
    }

    private func parsePrice(_ value: String) -> Double? {
        Double(value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "."))
    }

    private func loadRatesForSelectedModels() {
        roleplayInputRate = ""
        roleplayOutputRate = ""
        reviewInputRate = ""
        reviewOutputRate = ""
        if let rates = usageStore.rates(for: model) {
            roleplayInputRate = String(format: "%.6f", rates.inputPerMillion)
            roleplayOutputRate = String(format: "%.6f", rates.outputPerMillion)
        }
        let effectiveReviewModel = reviewModel.isEmpty ? model : reviewModel
        if let rates = usageStore.rates(for: effectiveReviewModel) {
            reviewInputRate = String(format: "%.6f", rates.inputPerMillion)
            reviewOutputRate = String(format: "%.6f", rates.outputPerMillion)
        }
    }

    private func saveRates() {
        guard let roleInput = parsePrice(roleplayInputRate), let roleOutput = parsePrice(roleplayOutputRate),
              !model.isEmpty else {
            saveStatus = "Укажи цены входных и выходных токенов для модели диалога."
            return
        }
        usageStore.setRates(ModelTokenRates(inputPerMillion: roleInput, outputPerMillion: roleOutput), for: model)
        let effectiveReviewModel = reviewModel.isEmpty ? model : reviewModel
        if effectiveReviewModel == model {
            reviewInputRate = roleplayInputRate
            reviewOutputRate = roleplayOutputRate
        } else if let reviewInput = parsePrice(reviewInputRate), let reviewOutput = parsePrice(reviewOutputRate) {
            usageStore.setRates(ModelTokenRates(inputPerMillion: reviewInput, outputPerMillion: reviewOutput), for: effectiveReviewModel)
        } else {
            saveStatus = "Цены модели диалога сохранены. Для модели разбора также укажи обе цены."
            return
        }
        saveStatus = "Цены моделей сохранены. Защита дневного лимита активна."
    }
}

struct VocabularyView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: LessonStore
    @State private var searchText = ""
    @State private var showLearned = true

    private var filteredItems: [VocabularyItem] {
        store.vocabulary.filter { item in
            (showLearned || !item.isLearned) &&
            (searchText.isEmpty || item.term.localizedCaseInsensitiveContains(searchText) || item.translationRU.localizedCaseInsensitiveContains(searchText))
        }.sorted { !$0.isLearned && $1.isLearned }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Показывать выученные слова", isOn: $showLearned)
                }
                Section("Мой словарь · \(store.vocabulary.count) слов") {
                    if filteredItems.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "book.closed").font(.largeTitle).foregroundStyle(.secondary)
                            Text("Пока нет слов").font(.headline)
                            Text("Новые полезные слова будут добавляться после диалогов с ИИ.").font(.footnote).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 28)
                    } else {
                        ForEach(filteredItems) { item in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(item.term).font(.headline)
                                    Spacer()
                                    if item.isLearned { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                                }
                                Text(item.translationRU).font(.subheadline).foregroundStyle(.secondary)
                                if !item.exampleEN.isEmpty { Text(item.exampleEN).font(.caption).italic() }
                                Button(item.isLearned ? "Вернуть в изучение" : "Отметить выученным") {
                                    store.setVocabularyLearned(item.id, learned: !item.isLearned)
                                }
                                .font(.caption.weight(.semibold)).buttonStyle(.bordered)
                            }
                            .padding(.vertical, 4)
                            .swipeActions {
                                Button(role: .destructive) { store.removeVocabulary(item.id) } label: { Label("Удалить", systemImage: "trash") }
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Слово или перевод")
            .navigationTitle("Мой словарь")
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Готово") { dismiss() } } }
        }
    }
}

struct LearningProgressView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: LessonStore
    private var stats: LearningProgress { store.progress }

    var body: some View {
        NavigationStack {
            List {
                Section("Практика") {
                    statRow("Завершённых занятий", value: "\(stats.completedLessons)", icon: "checkmark.circle")
                    statRow("Минут практики", value: "\(stats.totalMinutes)", icon: "clock")
                    statRow("Твоих ответов", value: "\(stats.spokenTurns)", icon: "mic")
                    statRow("Средняя оценка", value: stats.averageScore.map { "\($0)/10" } ?? "Пока нет", icon: "chart.bar")
                }
                Section("Словарь") {
                    statRow("Всего слов и фраз", value: "\(stats.vocabularyCount)", icon: "book")
                    statRow("Отмечено выученными", value: "\(stats.learnedVocabularyCount)", icon: "checkmark.seal")
                }
                Section("Над чем поработать") {
                    if stats.focusAreas.isEmpty {
                        Text("Пройди несколько занятий и заверши их итоговым разбором — здесь появятся повторяющиеся зоны роста.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        ForEach(stats.focusAreas, id: \.self) { area in
                            Label(area, systemImage: "target").font(.subheadline)
                        }
                    }
                }
                Section("Цель обучения") {
                    Text("Практический B1 для работы бортпроводником: уверенно приветствовать пассажиров, объяснять, помогать, отвечать на вопросы и решать повседневные ситуации на борту.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Мой прогресс")
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Готово") { dismiss() } } }
        }
    }

    private func statRow(_ title: String, value: String, icon: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            Text(value).fontWeight(.semibold).foregroundStyle(.secondary)
        }
    }
}

struct HistoryView: View {
    @Environment(\.dismiss) private var dismiss
    let sessions: [LessonSession]
    var onReview: (LessonSession) -> Void

    var body: some View {
        NavigationStack {
            List {
                if sessions.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "book.closed").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Пока нет занятий").font(.headline)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 28)
                } else {
                    ForEach(sessions.sorted(by: { $0.startedAt > $1.startedAt })) { session in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(session.scenarioTitle ?? (session.trainingMode?.title ?? "Занятие" )).font(.headline)
                                Spacer()
                                if let score = session.review?.score { Text("\(score)/10").fontWeight(.bold).foregroundStyle(.indigo) }
                            }
                            Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                            Text("\((session.trainingMode ?? .passenger).title) · \((session.trainingLevel ?? .a2).rawValue) · \(session.messages.filter { $0.role == .user }.count) ответов")
                                .font(.caption).foregroundStyle(.secondary)
                            if session.review != nil {
                                Button("Открыть разбор") { onReview(session) }.font(.caption.weight(.semibold)).buttonStyle(.bordered)
                            } else if session.endedAt != nil {
                                Text("Итоговый разбор не сохранён").font(.caption2).foregroundStyle(.secondary)
                            } else {
                                Text("В процессе").font(.caption2).foregroundStyle(.green)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("История занятий")
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Готово") { dismiss() } } }
        }
    }
}

struct SessionReviewView: View {
    @Environment(\.dismiss) private var dismiss
    let session: LessonSession
    var onPractice: (CorrectionItem) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if let review = session.review {
                    List {
                        Section {
                            HStack(alignment: .center) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Итог занятия").font(.headline)
                                    Text(session.scenarioTitle ?? (session.trainingMode?.title ?? "English practice"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(review.score)/10").font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(.indigo)
                            }
                        }
                        Section("Коммуникация") { Text(review.communication) }
                        Section("Грамматика") { Text(review.grammar) }
                        Section("Словарный запас") { Text(review.vocabulary) }
                        Section("Что получилось") {
                            ForEach(review.strengths, id: \.self) { item in Label(item, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                        }
                        Section("Следующие точки роста") {
                            ForEach(review.focusAreas, id: \.self) { item in Label(item, systemImage: "target") }
                        }
                        if !review.corrections.isEmpty {
                            Section("Исправить и повторить") {
                                ForEach(review.corrections) { correction in
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(correction.original).strikethrough().foregroundStyle(.secondary)
                                        Text(correction.corrected).fontWeight(.semibold)
                                        Text(correction.explanationRU).font(.caption).foregroundStyle(.secondary)
                                        Button("Повторить фразу") { onPractice(correction) }.buttonStyle(.bordered)
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        }
                        if !review.modelAnswer.isEmpty {
                            Section("Пример более сильного ответа") { Text(review.modelAnswer).font(.body) }
                        }
                        if !review.drillPhrases.isEmpty {
                            Section("Фразы для закрепления") {
                                ForEach(review.drillPhrases, id: \.self) { phrase in Text(phrase) }
                            }
                        }
                        Section {
                            Text("Оценка не включает произношение или акцент. Она основана на коммуникации, грамматике, лексике и распознанном тексте диалога.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "doc.text.magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Разбор не сформирован").font(.headline)
                        Text("Занятие сохранено, но итоговая оценка не получена. Проверь API и заверши следующее занятие.")
                            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Разбор занятия")
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Готово") { dismiss() } } }
        }
    }
}

struct CorrectionPracticeView: View {
    @Environment(\.dismiss) private var dismiss
    let correction: CorrectionItem
    @ObservedObject var speech: SpeechManager
    @ObservedObject var tutor: TutorService
    let model: String
    let baseURL: String
    let apiKey: String

    @State private var resultText: String?
    @State private var isChecking = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text("Скажи исправленную фразу самостоятельно. Мы проверим грамматику и выбор слов, но не произношение.")
                    .font(.subheadline).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    Text("ТВОЙ ПРЕДЫДУЩИЙ ВАРИАНТ").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                    Text(correction.original).strikethrough().foregroundStyle(.secondary)
                    Text("ПРАВИЛЬНЫЙ ВАРИАНТ").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                    Text(correction.corrected).font(.title3.weight(.semibold))
                    Text(correction.explanationRU).font(.footnote).foregroundStyle(.secondary)
                }
                .padding().frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
                if speech.isRecording || !speech.transcript.isEmpty {
                    Text(speech.transcript.isEmpty ? "Слушаю…" : speech.transcript)
                        .padding().frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
                Button {
                    Task {
                        if speech.isRecording {
                            let attempt = await speech.stopRecordingAndWait()
                            guard !attempt.isEmpty else { resultText = "Не удалось распознать фразу. Попробуй ещё раз."; return }
                            isChecking = true
                            defer { isChecking = false }
                            do {
                                resultText = try await tutor.checkCorrectionAttempt(attempt, target: correction.corrected,
                                                                                    model: model, baseURL: baseURL, apiKey: apiKey)
                            } catch { resultText = error.localizedDescription }
                        } else {
                            resultText = nil
                            await speech.startRecording()
                        }
                    }
                } label: {
                    Label(speech.isRecording ? "Завершить ответ" : "Записать мою попытку",
                          systemImage: speech.isRecording ? "stop.fill" : "mic.fill")
                        .fontWeight(.semibold).frame(maxWidth: .infinity).frame(height: 54)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isChecking || model.isEmpty || apiKey.isEmpty)
                if isChecking { ProgressView("Проверяю грамматику…") }
                if let resultText {
                    Text(resultText).padding().frame(maxWidth: .infinity, alignment: .leading)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Повторение фразы")
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Готово") { speech.stopSpeaking(); dismiss() } } }
        }
    }
}

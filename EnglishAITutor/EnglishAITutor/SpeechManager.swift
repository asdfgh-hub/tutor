import Foundation
import Speech
import AVFoundation
import Combine

@MainActor
final class SpeechManager: NSObject, ObservableObject {
    @Published var transcript = ""
    @Published var isRecording = false
    @Published var permissionMessage: String?
    @Published var lastRecordingURL: URL?
    @Published var isPlayingRecording = false

    private let audioEngine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recordingFile: AVAudioFile?
    private var audioPlayer: AVAudioPlayer?
    private var finalTranscriptContinuation: CheckedContinuation<String, Never>?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    func startRecording() async {
        guard !isRecording else { return }
        guard await requestPermissions() else { return }
        guard let recognizer, recognizer.isAvailable else {
            permissionMessage = "Распознавание английской речи сейчас недоступно."
            return
        }

        stopSpeaking()
        stopPlayback()
        transcript = ""
        permissionMessage = nil

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            recognitionTask?.cancel()
            recognitionTask = nil

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.taskHint = .unspecified
            if #available(iOS 16.0, *) {
                request.addsPunctuation = false
            }
            recognitionRequest = request

            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            let recordingURL = try makeRecordingURL()
            let file = try AVAudioFile(forWriting: recordingURL, settings: format.settings)
            recordingFile = file
            lastRecordingURL = recordingURL

            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
                try? file.write(from: buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true

            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let result {
                        self.transcript = result.bestTranscription.formattedString
                        if result.isFinal { self.resolveFinalTranscript() }
                    }
                    if error != nil { self.resolveFinalTranscript() }
                }
            }
        } catch {
            permissionMessage = "Не удалось запустить запись: \(error.localizedDescription)"
            stopCaptureImmediately()
        }
    }

    func stopRecordingAndWait() async -> String {
        guard isRecording else { return transcript }
        return await withCheckedContinuation { continuation in
            finalTranscriptContinuation = continuation
            stopCaptureImmediately()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                self.resolveFinalTranscript()
            }
        }
    }

    func speak(_ text: String) {
        guard !text.isEmpty else { return }
        stopPlayback()
        stopSpeaking()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
        } catch {
            // Speech synthesis can still work with the system's current audio session.
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        utterance.voice = preferredEnglishVoice()
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }

    func playLastRecording() {
        guard let url = lastRecordingURL else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.play()
            isPlayingRecording = true
            Task { @MainActor in
                while self.audioPlayer?.isPlaying == true {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                self.isPlayingRecording = false
            }
        } catch {
            permissionMessage = "Не удалось воспроизвести запись: \(error.localizedDescription)"
        }
    }

    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlayingRecording = false
    }

    private func requestPermissions() async -> Bool {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        let micGranted = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        let allowed = speechStatus == .authorized && micGranted
        if !allowed {
            permissionMessage = "Разреши доступ к микрофону и распознаванию речи в настройках iPhone."
        }
        return allowed
    }

    private func makeRecordingURL() throws -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("EnglishAITutor/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("speech-\(UUID().uuidString).caf")
    }

    private func stopCaptureImmediately() {
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recordingFile = nil
        isRecording = false
    }

    private func resolveFinalTranscript() {
        guard let continuation = finalTranscriptContinuation else { return }
        finalTranscriptContinuation = nil
        continuation.resume(returning: transcript.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func preferredEnglishVoice() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        let preferredNames = ["samantha", "ava", "zoe", "allison", "susan", "karen", "victoria", "aria", "joanna", "salli"]
        for preferred in preferredNames {
            if let voice = voices.first(where: { $0.name.localizedCaseInsensitiveContains(preferred) }) {
                return voice
            }
        }
        return AVSpeechSynthesisVoice(language: "en-US")
    }
}


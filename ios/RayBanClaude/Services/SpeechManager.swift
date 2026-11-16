import Foundation
import Speech
import AVFoundation

// MARK: - ElevenLabs voices (optional, paid)

struct ElevenLabsVoice: Identifiable, Hashable {
    let id: String
    let name: String
    let description: String

    /// With the eleven_flash_v2_5 model, all voices also speak German.
    static let allVoices: [ElevenLabsVoice] = [
        ElevenLabsVoice(id: "XB0fDUnXU5powFXDhCwa", name: "Charlotte", description: "Warm, female"),
        ElevenLabsVoice(id: "21m00Tcm4TlvDq8ikWAM", name: "Rachel", description: "Calm, female"),
        ElevenLabsVoice(id: "EXAVITQu4vr4xnSDxMaL", name: "Sarah", description: "Soft, female"),
        ElevenLabsVoice(id: "MF3mGyEYCl7XYWbV9V6O", name: "Elli", description: "Young, female"),
        ElevenLabsVoice(id: "29vD33N1CtxCmqQRPOHJ", name: "Drew", description: "Balanced, male"),
        ElevenLabsVoice(id: "2EiwWnXFnvU5JabPnv8n", name: "Clyde", description: "Deep, male"),
        ElevenLabsVoice(id: "TxGEqnHWrfWFTfGW9XjX", name: "Josh", description: "Young, male"),
        ElevenLabsVoice(id: "pNInz6obpgDQGcFmaJgB", name: "Adam", description: "Clear, male"),
    ]

    static func voice(for id: String) -> ElevenLabsVoice {
        allVoices.first { $0.id == id } ?? allVoices[0]
    }
}

/// Direct ElevenLabs call from the iPhone (gateway mode only; in channel mode the PC generates the audio)
struct ElevenLabsTTSClient {
    let apiKey: String

    func synthesize(text: String, voiceId: String) async throws -> Data {
        guard let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)/stream") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": String(text.prefix(2500)),
            "model_id": "eleven_flash_v2_5",
            "voice_settings": ["stability": 0.5, "similarity_boost": 0.75],
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            // Provider error text only goes to the log, not the UI
            print("[Speech] ElevenLabs error: \(String(data: data, encoding: .utf8) ?? "-")")
            throw URLError(.badServerResponse)
        }
        return data
    }
}

// MARK: - MP3 playback

@MainActor
final class AudioDataPlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = AudioDataPlayer()
    private var player: AVAudioPlayer?
    private var completion: (() -> Void)?

    /// Plays in the existing voice chat session – no switching to `.playback`
    /// (that broke the Bluetooth route on the glasses).
    func play(data: Data, completion: @escaping () -> Void) {
        stop()
        do {
            try AudioSessionManager.shared.configureForVoiceChat()
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            self.player = player
            self.completion = completion
            if !player.play() { finish() }
        } catch {
            print("[Audio] Playback failed: \(error)")
            completion()
        }
    }

    /// Cancels without triggering the completion callback (otherwise listening would start twice).
    func stop() {
        completion = nil
        player?.stop()
        player = nil
    }

    private func finish() {
        let done = completion
        completion = nil
        player = nil
        done?()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.finish() }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in self.finish() }
    }
}

// MARK: - Speech input and output

/// Listening mode: standby (waits for “Hey Claude”/“Claudi”) or command (records the sentence).
enum ListenMode: Equatable {
    case standby
    case command
}

@MainActor
final class SpeechManager: NSObject, ObservableObject {
    @Published private(set) var transcribedText: String = ""
    @Published private(set) var listenMode: ListenMode?
    @Published private(set) var isSpeaking: Bool = false

    var isListening: Bool { listenMode != nil }

    /// Recognized command after a speech pause
    var onSpeechPause: ((String) -> Void)?
    /// Wake word recognized – the command is now being recorded
    var onWakeWord: (() -> Void)?
    /// Speech output finished naturally (not on cancellation)
    var onSpeechFinished: (() -> Void)?
    /// Short diagnostic note when the PC's voice audio could not be used (shown in the transcript)
    var onVoiceNote: ((String) -> Void)?
    /// Command listening ended without a command (error, timeout, nothing said)
    var onListeningStopped: ((String?) -> Void)?

    /// Wake word active? Then it returns to standby after every command.
    var wakeWordEnabled = false

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    /// Recording runs continuously (also with the iPhone locked) – only the recognition switches.
    /// It used to be stopped after every sentence; in the background iOS then won't let it restart.
    private let audioEngine = AVAudioEngine()
    private let sink = RecognitionSink()
    private var tapInstalled = false
    private var languageCode: String = ClaudeConfig.defaultLanguage

    private var elevenLabsClient: ElevenLabsTTSClient?
    private var elevenLabsVoiceId: String = ElevenLabsVoice.allVoices[0].id
    private let appleSynthesizer = AVSpeechSynthesizer()

    private var silenceTimer: Timer?
    private var noSpeechTimer: Timer?
    private var standbyRefreshTimer: Timer?
    private var pauseThreshold: TimeInterval = 1.5
    private var pauseHandled = false
    /// Command came via the wake word → only the part after it counts
    private var viaWakeWord = false
    /// Every recognition session gets a number – callbacks from old sessions are ignored
    private var generation = 0
    private var standbyRetries = 0

    /// Restart standby regularly: recognition via Apple's servers is limited to about a minute;
    /// on-device the limit doesn't apply – then less often (otherwise the text grows endlessly, and in the
    /// background every restart is more likely to fail)
    private let standbyRefreshInterval: TimeInterval = 50
    private let onDeviceStandbyRefreshInterval: TimeInterval = 240
    /// How long to wait for the command after the wake word
    private let wakeCommandTimeout: TimeInterval = 7

    override init() {
        super.init()
        appleSynthesizer.delegate = self
        setLanguage(languageCode)
        // Glasses connected/disconnected, phone call, etc.: the input format changes, the recording must be set up again
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.engineConfigurationChanged() }
        }
    }

    // MARK: Settings

    /// Language for recognition and voice (used to be fixed to English – German was not understood).
    func setLanguage(_ code: String) {
        languageCode = code
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: code))
    }

    func configureElevenLabs(apiKey: String, voiceId: String) {
        elevenLabsClient = apiKey.isEmpty ? nil : ElevenLabsTTSClient(apiKey: apiKey)
        elevenLabsVoiceId = voiceId
    }

    func setPauseThreshold(_ threshold: TimeInterval) {
        pauseThreshold = threshold
    }

    func requestAuthorization() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        let mic = await AVAudioApplication.requestRecordPermission()
        return speech == .authorized && mic
    }

    // MARK: Listening (Apple speech recognition, on-device when possible)

    /// Waits for the wake word. Without the wake word setting, it just stops.
    func enterStandby() {
        guard wakeWordEnabled, !isSpeaking else {
            stopListening()
            return
        }
        do {
            try startListening(mode: .standby)
        } catch {
            scheduleStandbyRestart()
        }
    }

    /// - Parameter noSpeechTimeout: If no word comes within this time, listening ends (e.g. after an answer).
    func startListening(mode: ListenMode = .command, noSpeechTimeout: TimeInterval? = nil) throws {
        if isSpeaking { stopSpeaking() }
        stopListening()

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            throw SpeechError.recognizerUnavailable(languageCode)
        }
        try ensureEngineRunning()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.contextualStrings = WakeWord.contextualStrings
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true // Privacy: speech does not leave the iPhone
        }
        recognitionRequest = request
        sink.set(request)

        generation += 1
        let session = generation
        pauseHandled = false
        viaWakeWord = false
        transcribedText = ""
        listenMode = mode

        if mode == .standby {
            let interval = request.requiresOnDeviceRecognition ? onDeviceStandbyRefreshInterval : standbyRefreshInterval
            standbyRefreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.generation == session, self.listenMode == .standby else { return }
                    self.enterStandby()
                }
            }
        } else if let noSpeechTimeout {
            startNoSpeechTimer(noSpeechTimeout, session: session)
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor [weak self] in
                guard let self, self.generation == session, self.listenMode != nil else { return }
                if let text { self.handleTranscript(text, isFinal: isFinal) }
                if failed && !self.pauseHandled { self.handleRecognitionEnd() }
            }
        }
    }

    func stopListening() {
        generation += 1 // discard in-flight callbacks
        silenceTimer?.invalidate()
        silenceTimer = nil
        noSpeechTimer?.invalidate()
        noSpeechTimer = nil
        standbyRefreshTimer?.invalidate()
        standbyRefreshTimer = nil
        sink.set(nil) // recording continues but no longer goes to any recognition
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        listenMode = nil
        transcribedText = ""
    }

    // MARK: Recording (runs continuously while listening)

    /// Start recording if it isn't running yet – with the format of the active route
    /// (iPhone 48 kHz, glasses/HFP 8–16 kHz).
    private func ensureEngineRunning() throws {
        try AudioSessionManager.shared.configureForVoiceChat()
        if !tapInstalled {
            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            guard format.channelCount > 0, format.sampleRate > 0 else {
                throw SpeechError.inputNotReady
            }
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [sink] buffer, _ in
                sink.append(buffer)
            }
            tapInstalled = true
        }
        if !audioEngine.isRunning {
            audioEngine.prepare()
            try audioEngine.start()
        }
    }

    /// Release the microphone completely (no wake word, app disconnected) – the orange dot disappears too
    func releaseMicrophone() {
        stopListening()
        if audioEngine.isRunning { audioEngine.stop() }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
    }

    /// Route or format changed – set up recording again and continue where we left off
    private func engineConfigurationChanged() {
        let mode = listenMode
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if audioEngine.isRunning { audioEngine.stop() }
        switch mode {
        case .standby: enterStandby()
        case .command: handleRecognitionEnd()
        case nil: break
        }
    }

    private func handleTranscript(_ text: String, isFinal: Bool) {
        switch listenMode {
        case .standby:
            standbyRetries = 0
            // Nothing is shown in standby – only listening for the wake word
            guard let command = WakeWord.command(in: text) else { return }
            listenMode = .command
            viaWakeWord = true
            standbyRefreshTimer?.invalidate()
            standbyRefreshTimer = nil
            Chime.shared.play()
            onWakeWord?()
            transcribedText = command
            if command.isEmpty {
                startNoSpeechTimer(wakeCommandTimeout, session: generation)
            } else {
                resetSilenceTimer()
            }
        case .command:
            noSpeechTimer?.invalidate()
            noSpeechTimer = nil
            transcribedText = viaWakeWord ? (WakeWord.command(in: text) ?? text) : text
            guard !transcribedText.isEmpty else { return }
            resetSilenceTimer()
            if isFinal { handlePause() }
        case nil:
            break
        }
    }

    /// Recognition ended (error, silence, Apple's time limit)
    private func handleRecognitionEnd() {
        if listenMode == .standby {
            scheduleStandbyRestart()
            return
        }
        let heard = transcribedText
        stopListening()
        onListeningStopped?(heard.isEmpty ? nil : heard)
    }

    /// Restart standby with a growing pause if recognition fails repeatedly
    private func scheduleStandbyRestart() {
        stopListening()
        standbyRetries += 1
        let delay = min(0.3 * Double(standbyRetries), 5.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.listenMode == nil, !self.isSpeaking, self.wakeWordEnabled else { return }
            self.enterStandby()
        }
    }

    private func startNoSpeechTimer(_ timeout: TimeInterval, session: Int) {
        noSpeechTimer?.invalidate()
        noSpeechTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == session, self.transcribedText.isEmpty else { return }
                self.stopListening()
                self.onListeningStopped?(nil)
            }
        }
    }

    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        let session = generation
        silenceTimer = Timer.scheduledTimer(withTimeInterval: pauseThreshold, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == session else { return }
                self.handlePause()
            }
        }
    }

    /// Pause or final result – passed on only ONCE per utterance (used to be doubled at times).
    private func handlePause() {
        guard !pauseHandled, listenMode == .command else { return }
        let text = transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        pauseHandled = true
        stopListening()
        onSpeechPause?(text)
    }

    // MARK: Speaking

    /// Local speech output: ElevenLabs (if key set), otherwise the free iPhone voice.
    func speak(_ text: String) {
        stopSpeaking()
        isSpeaking = true
        if let client = elevenLabsClient {
            Task {
                do {
                    let audio = try await client.synthesize(text: text, voiceId: elevenLabsVoiceId)
                    guard isSpeaking else { return }
                    AudioDataPlayer.shared.play(data: audio) { [weak self] in self?.finishSpeaking() }
                } catch {
                    guard isSpeaking else { return }
                    speakWithApple(text)
                }
            }
        } else {
            speakWithApple(text)
        }
    }

    /// Play voice audio (MP3) that arrived inside the PC's reply.
    func playAudioData(_ data: Data) {
        stopSpeaking()
        isSpeaking = true
        AudioDataPlayer.shared.play(data: data) { [weak self] in self?.finishSpeaking() }
    }

    /// Play audio generated by the PC (channel mode, with token header).
    func playRemoteAudio(request: URLRequest, fallbackText: String) {
        stopSpeaking()
        isSpeaking = true
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                guard isSpeaking else { return }
                AudioDataPlayer.shared.play(data: data) { [weak self] in self?.finishSpeaking() }
            } catch {
                print("[Speech] Audio from the PC could not be played (\(error.localizedDescription)) – iPhone voice")
                onVoiceNote?("Voice audio from the PC failed (\(error.localizedDescription)) – using the iPhone voice")
                guard isSpeaking else { return }
                speakWithApple(fallbackText)
            }
        }
    }

    func stopSpeaking() {
        AudioDataPlayer.shared.stop()
        if appleSynthesizer.isSpeaking { appleSynthesizer.stopSpeaking(at: .immediate) }
        isSpeaking = false
    }

    private func finishSpeaking() {
        guard isSpeaking else { return }
        isSpeaking = false
        onSpeechFinished?()
    }

    private func speakWithApple(_ text: String) {
        try? AudioSessionManager.shared.configureForVoiceChat()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.bestVoice(for: languageCode)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        appleSynthesizer.speak(utterance)
    }

    /// Best installed voice for the language (Premium > Enhanced > Standard)
    private static func bestVoice(for code: String) -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == code }
        return voices.first { $0.quality == .premium }
            ?? voices.first { $0.quality == .enhanced }
            ?? AVSpeechSynthesisVoice(language: code)
    }
}

extension SpeechManager: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishSpeaking() }
    }
}

/// Passes the audio buffers of the continuous recording on to the currently active recognition.
/// Called from the audio thread – hence a lock instead of the main actor.
final class RecognitionSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func set(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        self.request = request
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let current = request
        lock.unlock()
        current?.append(buffer)
    }
}

enum SpeechError: LocalizedError {
    case recognizerUnavailable(String)
    case inputNotReady

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable(let code):
            return "Speech recognition for \(code) is not available – check the language in Settings"
        case .inputNotReady:
            return "Microphone not ready yet – please tap again"
        }
    }
}

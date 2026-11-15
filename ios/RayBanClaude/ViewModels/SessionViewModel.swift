import Foundation
import Combine
import SwiftUI
import UIKit
import MWDATCore

enum SessionState: String {
    case disconnected = "Disconnected"
    case idle = "Ready"
    case standby = "Say \"Hey Claude\""
    case listening = "Listening"
    case thinking = "Thinking"
    case speaking = "Speaking"
}

/// Which route a question is currently taking to Claude
enum Route: Equatable {
    /// PC: Claude Code (channel) or gateway
    case pc
    /// No PC: directly to the Claude API
    case direct
    /// Neither PC reachable nor API key available
    case none
}

@MainActor
final class SessionViewModel: ObservableObject {
    @Published private(set) var state: SessionState = .disconnected
    @Published private(set) var transcript: [TranscriptMessage] = []
    @Published private(set) var currentTranscription: String = ""
    @Published private(set) var isConnected: Bool = false
    @Published private(set) var isProcessing: Bool = false
    @Published var errorMessage: String?
    @Published var notice: String?

    @Published var config: ClaudeConfig {
        didSet {
            guard config != oldValue else { return }
            applyConfig()
            config.save()
            if config.wakeWordEnabled != oldValue.wakeWordEnabled, state == .idle || state == .standby { goIdle() }
            if config.memoryEnabled != oldValue.memoryEnabled { syncMemory() }
        }
    }

    /// Connected via Tailscale (away) instead of the home Wi-Fi
    @Published private(set) var viaTailscale = false

    @Published var activeFrameSource: FrameSourceType = .iPhone {
        didSet { if activeFrameSource != oldValue { switchFrameSource() } }
    }
    @Published private(set) var frameSourceStatus: FrameSourceStatus = .disconnected

    /// Pairing from QR code – waiting for confirmation
    @Published var pendingPairing: PairingRequest?
    /// Tool approval from Claude Code – waiting for Allow/Deny
    @Published private(set) var pendingPermission: PermissionRequest?

    @Published var codeToast: DetectedCode?

    let modeManager = ModeManager()
    let bridge: ClaudeBridge
    let speechManager = SpeechManager()
    let cameraManager = CameraManager()
    let rayBanManager = RayBanManager()
    let phoneActions = PhoneActionHandler()
    let directClient = DirectClaudeClient()
    /// What Claude remembers about you – in demo mode only in memory
    let memory = MemoryStore(persistent: !DemoMode.isActive)

    private var cancellables = Set<AnyCancellable>()
    private var watchdog: Task<Void, Never>?
    private var lastGatewayMode: String?
    /// Gateway conversation already knows the memory
    private var gatewayMemorySent = false
    /// The photo Claude received last (for "Take a photo" → save to the photo library)
    private var lastPhoto: (data: Data, date: Date)?
    /// For this long the last photo still counts as "the photo from just now"
    private let lastPhotoValidity: TimeInterval = 120
    /// Route of the question currently being processed
    private var processingRoute: Route = .none

    /// Without a delivery confirmation, a message counts as lost after this time
    private let ackTimeout: UInt64 = 10_000_000_000
    /// Without a reply from Claude, "Thinking" ends after this time
    private let replyTimeout: UInt64 = 180_000_000_000
    /// After a reply, wait this long for a follow-up, then go back to the wake word
    private let followUpTimeout: TimeInterval = 8
    /// After the double tap, wait this long for the question (as after "Hey Claude")
    private let gestureListenTimeout: TimeInterval = 7
    /// Question for the capture button – `VisionIntent` recognizes from it that a photo is needed
    static let gesturePhotoQuestion = "What do you see?"

    init(config: ClaudeConfig = ClaudeConfig.load()) {
        self.config = config
        self.bridge = ClaudeBridge(config: config)
        applyConfig()
        setupBindings()
        setupBridgeCallbacks()
        setupSpeechCallbacks()
        setupPhoneActions()
        memory.onChange = { [weak self] in self?.syncMemory() }
        if DemoMode.isActive {
            loadDemo()
        } else {
            rayBanManager.startMonitoringRegistration()
            // The glasses take priority: if paired, they are the camera (iPhone only as a fallback)
            if rayBanManager.isRegistered { activeFrameSource = .rayBan }
        }
    }

    /// Sample conversation for screenshots (`-demo`): nothing is started or sent
    private func loadDemo() {
        activeFrameSource = .rayBan
        isConnected = true
        frameSourceStatus = .connected
        modeManager.setActiveMode(VisionMode.hvac)
        transcript = [
            TranscriptMessage(role: .user, text: "How old is the boiler and what does F28 mean?"),
            TranscriptMessage(role: .assistant, text: "A Thermavia CondensPro 24 from 2014, so a good twelve years old. F28 means: ignition failed – first check whether the gas valve is open."),
            TranscriptMessage(role: .user, text: "Set a timer for ten minutes for the pasta."),
            TranscriptMessage(role: .system, text: "📱 Timer \"Pasta\" set for 10 min"),
            TranscriptMessage(role: .assistant, text: "On it – I'll let you know in ten minutes."),
        ]
        var confirmation: ActionConfirmation?
        if DemoMode.showConfirmation {
            transcript.append(TranscriptMessage(role: .user, text: "Call Mom."))
            transcript.append(TranscriptMessage(role: .system, text: "📱 Follow-up on the iPhone: call Mom (mobile)"))
            confirmation = ActionConfirmation(kind: .call, title: "Call Mom?",
                                              options: [.init(label: "Mom (mobile)", value: "+490000000000")])
        }
        phoneActions.showDemo(timerLabel: "Pasta", seconds: 9 * 60 + 41, confirmation: confirmation)
        memory.loadDemo(["Daughter is named Mia, birthday on May 3", "Drinks espresso without sugar", "Works as a heating engineer"])
        state = .standby
    }

    // MARK: - Setup

    private func applyConfig() {
        bridge.updateConfig(config)
        speechManager.setLanguage(config.speechLanguage)
        speechManager.setPauseThreshold(config.speechPauseThreshold)
        speechManager.configureElevenLabs(apiKey: config.elevenLabsAPIKey, voiceId: config.elevenLabsVoiceId)
        speechManager.wakeWordEnabled = config.wakeWordEnabled
        phoneActions.memory = config.memoryEnabled ? memory : nil
        cameraManager.configure(frameInterval: config.videoFrameInterval, jpegQuality: config.videoJPEGQuality)
        rayBanManager.configure(frameInterval: config.videoFrameInterval, jpegQuality: config.videoJPEGQuality)
        rayBanManager.gesturesEnabled = config.glassesGestures
    }

    private func setupBindings() {
        // Pass mode and action changes on to the UI. The glasses are deliberately
        // NOT passed on – otherwise every video frame would recompute the whole UI.
        [modeManager.objectWillChange, phoneActions.objectWillChange, memory.objectWillChange].forEach { publisher in
            publisher.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        }

        bridge.$state
            .sink { [weak self] state in self?.bridgeStateChanged(state) }
            .store(in: &cancellables)

        bridge.$isRemote
            .sink { [weak self] remote in self?.viaTailscale = remote }
            .store(in: &cancellables)

        // Glasses paired later → use the glasses from now on
        rayBanManager.$isRegistered
            .removeDuplicates()
            .dropFirst()
            .filter { $0 }
            .sink { [weak self] _ in self?.activeFrameSource = .rayBan }
            .store(in: &cancellables)

        rayBanManager.$connectionStatus
            .sink { [weak self] status in
                guard let self, self.activeFrameSource == .rayBan else { return }
                self.frameSourceStatus = status
            }
            .store(in: &cancellables)

        // Touchpad and capture button of the glasses (like Meta AI)
        rayBanManager.onGesture = { [weak self] gesture in self?.handleGlassesGesture(gesture) }

        cameraManager.$connectionStatus
            .sink { [weak self] status in
                guard let self, self.activeFrameSource == .iPhone else { return }
                self.frameSourceStatus = status
            }
            .store(in: &cancellables)

        speechManager.$transcribedText
            .sink { [weak self] text in
                guard let self else { return }
                self.currentTranscription = text
                // Wake the camera while the question is still being spoken ("What does it say on the …") – saves waiting time
                if self.speechManager.listenMode == .command, VisionIntent.needsImage(text) {
                    self.activeSource.prepareCapture()
                }
            }
            .store(in: &cancellables)

        cameraManager.$lastDetectedCode
            .compactMap { $0 }
            .sink { [weak self] code in self?.handleDetectedCode(code) }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .audioInterruptionBegan)
            .sink { [weak self] _ in
                self?.speechManager.stopListening()
                self?.speechManager.stopSpeaking()
                if self?.isConnected == true { self?.state = .idle }
            }
            .store(in: &cancellables)

        // After a call or similar, listen for the wake word again
        NotificationCenter.default.publisher(for: .audioInterruptionEnded)
            .sink { [weak self] _ in self?.goIdle() }
            .store(in: &cancellables)
    }

    private func bridgeStateChanged(_ bridgeState: ClaudeBridge.ConnectionState) {
        isConnected = bridgeState == .connected
        switch bridgeState {
        case .connected:
            errorMessage = nil
        case .failed(let message):
            if route == .direct {
                notice = "PC unreachable – asking directly"
            } else {
                errorMessage = message
            }
            fallthrough
        case .disconnected, .connecting:
            if processingRoute == .pc { finishProcessing() }
            pendingPermission = nil
            if route == .direct {
                activateDirect()
            } else if state != .disconnected {
                speechManager.releaseMicrophone()
                state = .disconnected
            }
        }
    }

    private func setupBridgeCallbacks() {
        bridge.onConnected = { [weak self] in
            guard let self else { return }
            try? AudioSessionManager.shared.configureForVoiceChat()
            self.syncMemory() // Claude on the PC gets the memory list with the first message
            if !self.activeSource.isRunning { self.startActiveFrameSource() }
            self.goIdle()
        }
        bridge.onMemory = { [weak self] op, items in self?.applyMemoryFromPC(op: op, items: items) }
        bridge.onReply = { [weak self] reply in self?.handleReply(reply) }
        bridge.onEdit = { [weak self] id, text in
            guard let self, let index = self.transcript.firstIndex(where: { $0.id == id }) else { return }
            self.transcript[index].text = text
        }
        bridge.onAck = { [weak self] id in
            guard let self, let index = self.transcript.firstIndex(where: { $0.id == id }) else { return }
            self.transcript[index].delivered = true
            self.armWatchdog(replyTimeout: true)
        }
        bridge.onCaptureRequest = { [weak self] id, reason in
            Task { await self?.handleCaptureRequest(id: id, reason: reason) }
        }
        bridge.onPermissionRequest = { [weak self] request in self?.handlePermissionRequest(request) }
        bridge.onPermissionResolved = { [weak self] id in
            if self?.pendingPermission?.id == id { self?.pendingPermission = nil }
        }
        bridge.onPhoneAction = { [weak self] action in
            Task { await self?.handlePhoneAction(action) }
        }
        bridge.onServerError = { [weak self] message in
            self?.errorMessage = message
            self?.finishProcessing()
        }
    }

    private func setupSpeechCallbacks() {
        speechManager.onSpeechPause = { [weak self] text in
            Task { await self?.handleUserSpeech(text) }
        }
        speechManager.onWakeWord = { [weak self] in
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            self?.state = .listening
        }
        speechManager.onSpeechFinished = { [weak self] in
            guard let self, self.state == .speaking else { return }
            // canTalk instead of isConnected – otherwise there was never a follow-up without a PC (direct)
            if self.config.autoListen && self.canTalk {
                // Wait briefly for a follow-up – with the wake word, return to standby afterwards
                self.startListening(noSpeechTimeout: self.config.wakeWordEnabled ? self.followUpTimeout : nil)
            } else {
                self.goIdle()
            }
        }
        // Listening ended without a command (silence, error) → back to standby
        speechManager.onListeningStopped = { [weak self] _ in
            guard let self, self.state == .listening else { return }
            self.goIdle()
        }
    }

    private func setupPhoneActions() {
        phoneActions.latestPhoto = { [weak self] in
            guard let self else { return nil }
            if let recent = self.lastPhoto, Date().timeIntervalSince(recent.date) < self.lastPhotoValidity {
                return recent.data
            }
            return await self.takePhoto()
        }
        phoneActions.onTimerFired = { [weak self] timer in
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            let text = timer.isAlarm ? "Alarm: \(timer.label)." : "Your timer \(timer.label) has finished."
            self?.transcript.append(TranscriptMessage(role: .system, text: "⏱ \(text)"))
            self?.speak(text, audioPath: nil)
        }
    }

    /// PC connected → PC; otherwise (if allowed and API key present) direct; otherwise nothing
    var route: Route {
        if config.connectionMode == .direct { return config.hasDirectKey ? .direct : .none }
        if isConnected { return .pc }
        return config.directFallback && config.hasDirectKey ? .direct : .none
    }

    /// Can a question be asked right now (PC or direct)?
    var canTalk: Bool { route != .none }

    /// Resting state without active recording: with wake word "Say Hey Claude", otherwise "Ready"
    private var restingState: SessionState {
        guard canTalk else { return .disconnected }
        return config.wakeWordEnabled ? .standby : .idle
    }

    /// Back to the resting state – with the wake word, the app listens for "Hey Claude" again.
    func goIdle() {
        guard !speechManager.isSpeaking else { return }
        if canTalk && config.wakeWordEnabled {
            speechManager.enterStandby()
        } else {
            speechManager.releaseMicrophone() // without the wake word nobody needs the microphone
        }
        state = isProcessing ? .thinking : restingState
    }

    // MARK: - Foreground / Background

    /// Locked or in your pocket: with pocket mode the app keeps listening through the glasses
    /// (background audio), otherwise it releases the microphone. Back in the foreground it resumes.
    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            if !config.listenWhenLocked {
                speechManager.releaseMicrophone()
                // End the glasses session cleanly before the app is suspended – otherwise the glasses can get stuck
                rayBanManager.releaseCamera()
                if state == .standby || state == .listening { state = .idle }
            }
        case .active:
            Task { await phoneActions.refreshTimers() }
            // If the glasses were released before suspending, the gestures come back now
            if activeFrameSource == .rayBan, canTalk { rayBanManager.restoreGestureSession() }
            if !speechManager.isSpeaking, !speechManager.isListening, state != .disconnected { goIdle() }
        default:
            break
        }
    }

    // MARK: - Connection

    func connect() async {
        errorMessage = nil
        if config.connectionMode.usesPC {
            if config.baseURL != nil, !config.channelToken.isEmpty {
                await bridge.connect()
            } else if !config.hasDirectKey {
                errorMessage = "Not paired yet – scan the QR code in the PC dashboard or set up \"No PC\" in Settings"
            }
        }
        if route == .direct { activateDirect() }
        if route == .none && config.connectionMode == .direct {
            errorMessage = DirectError.missingKey.localizedDescription
        }
    }

    /// Get going without a PC: start the camera and listen for the wake word
    private func activateDirect() {
        if !activeSource.isRunning { startActiveFrameSource() }
        if state == .disconnected || state == .idle || state == .standby { goIdle() }
    }

    func disconnect() {
        speechManager.releaseMicrophone()
        speechManager.stopSpeaking()
        cameraManager.stop()
        rayBanManager.stop()
        bridge.disconnect()
        frameSourceStatus = .disconnected
        state = .disconnected
    }

    /// Links into the app: pairing (`raybanclaude://pair?…`) or callback from the Meta AI app.
    func handleIncomingURL(_ url: URL) {
        if let pairing = PairingRequest(url: url) {
            pendingPairing = pairing
            return
        }
        guard URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .contains(where: { $0.name == "metaWearablesAction" }) == true else {
            if url.host == PairingRequest.urlHost {
                errorMessage = "Invalid pairing code – generate a new one in the dashboard"
            }
            return
        }
        Task {
            do {
                _ = try await Wearables.shared.handleUrl(url)
            } catch {
                errorMessage = "Meta AI callback failed: \(error.localizedDescription)"
            }
        }
    }

    func confirmPairing() {
        guard let pairing = pendingPairing else { return }
        pendingPairing = nil
        var updated = config
        updated.gatewayHost = pairing.host
        updated.remoteHost = pairing.remote ?? ""
        updated.gatewayPort = pairing.port
        updated.channelToken = pairing.token
        updated.connectionMode = .channel
        config = updated
        notice = pairing.remote == nil
            ? "Paired with \(pairing.host)"
            : "Paired – via Wi-Fi at home, via Tailscale when away"
        Task { await connect() }
    }

    func connectGlasses() async {
        await rayBanManager.register()
    }

    // MARK: - Frame source

    private func switchFrameSource() {
        cameraManager.stop()
        rayBanManager.stop()
        frameSourceStatus = .disconnected
        if canTalk { startActiveFrameSource() }
    }

    private func startActiveFrameSource() {
        do {
            switch activeFrameSource {
            case .iPhone: try cameraManager.start()
            case .rayBan: try rayBanManager.start()
            }
        } catch {
            frameSourceStatus = .error(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    private var activeSource: any FrameSource {
        switch activeFrameSource {
        case .iPhone: return cameraManager
        case .rayBan: return rayBanManager
        }
    }

    // MARK: - QR codes / barcodes

    private func handleDetectedCode(_ code: DetectedCode) {
        if modeManager.activeMode.id == VisionMode.qrScanner.id {
            Task { await sendText("I scanned a \(code.typeLabel) code: \(code.value). What is this?") }
            return
        }
        codeToast = code
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            if self?.codeToast?.timestamp == code.timestamp { self?.codeToast = nil }
        }
    }

    func sendCodeToChat(_ code: DetectedCode) {
        codeToast = nil
        Task { await sendText("I scanned a \(code.typeLabel) code: \(code.value). What is this?") }
    }

    func copyCodeToClipboard(_ code: DetectedCode) {
        UIPasteboard.general.string = code.value
        codeToast = nil
        notice = "Copied"
    }

    // MARK: - Speech

    /// Microphone button: listen immediately in standby or idle, cancel while listening
    func toggleListening() {
        if speechManager.listenMode == .command {
            speechManager.stopListening()
            goIdle()
        } else {
            startListening()
        }
    }

    func startListening(noSpeechTimeout: TimeInterval? = nil) {
        do {
            try speechManager.startListening(mode: .command, noSpeechTimeout: noSpeechTimeout)
            state = .listening
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            goIdle()
        }
    }

    func interruptSpeaking() {
        speechManager.stopSpeaking()
        state = restingState
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.startListening()
        }
    }

    // MARK: - Glasses gestures

    /// Like Meta AI: double tap → listen immediately (no wake word, even in the middle of an answer),
    /// capture button → photo and "What do you see?", back → cancel.
    private func handleGlassesGesture(_ gesture: GlassesGesture) {
        guard activeFrameSource == .rayBan else { return }
        guard canTalk else {
            notice = "Not connected – pair with the PC or set up \"No PC\""
            return
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        switch gesture {
        case .listen:
            startListening(noSpeechTimeout: gestureListenTimeout)
        case .photo:
            speechManager.stopSpeaking()
            rayBanManager.prepareCapture() // Wake the camera before the question goes out
            Task { await sendText(Self.gesturePhotoQuestion) }
        case .cancel:
            speechManager.stopSpeaking()
            speechManager.stopListening()
            goIdle()
        }
    }

    // MARK: - Sending

    func sendText(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await handleUserSpeech(trimmed)
    }

    private func handleUserSpeech(_ text: String) async {
        // Open approval or follow-up question? Then "yes"/"no" is the answer to it.
        if let request = pendingPermission, let allow = Self.interpretYesNo(text) {
            await answerPermission(request, allow: allow)
            goIdle()
            return
        }
        if let confirmation = phoneActions.confirmation, confirmation.options.count == 1, let yes = Self.interpretYesNo(text) {
            if yes { confirmAction(confirmation.options[0]) } else { dismissAction() }
            goIdle()
            return
        }
        guard !isProcessing else {
            notice = "Claude is still answering – wait a moment"
            goIdle()
            return
        }
        // This used to be "guard isConnected" – that completely blocked the no-PC (direct) route
        let currentRoute = route
        guard currentRoute != .none else {
            errorMessage = "Not connected – pair with the PC or set up \"No PC\""
            return
        }

        let id = "ios-\(UUID().uuidString.prefix(8))"
        let viaChannel = currentRoute == .pc && config.connectionMode == .channel
        transcript.append(TranscriptMessage(id: id, role: .user, text: text, delivered: !viaChannel))
        currentTranscription = ""
        isProcessing = true
        processingRoute = currentRoute
        errorMessage = nil
        goIdle() // while Claude is thinking, the app keeps responding to "Hey Claude"
        // Like Meta AI: photo only if the question needs one – otherwise the camera stays off
        let image = VisionIntent.needsImage(text) ? await photoForQuestion() : nil

        if currentRoute == .direct {
            await sendDirect(text: text, image: image)
        } else if viaChannel {
            do {
                armWatchdog(replyTimeout: false)
                try await bridge.send(.init(id: id, text: text, source: activeFrameSource, mode: modeManager.activeMode, image: image))
            } catch {
                errorMessage = error.localizedDescription
                finishProcessing()
            }
        } else {
            await sendViaGateway(text: text, image: image)
        }
    }

    /// Photo for a question: iPhone viewfinder → current frame; glasses → briefly turn the camera on, take a photo, turn it off again
    private func photoForQuestion() async -> Data? {
        if activeFrameSource == .iPhone, let frame = activeSource.consumeFrame() {
            lastPhoto = (frame, Date())
            return frame
        }
        let photo = await takePhoto()
        if photo == nil {
            notice = activeFrameSource == .rayBan
                ? "Glasses could not take a photo – asking without an image"
                : "No camera image – asking without an image"
        }
        return photo
    }

    /// Take a fresh photo and remember it as "the photo from just now". Glasses first – if they can't right now,
    /// the iPhone camera steps in (if the app is open).
    private func takePhoto() async -> Data? {
        var captured = await activeSource.capturePhoto()
        if captured == nil, activeFrameSource == .rayBan, let fallback = await iPhoneFallbackPhoto() {
            notice = "Glasses not ready – photo with the iPhone camera"
            captured = fallback
        }
        guard let photo = captured else { return nil }
        lastPhoto = (photo, Date())
        transcript.append(TranscriptMessage(role: .system, text: "📸 Photo sent to Claude"))
        return photo
    }

    /// Fallback photo with the iPhone camera (only when the app is in the foreground – otherwise iOS blocks the camera)
    private func iPhoneFallbackPhoto() async -> Data? {
        guard UIApplication.shared.applicationState == .active else { return nil }
        let wasRunning = cameraManager.isRunning
        if !wasRunning {
            guard (try? cameraManager.start()) != nil else { return nil }
            // Let the camera start up and expose briefly (max. 2 s)
            for _ in 0..<20 where !cameraManager.isRunning {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        let photo = await cameraManager.capturePhoto()
        if !wasRunning { cameraManager.stop() }
        return photo
    }

    /// No PC: directly to the Claude API; phone actions and photos run locally
    private func sendDirect(text: String, image: Data?) async {
        do {
            let answer = try await directClient.ask(text, image: image, mode: modeManager.activeMode, config: config,
                                                    memory: config.memoryEnabled ? memory.texts : nil) { [weak self] name, input in
                await self?.executeDirectTool(name: name, input: input)
                    ?? DirectClaudeClient.ToolOutput(text: "App not available", isError: true)
            }
            transcript.append(TranscriptMessage(role: .assistant, text: answer.text, toolCalls: answer.toolsUsed))
            finishProcessing()
            speak(answer.text, audioPath: nil)
        } catch {
            errorMessage = error.localizedDescription
            finishProcessing()
        }
    }

    private func executeDirectTool(name: String, input: [String: Any]) async -> DirectClaudeClient.ToolOutput {
        switch name {
        case "take_photo":
            guard let photo = await takePhoto() else {
                return DirectClaudeClient.ToolOutput(text: "No camera image available (glasses not ready or iPhone camera off)", isError: true)
            }
            return DirectClaudeClient.ToolOutput(text: "Current photo", imageJPEG: photo)
        case "phone_action":
            guard let kind = (input["action"] as? String).flatMap(PhoneAction.Kind.init(rawValue:)) else {
                return DirectClaudeClient.ToolOutput(text: "Unknown action", isError: true)
            }
            let action = PhoneAction(
                id: UUID().uuidString, kind: kind,
                durationSeconds: input["duration_seconds"] as? Int,
                time: input["time"] as? String,
                date: input["date"] as? String,
                label: input["label"] as? String,
                contact: input["contact"] as? String,
                number: input["number"] as? String,
                text: input["text"] as? String,
                destination: input["destination"] as? String
            )
            let result = await phoneActions.handle(action)
            transcript.append(TranscriptMessage(role: .system, text: (result.ok ? "📱 " : "⚠️ ") + result.message))
            return DirectClaudeClient.ToolOutput(text: result.message, isError: !result.ok)
        case "remember":
            guard config.memoryEnabled, let saved = memory.add(input["fact"] as? String ?? "") else {
                return DirectClaudeClient.ToolOutput(text: "Nothing saved (empty or memory off)", isError: true)
            }
            directClient.acknowledgeMemory(memory.texts)
            transcript.append(TranscriptMessage(role: .system, text: "🧠 Remembered: \(saved)"))
            return DirectClaudeClient.ToolOutput(text: "Remembered – \(memory.items.count) entries in memory.")
        case "forget":
            let removed = memory.forget(matching: input["fact"] as? String ?? "")
            guard !removed.isEmpty else { return DirectClaudeClient.ToolOutput(text: "Nothing is saved about that.") }
            directClient.acknowledgeMemory(memory.texts)
            transcript.append(TranscriptMessage(role: .system, text: "🧠 Forgotten: \(removed.joined(separator: ", "))"))
            return DirectClaudeClient.ToolOutput(text: "Deleted: \(removed.joined(separator: " | "))")
        default:
            return DirectClaudeClient.ToolOutput(text: "Unknown tool \(name)", isError: true)
        }
    }

    private func sendViaGateway(text: String, image: Data?) async {
        let mode = modeManager.activeMode
        // Only send the mode context when it changes (the conversation remembers it)
        var prefix = lastGatewayMode == mode.id ? "" : "[Mode \"\(mode.name)\": \(mode.systemPrompt)]\n\n"
        lastGatewayMode = mode.id
        // Memory once per conversation (the gateway remembers the history); remembering only works in the app there
        if config.memoryEnabled, !gatewayMemorySent, !memory.items.isEmpty {
            prefix = MemoryStore.promptBlock(memory.texts) + "\n" + prefix
        }
        gatewayMemorySent = true
        do {
            let response = try await bridge.chatREST(text: prefix + text, images: image.map { [$0] } ?? [])
            transcript.append(TranscriptMessage(role: .assistant, text: response.text, toolCalls: response.tool_calls.map(\.name)))
            finishProcessing()
            speak(response.text, audioPath: nil)
        } catch {
            errorMessage = error.localizedDescription
            finishProcessing()
        }
    }

    private func handleReply(_ reply: ClaudeBridge.Reply) {
        transcript.append(TranscriptMessage(id: reply.id, role: .assistant, text: reply.text, attachments: reply.attachments))
        finishProcessing()
        speak(reply.text, audioPath: reply.audioPath)
    }

    private func speak(_ text: String, audioPath: String?) {
        speechManager.stopListening()
        state = .speaking
        if let audioPath, let request = bridge.fileRequest(audioPath) {
            speechManager.playRemoteAudio(request: request, fallbackText: text)
        } else {
            speechManager.speak(text)
        }
    }

    private func finishProcessing() {
        watchdog?.cancel()
        watchdog = nil
        isProcessing = false
        if state == .thinking { state = restingState }
    }

    /// The app used to get stuck on "Thinking" forever without a reply.
    private func armWatchdog(replyTimeout: Bool) {
        watchdog?.cancel()
        let delay = replyTimeout ? self.replyTimeout : ackTimeout
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self, self.isProcessing else { return }
            self.errorMessage = replyTimeout
                ? "No reply from Claude – is Claude Code still running? Check the terminal for approvals."
                : "Message did not arrive – is Claude Code running with the channel?"
            self.finishProcessing()
        }
    }

    // MARK: - Photo on request (tool request_photo)

    private func handleCaptureRequest(id: String, reason: String?) async {
        notice = "📸 Claude is taking a photo" + (reason.map { ": \($0)" } ?? "")
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        let photo = await takePhoto()
        if photo == nil { notice = "Photo not possible – glasses ready?" }
        do {
            // Reply even without a photo – otherwise Claude waits in vain
            try await bridge.send(.init(id: "photo-\(UUID().uuidString.prefix(8))",
                                        text: photo == nil ? "(Photo not possible – camera not ready)" : "",
                                        source: activeFrameSource, mode: modeManager.activeMode, image: photo, inReplyTo: id))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Phone actions (tool phone_action)

    private func handlePhoneAction(_ action: PhoneAction) async {
        let result = await phoneActions.handle(action)
        transcript.append(TranscriptMessage(role: .system, text: (result.ok ? "📱 " : "⚠️ ") + result.message))
        if phoneActions.confirmation != nil {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
        do {
            try await bridge.sendActionResult(id: action.id, result: result)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func confirmAction(_ option: ActionConfirmation.Option) {
        transcript.append(TranscriptMessage(role: .system, text: "✅ \(option.label)"))
        phoneActions.confirm(option)
    }

    func dismissAction() {
        phoneActions.dismissConfirmation()
        transcript.append(TranscriptMessage(role: .system, text: "⛔ Cancelled"))
    }

    // MARK: - Memory

    /// Send the memory list to Claude on the PC (channel only; direct and gateway get it with the question)
    private func syncMemory() {
        gatewayMemorySent = false
        Task {
            do {
                try await bridge.sendMemory(memory.texts, enabled: config.memoryEnabled)
            } catch {
                print("[Memory] Sync with the PC failed: \(error.localizedDescription)")
            }
        }
    }

    /// Claude on the PC remembered or forgot something
    private func applyMemoryFromPC(op: String, items: [String]) {
        guard config.memoryEnabled else { return }
        switch op {
        case "add":
            items.forEach { memory.add($0, notify: false) }
            transcript.append(TranscriptMessage(role: .system, text: "🧠 Remembered: \(items.joined(separator: ", "))"))
        case "remove":
            memory.remove(texts: items, notify: false)
            transcript.append(TranscriptMessage(role: .system, text: "🧠 Forgotten: \(items.joined(separator: ", "))"))
        default:
            break
        }
    }

    // MARK: - Approvals (permission relay)

    private func handlePermissionRequest(_ request: PermissionRequest) {
        pendingPermission = request
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        // Hands-free: read the question aloud, then answer with "yes"/"no"
        let question = "Claude wants to run \(request.toolName). \(request.description). Allow?"
        speak(question, audioPath: nil)
    }

    func answerPermission(_ request: PermissionRequest, allow: Bool) async {
        pendingPermission = nil
        do {
            try await bridge.sendPermission(requestId: request.id, allow: allow)
            transcript.append(TranscriptMessage(role: .system, text: allow ? "✅ \(request.toolName) allowed" : "⛔ \(request.toolName) denied"))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static let yesWords = ["ja", "jawohl", "jo", "erlauben", "erlaube", "okay", "ok", "klar", "mach", "yes", "gerne", "anrufen", "senden", "los", "yeah", "yep", "sure", "allow", "approve", "go", "call", "send", "please", "sí", "si", "dale", "claro", "listo", "permitir", "permito", "aprobar", "llamar", "enviar", "manda", "mandá", "vale", "adelante", "bueno"]
    private static let noWords = ["nein", "nö", "ne", "nicht", "ablehnen", "lehne", "stopp", "stop", "no", "abbrechen", "nope", "deny", "reject", "cancel", "never", "nop", "nunca", "cancelar", "cancela", "cancelá", "rechazar", "rechaza", "detente", "basta"]

    /// Read "yes"/"no" from a spoken answer (nil = unclear)
    static func interpretYesNo(_ text: String) -> Bool? {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let saysNo = words.contains { noWords.contains($0) }
        let saysYes = words.contains { yesWords.contains($0) }
        if saysNo { return false } // when in doubt, deny
        return saysYes ? true : nil
    }

    // MARK: - History

    func resetConversation() {
        transcript.removeAll()
        bridge.resetConversation()
        directClient.reset()
        lastGatewayMode = nil
        gatewayMemorySent = false
        errorMessage = nil
    }
}

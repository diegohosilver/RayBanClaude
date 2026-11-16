import Foundation
import Combine
import UIKit
import MWDATCore
import MWDATCamera
import MWDATInputs

/// Glasses gestures the app understands (translated from `MWDATInputs.InputEvent`)
enum GlassesGesture: Equatable {
    /// Double tap on the touchpad (or action button): listen immediately, without a wake word
    case listen
    /// Capture button pressed briefly: take a photo and ask “What do you see?”
    case photo
    /// Back gesture: cancel the answer or listening (real glasses don't deliver it yet, according to Meta)
    case cancel
}

/// Camera and gestures of the Ray-Ban Meta (Gen 1 and Gen 2) via the Meta Wearables DAT SDK 1.x.
///
/// As with Meta AI, the glasses do NOT film constantly: they are only “ready”. The device session stays
/// open so that touchpad and capture button events arrive (experimental module `MWDATInputs`) – the
/// camera, however, only starts for a photo (camera → stream → photo) and switches off again after a short
/// grace period. If gestures are turned off, the session ends together with the camera.
///
/// Flow according to the SDK: registration → camera permission → start DeviceSession →
/// wait for `.started` → attach inputs · per photo: add camera → audio (HFP) → stream.
@MainActor
final class RayBanManager: NSObject, ObservableObject, FrameSource {

    // MARK: FrameSource

    @Published private(set) var latestFrame: Data?
    @Published private(set) var latestImage: UIImage?
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var connectionStatus: FrameSourceStatus = .disconnected
    @Published private(set) var frameCount: Int = 0
    let sourceType: FrameSourceType = .rayBan

    // MARK: Device status

    @Published private(set) var glassesName: String = "Not connected"
    @Published private(set) var deviceModel: String?
    @Published private(set) var batteryLevel: Int?
    @Published private(set) var hingesOpen: Bool?
    @Published private(set) var hasActiveDevice: Bool = false
    @Published private(set) var isRegistered: Bool = false
    @Published private(set) var registrationLabel: String = "Not registered"
    @Published private(set) var updateHint: String?

    // MARK: Gestures

    /// Touchpad and capture button events are currently reaching the app
    @Published private(set) var gesturesActive: Bool = false
    /// Why gestures don't work (e.g. not enabled)
    @Published private(set) var gestureHint: String?
    /// Recognized gesture – the flow controller decides what happens
    var onGesture: ((GlassesGesture) -> Void)?
    /// Gestures on: session stays open. Off (default): session only for the photo (as before gestures).
    var gesturesEnabled = false {
        didSet {
            guard gesturesEnabled != oldValue else { return }
            gesturesEnabledChanged()
        }
    }

    // MARK: SDK objects

    private var deviceSession: DeviceSession?
    private var camera: Camera?
    private var inputs: Inputs?
    private let sessionTokens = ListenerTokenBag()
    private let streamTokens = ListenerTokenBag()
    private let inputsTokens = ListenerTokenBag()
    private let deviceTokens = ListenerTokenBag()
    private var registrationTask: Task<Void, Never>?
    /// Camera start for a photo
    private var startTask: Task<Void, Never>?
    /// Session setup – concurrent callers wait for the same setup
    private var sessionTask: Task<DeviceSession?, Never>?
    private var sessionAttempt = 0
    private var sessionRetryTask: Task<Void, Never>?
    private var inputsDrain: Task<Void, Never>?
    private var inputsAttachTask: Task<Void, Never>?
    private nonisolated let gate = FrameGate()
    private var photoWaiter: CheckedContinuation<Data?, Never>?
    /// Glasses are selected as the image source and ready (camera only starts on demand)
    private var isArmed = false
    /// Released before the app is suspended – don't reopen a session on its own
    private var isSuspended = false
    private var idleStopTask: Task<Void, Never>?
    /// Audio (HFP) has been set up once and had time to settle
    private var audioSettled = false

    // MARK: Session and gesture state

    private var sessionStartedAt: Date = .distantPast
    /// Tapped the touchpad once → session paused (system gesture)
    private var sessionPaused = false
    /// A camera has already run on this session – a restart can fail according to Meta issue #260
    private var sessionHadCamera = false
    /// Consecutive failed session rebuilds
    private var sessionFailures = 0
    /// Inputs have already left the initial `.inactive` state once
    private var inputsLeftInactive = false
    private var inputsRetries = 0
    /// Gestures not available for this app/glasses – stop trying
    private var inputsBlocked = false

    /// For photos only: according to Meta, `hvc1` also delivers with the iPhone locked (background) – `raw` only in the foreground.
    /// Medium resolution spares Bluetooth and battery; the photos themselves still arrive at 1440×1080.
    private let streamConfig = StreamConfiguration(videoCodec: .hvc1, resolution: .medium, frameRate: 15)
    /// As in Meta's BirdSpotter example: touchpad and both buttons. The capture button alone
    /// reported “active” there but delivered nothing. “Back” belongs to the app – otherwise it ends the session.
    private let inputsConfig = InputsConfiguration(sources: [.captouch, .captureButton, .actionButton], consumeBack: true)
    /// Meta: at least a 2 s pause between two sessions, otherwise the glasses can hang
    private let sessionGap: TimeInterval = 2
    private var lastTeardown: Date = .distantPast
    private let sessionStartTimeout: TimeInterval = 20
    private let hfpSettleDelay: UInt64 = 2_000_000_000       // 2 s according to the Meta docs
    private let photoTimeout: UInt64 = 12_000_000_000         // 12 s
    /// How long the camera stays on after a photo (for quick follow-up questions), then it switches off
    private let cameraKeepAlive: UInt64 = 15_000_000_000      // 15 s
    /// Wait at most this long for a running stream
    private let streamReadyTimeout: TimeInterval = 15
    /// Camera restart on the running session – then fall back: rebuild the session
    private let cameraRestartTimeout: TimeInterval = 8
    /// Let the exposure settle after the camera starts (0.4 s was too short: photos came out black)
    private let exposureSettleDelay: UInt64 = 1_500_000_000    // 1.5 s
    /// A photo that is nearly black is retried this many times, after `blackRetryDelay`
    private let blackPhotoRetries = 2
    private let blackRetryDelay: UInt64 = 1_000_000_000        // 1 s
    /// Average brightness (0–255) below which an image counts as black
    private static let blackLuminanceThreshold = 6
    private static let luminanceProbeSize = 8
    private let pollInterval: UInt64 = 100_000_000             // 0.1 s
    /// Wait at most this long for the SDK to list the paired glasses
    private let deviceListTimeout: TimeInterval = 3
    /// Only attach inputs once the glasses are really connected (wait at most this long)
    private let deviceArrivalTimeout: TimeInterval = 10
    /// Pause before (re)attaching the inputs – value from Meta's BirdSpotter example
    private let inputsAttachDelay: UInt64 = 750_000_000        // 0.75 s
    private let maxInputsRetries = 5
    /// Rebuild an aborted session (tap and hold, temple closed) after this pause
    private let sessionRetryDelay: UInt64 = 5_000_000_000      // 5 s
    private let maxSessionRetries = 3
    /// If a session ran this long, earlier failed attempts no longer count
    private let stableSessionDuration: TimeInterval = 60

    private static let pausedMessage = "Paused – tap the glasses' touchpad to resume"

    private var wearables: any WearablesInterface { Wearables.shared }

    /// Session stays open after the photo (for gestures) – otherwise it ends with the camera
    private var keepsSession: Bool { gesturesEnabled && deviceSession != nil }

    /// Status without a running camera
    private var restingStatus: FrameSourceStatus { sessionPaused ? .error(Self.pausedMessage) : .standby }

    func configure(frameInterval: TimeInterval = 1.0, jpegQuality: CGFloat = 0.85) {
        gate.update(frameInterval: frameInterval, jpegQuality: jpegQuality)
    }

    // MARK: - Registration (one-time, via the Meta AI app)

    func startMonitoringRegistration() {
        guard WearablesSupport.isConfigured else {
            registrationLabel = "Meta SDK not available"
            return
        }
        updateRegistration(wearables.registrationState)
        registrationTask?.cancel()
        registrationTask = Task { [weak self] in
            guard let stream = self?.wearables.registrationStateStream() else { return }
            for await state in stream {
                self?.updateRegistration(state)
            }
        }
    }

    private func updateRegistration(_ state: RegistrationState) {
        switch state {
        case .registered:
            isRegistered = true
            registrationLabel = "Registered"
        case .registering:
            isRegistered = false
            registrationLabel = "Registering …"
        case .available:
            isRegistered = false
            registrationLabel = "Not registered"
        case .unavailable:
            isRegistered = false
            registrationLabel = "Meta AI app missing"
        @unknown default:
            isRegistered = false
            registrationLabel = "Unknown"
        }
    }

    func register() async {
        guard !isRegistered, WearablesSupport.isConfigured else { return }
        do {
            connectionStatus = .connecting
            try await wearables.startRegistration()
        } catch {
            connectionStatus = .error("Registration failed: \(error.localizedDescription)")
        }
    }

    func unregister() async {
        stop()
        do {
            try await wearables.startUnregistration()
        } catch {
            connectionStatus = .error("Unregistering failed: \(error.localizedDescription)")
        }
    }

    // MARK: - FrameSource

    /// Select the glasses as the image source: checks registration and camera permission and opens (with gestures)
    /// the session – but doesn't film yet.
    func start() throws {
        isArmed = true
        isSuspended = false
        guard startTask == nil, sessionTask == nil, deviceSession == nil else { return } // already running / starting
        Task { [weak self] in
            guard let self, await self.ensureAccess(), self.isArmed, self.deviceSession == nil else { return }
            self.connectionStatus = .standby
            self.ensureGestureSession(resetRetries: true)
        }
    }

    func stop() {
        isArmed = false
        cancelPendingWork()
        teardown(status: .disconnected)
    }

    /// Only a fresh frame from a currently running capture – never an old one
    func consumeFrame() -> Data? {
        isRunning ? latestFrame : nil
    }

    /// Start the camera early (e.g. while the user is still saying “What does it say on …”)
    func prepareCapture() {
        guard isArmed else { return }
        scheduleIdleStop()
        // Already running, starting (stream not yet “streaming”) or session being set up
        guard camera == nil, startTask == nil else { return }
        startTask = Task { [weak self] in
            await self?.startStreaming()
            self?.startTask = nil
        }
    }

    /// Trigger a photo directly on the glasses (sharper than a video frame). Starts the camera on
    /// demand and switches it off again after a short grace period.
    func capturePhoto() async -> Data? {
        guard isArmed else { return nil }
        if !isRunning {
            guard await bringUpCamera() else {
                scheduleIdleStop()
                return nil
            }
            try? await Task.sleep(nanoseconds: exposureSettleDelay)
        }
        idleStopTask?.cancel()
        var photo = await takePhoto()
        var attempt = 0
        while let data = photo, Self.isNearlyBlack(data), attempt < blackPhotoRetries {
            attempt += 1
            print("[Glasses] Photo is black (\(data.count) bytes) – retry \(attempt)/\(blackPhotoRetries)")
            try? await Task.sleep(nanoseconds: blackRetryDelay)
            photo = await takePhoto()
        }
        scheduleIdleStop()
        return photo
    }

    /// True if the JPEG is (almost) completely black. Undecodable data counts as not black.
    private static func isNearlyBlack(_ data: Data) -> Bool {
        guard let cgImage = UIImage(data: data)?.cgImage else { return false }
        let side = luminanceProbeSize
        var pixels = [UInt8](repeating: 0, count: side * side)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return false }
        let average = pixels.reduce(0) { $0 + Int($1) } / pixels.count
        return average < blackLuminanceThreshold
    }

    /// Start the camera and wait for the stream. If it doesn't restart on the continuing session
    /// (Meta issue #260), the whole session is rebuilt once (with at least a 2 s pause).
    private func bringUpCamera() async -> Bool {
        let reused = sessionHadCamera && deviceSession != nil
        prepareCapture()
        idleStopTask?.cancel() // don't switch off during startup
        if await waitForStreaming(timeout: reused ? cameraRestartTimeout : streamReadyTimeout) { return true }
        guard reused, isArmed, !isRunning, !sessionPaused else { return false }
        print("[Glasses] Camera does not restart on the running session – rebuilding session")
        startTask?.cancel()
        startTask = nil
        teardown(status: .connecting)
        prepareCapture()
        idleStopTask?.cancel()
        return await waitForStreaming(timeout: streamReadyTimeout)
    }

    private func waitForStreaming(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isRunning { return true }
            // Startup is done, but without a camera or with an error → stop waiting
            if startTask == nil {
                if camera == nil { return false }
                if case .error = connectionStatus { return false }
            }
            try? await Task.sleep(nanoseconds: pollInterval)
        }
        return isRunning
    }

    /// After the grace period without another photo: release the camera (and the session too, without gestures)
    private func scheduleIdleStop() {
        idleStopTask?.cancel()
        idleStopTask = Task { [weak self, cameraKeepAlive] in
            try? await Task.sleep(nanoseconds: cameraKeepAlive)
            guard !Task.isCancelled, let self, self.isArmed else { return }
            self.startTask?.cancel()
            self.startTask = nil
            if self.keepsSession {
                self.stopCamera(status: self.restingStatus)
            } else {
                self.teardown(status: .standby)
            }
        }
    }

    private func takePhoto() async -> Data? {
        guard let stream = camera?.stream, stream.state == .streaming else { return latestFrame }
        photoWaiter?.resume(returning: nil)
        let photo: Data? = await withCheckedContinuation { continuation in
            photoWaiter = continuation
            if !stream.capturePhoto(format: .jpeg) {
                resolvePhoto(nil)
                return
            }
            Task { [weak self, photoTimeout] in
                try? await Task.sleep(nanoseconds: photoTimeout)
                self?.resolvePhoto(nil)
            }
        }
        // A photo from the glasses wins; the video frame is only the fallback
        return photo ?? latestFrame
    }

    private func resolvePhoto(_ data: Data?) {
        photoWaiter?.resume(returning: data)
        photoWaiter = nil
    }

    // MARK: - Flow

    /// SDK ready, glasses registered, camera permission granted? (Granting may open the Meta AI app once)
    private func ensureAccess() async -> Bool {
        guard WearablesSupport.isConfigured else {
            connectionStatus = .error("Meta SDK not available – restart the app")
            return false
        }
        guard wearables.registrationState == .registered else {
            connectionStatus = .error("Connect the glasses first: Settings → “Connect glasses via Meta AI”")
            await register()
            return false
        }
        do {
            if try await wearables.checkPermissionStatus(.camera) != .granted {
                guard try await wearables.requestPermission(.camera) == .granted else {
                    connectionStatus = .error("Camera permission denied – allow it in the Meta AI app")
                    return false
                }
            }
        } catch {
            connectionStatus = .error("Camera permission not possible: \(error.localizedDescription)")
            return false
        }
        return true
    }

    /// Get the started session – builds it if needed. Concurrent callers (photo and gestures)
    /// wait for the same setup so that two sessions never arise.
    private func startedSession() async -> DeviceSession? {
        if let session = deviceSession, sessionTask == nil {
            switch session.state {
            case .started:
                return session
            case .paused:
                connectionStatus = .error(Self.pausedMessage)
                return nil
            default:
                // Stuck or already ended → tear down cleanly and rebuild
                teardown(status: .connecting)
            }
        }
        if let pending = sessionTask { return await pending.value }
        sessionAttempt += 1
        let attempt = sessionAttempt
        let task = Task { [weak self] () -> DeviceSession? in
            let session = await self?.openSession()
            if self?.sessionAttempt == attempt { self?.sessionTask = nil }
            return session
        }
        sessionTask = task
        return await task.value
    }

    /// The paired glasses to run the session on: a connected one first, then a compatible one.
    /// The list can arrive a moment after start-up, so wait briefly for it.
    private func pairedDeviceIdentifier() async -> DeviceIdentifier? {
        let deadline = Date().addingTimeInterval(deviceListTimeout)
        var devices: [Device] = []
        repeat {
            devices = Wearables.shared.devices.compactMap { Wearables.shared.deviceForIdentifier($0) }
            if !devices.isEmpty { break }
            try? await Task.sleep(nanoseconds: pollInterval)
        } while Date() < deadline && !Task.isCancelled
        let rank: (Device) -> Int = { device in
            if device.linkState == .connected { return 0 }
            return device.compatibility() == .compatible ? 1 : 2
        }
        return devices.min { rank($0) < rank($1) }?.identifier
    }

    /// Create and start the session and (with gestures) attach the inputs
    private func openSession() async -> DeviceSession? {
        connectionStatus = .connecting

        // 1. Registration and camera permission
        guard await ensureAccess(), !Task.isCancelled else { return nil }
        let sinceLast = Date().timeIntervalSince(lastTeardown)
        if sinceLast < sessionGap {
            try? await Task.sleep(nanoseconds: UInt64((sessionGap - sinceLast) * 1_000_000_000))
        }
        guard !Task.isCancelled, isArmed else { return nil }

        // 2. Device session
        let session: DeviceSession
        do {
            // Named device, not AutoDeviceSelector: that one fills in asynchronously and is still
            // empty right after the tap, which fails with noEligibleDevice (see Meta's BirdSpotter sample)
            guard let identifier = await pairedDeviceIdentifier() else {
                connectionStatus = .error("No paired glasses found. Connect them in the Meta AI app, then \"Connect glasses via Meta AI\".")
                return nil
            }
            session = try wearables.createSession(deviceSelector: SpecificDeviceSelector(device: identifier))
        } catch {
            connectionStatus = .error(describe(error))
            return nil
        }
        deviceSession = session
        // Subscribe before start() – publishers don't replay anything
        session.statePublisher.listen { [weak self] state in
            Task { @MainActor [weak self] in self?.handle(sessionState: state, of: session) }
        }.store(in: sessionTokens)
        do {
            try session.start()
        } catch {
            teardown(status: .error(describe(error)))
            await handleUpdateRequirement(error)
            return nil
        }
        guard await waitUntilStarted(session), deviceSession === session else {
            if deviceSession === session {
                teardown(status: .error("Glasses not responding. Switched on, temples open, within Bluetooth range?"))
            }
            return nil
        }
        sessionStartedAt = Date()
        observeDevice(session.device)

        // 3. Gestures – independent of the photo, which may already be waiting
        if gesturesEnabled { scheduleInputsAttach(to: session, waitForDevice: true) }
        return session
    }

    private func waitUntilStarted(_ session: DeviceSession) async -> Bool {
        let deadline = Date().addingTimeInterval(sessionStartTimeout)
        while Date() < deadline, !Task.isCancelled {
            switch session.state {
            case .started, .paused: return true
            case .stopping, .stopped: return false
            case .idle, .starting: try? await Task.sleep(nanoseconds: pollInterval)
            }
        }
        return false
    }

    private func startStreaming() async {
        connectionStatus = .connecting

        // 1.–2. Registration, permission and session (usually already running for gestures)
        guard let session = await startedSession(), !Task.isCancelled, camera == nil else { return }

        // 3. Camera + stream – a stopped camera is invalid, so add it anew for every photo
        let cam: Camera
        do {
            guard let created = try session.addCamera(config: streamConfig) else {
                failCamera("Glasses camera not available")
                return
            }
            cam = created
        } catch {
            failCamera(describe(error))
            return
        }
        camera = cam
        sessionHadCamera = true
        subscribe(to: cam)

        // 4. Set up audio over the glasses (HFP) BEFORE starting the stream and let it settle briefly the first time
        try? AudioSessionManager.shared.configureForVoiceChat()
        if !audioSettled {
            try? await Task.sleep(nanoseconds: hfpSettleDelay)
            audioSettled = true
        }
        guard !Task.isCancelled, camera === cam else { return }
        cam.stream.start()
    }

    private func subscribe(to cam: Camera) {
        let stream = cam.stream
        // Ignore old callbacks from an already stopped camera – the camera comes and goes
        stream.statePublisher.listen { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, self.camera === cam else { return }
                self.handle(state: state)
            }
        }.store(in: streamTokens)

        stream.videoFramePublisher.listen { [weak self, gate] frame in
            // Conversion off the main thread, only the result goes to the UI
            guard let image = frame.makeUIImage() else { return }
            let jpeg = gate.jpegIfDue(image)
            Task { @MainActor [weak self] in
                guard let self, self.camera === cam else { return }
                self.latestImage = image
                self.frameCount += 1
                if let jpeg { self.latestFrame = jpeg }
            }
        }.store(in: streamTokens)

        stream.photoDataPublisher.listen { [weak self] photo in
            let data = photo.data
            Task { @MainActor [weak self] in
                guard let self, self.camera === cam else { return }
                self.resolvePhoto(data)
            }
        }.store(in: streamTokens)

        stream.errorPublisher.listen { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.camera === cam else { return }
                self.handle(error: error)
            }
        }.store(in: streamTokens)
    }

    private func handle(state: StreamState) {
        switch state {
        case .streaming:
            isRunning = true
            connectionStatus = .connected
        case .paused:
            // Tapped the touchpad once → stream paused; don't restart
            connectionStatus = .error(Self.pausedMessage)
        case .waitingForDevice, .starting, .stopping:
            connectionStatus = .connecting
        case .stopped:
            isRunning = false
            if isArmed {
                // Ended externally (e.g. temple closed) → tear down the camera, the next photo restarts it
                let status = connectionStatus.isReady || connectionStatus == .connecting ? restingStatus : connectionStatus
                if keepsSession { stopCamera(status: status) } else { teardown(status: status) }
            } else if connectionStatus == .connecting || connectionStatus == .connected {
                connectionStatus = .disconnected
            }
        @unknown default:
            break
        }
    }

    private func handle(error: StreamError) {
        if error == .photoCaptureFailed {
            resolvePhoto(nil)
            return // Stream keeps running
        }
        let message = describe(error)
        print("[Glasses] Error: \(message)")
        failCamera(message)
    }

    /// Camera failed: tear down only it (session stays for gestures) – without gestures, everything
    private func failCamera(_ message: String) {
        if keepsSession {
            stopCamera(status: .error(message))
        } else {
            teardown(status: .error(message))
        }
    }

    /// Release camera and session immediately (e.g. before iOS suspends the app), but stay ready.
    /// Back in the foreground, `restoreGestureSession()` brings the gestures back.
    func releaseCamera() {
        isSuspended = true
        cancelPendingWork()
        guard deviceSession != nil else { return }
        teardown(status: isArmed ? .standby : .disconnected)
    }

    /// Rebuild the gesture session (e.g. when the app comes to the foreground)
    func restoreGestureSession() {
        isSuspended = false
        ensureGestureSession(resetRetries: true)
    }

    private func cancelPendingWork() {
        idleStopTask?.cancel()
        idleStopTask = nil
        startTask?.cancel()
        startTask = nil
        sessionRetryTask?.cancel()
        sessionRetryTask = nil
        sessionTask?.cancel()
        sessionTask = nil
        sessionAttempt += 1
    }

    /// Release only the camera – the session (and with it the gestures) stays open
    private func stopCamera(status: FrameSourceStatus) {
        resolvePhoto(nil)
        streamTokens.clear()
        camera?.stop()
        camera = nil
        isRunning = false
        latestFrame = nil
        latestImage = nil
        connectionStatus = status
    }

    /// Tear everything down, top to bottom: inputs → camera → session
    private func teardown(status: FrameSourceStatus) {
        if deviceSession != nil { lastTeardown = Date() }
        inputsAttachTask?.cancel()
        inputsAttachTask = nil
        detachInputs(from: deviceSession)
        inputsRetries = 0
        inputsBlocked = false
        stopCamera(status: status)
        sessionTokens.clear()
        deviceSession?.stop()
        deviceSession = nil
        sessionHadCamera = false
        sessionPaused = false
    }

    // MARK: - Persistent session for gestures

    /// Set up the session for gestures if none is running (idempotent)
    private func ensureGestureSession(resetRetries: Bool = false) {
        if resetRetries { sessionFailures = 0 }
        guard isArmed, !isSuspended, gesturesEnabled, deviceSession == nil, sessionTask == nil, startTask == nil else { return }
        Task { [weak self] in
            guard let self else { return }
            guard await self.startedSession() != nil else {
                self.scheduleSessionRetry()
                return
            }
            if self.camera == nil, self.startTask == nil { self.connectionStatus = self.restingStatus }
        }
    }

    /// Rebuild an aborted or failed session after a pause – limited so the
    /// app doesn't wrestle endlessly with another app (e.g. Meta AI) over the glasses
    private func scheduleSessionRetry() {
        // Temples closed: don't try – when they open, `apply` rebuilds the session
        guard isArmed, !isSuspended, gesturesEnabled, hingesOpen != false, sessionFailures < maxSessionRetries else { return }
        // Already scheduled (e.g. a startup error reports via the status and the return value) → count only once
        guard sessionRetryTask == nil else { return }
        sessionFailures += 1
        sessionRetryTask = Task { [weak self, sessionRetryDelay] in
            try? await Task.sleep(nanoseconds: sessionRetryDelay)
            guard !Task.isCancelled, let self else { return }
            self.sessionRetryTask = nil
            self.ensureGestureSession()
        }
    }

    private func handle(sessionState state: DeviceSessionState, of session: DeviceSession) {
        guard deviceSession === session else { return } // old session
        switch state {
        case .paused:
            sessionPaused = true
            connectionStatus = .error(Self.pausedMessage)
        case .started:
            guard sessionPaused else { return }
            sessionPaused = false
            connectionStatus = isRunning ? .connected : .standby
            if gesturesEnabled, inputs == nil { scheduleInputsAttach(to: session, waitForDevice: true) }
        case .stopped:
            // Ended externally: tap and hold on the touchpad, temples closed, glasses off
            sessionEnded()
        case .idle, .starting, .stopping:
            break
        }
    }

    private func sessionEnded() {
        if Date().timeIntervalSince(sessionStartedAt) > stableSessionDuration { sessionFailures = 0 }
        idleStopTask?.cancel()
        idleStopTask = nil
        startTask?.cancel()
        startTask = nil
        let status: FrameSourceStatus = isArmed
            ? (connectionStatus.isReady || connectionStatus == .connecting ? .standby : connectionStatus)
            : .disconnected
        teardown(status: status)
        scheduleSessionRetry()
    }

    private func gesturesEnabledChanged() {
        if gesturesEnabled {
            ensureGestureSession(resetRetries: true)
            if let session = deviceSession, inputs == nil { scheduleInputsAttach(to: session, waitForDevice: false) }
            return
        }
        inputsAttachTask?.cancel()
        inputsAttachTask = nil
        sessionRetryTask?.cancel()
        sessionRetryTask = nil
        detachInputs(from: deviceSession)
        gestureHint = nil
        // Without gestures as before: session only while the camera runs
        if camera == nil, startTask == nil, deviceSession != nil {
            teardown(status: isArmed ? .standby : .disconnected)
        }
    }

    // MARK: - Gestures (MWDATInputs, experimental)

    /// Attach inputs (again) – after a short pause, when the glasses are really there and no photo
    /// is being transferred. Attached too early, they fail silently once (`deviceDisconnected`).
    private func scheduleInputsAttach(to session: DeviceSession, waitForDevice: Bool) {
        guard gesturesEnabled, !inputsBlocked, inputsAttachTask == nil else { return }
        inputsAttachTask = Task { [weak self, inputsAttachDelay, pollInterval, deviceArrivalTimeout] in
            try? await Task.sleep(nanoseconds: inputsAttachDelay)
            if waitForDevice {
                let deadline = Date().addingTimeInterval(deviceArrivalTimeout)
                while session.device?.linkState != .connected, Date() < deadline, !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: pollInterval)
                }
            }
            // Don't touch anything while a photo is coming over Bluetooth – otherwise it drops out again
            while self?.photoWaiter != nil, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: pollInterval)
            }
            guard !Task.isCancelled, let self else { return }
            self.inputsAttachTask = nil
            guard self.isArmed, self.gesturesEnabled, self.deviceSession === session, session.state == .started else { return }
            self.detachInputs(from: session)
            self.attachInputs(to: session)
        }
    }

    private func attachInputs(to session: DeviceSession) {
        guard inputs == nil else { return }
        let attached: Inputs?
        do {
            attached = try session.addInputs(configuration: inputsConfig)
        } catch {
            print("[Glasses] Gestures not attached: \(error.localizedDescription)")
            retryInputs(on: session)
            return
        }
        guard let attached else {
            // Session is running, but the glasses offer no gestures – a fact, not an error
            gestureHint = "These glasses report no gestures"
            return
        }
        inputs = attached
        inputsLeftInactive = false
        // Subscribe right away – these publishers don't replay anything either
        attached.statePublisher.listen { [weak self] state in
            Task { @MainActor [weak self] in self?.handle(inputsState: state, of: attached) }
        }.store(in: inputsTokens)
        attached.errorPublisher.listen { [weak self] error in
            Task { @MainActor [weak self] in self?.handle(inputsError: error, of: attached) }
        }.store(in: inputsTokens)
        let events = attached.events
        inputsDrain = Task { [weak self] in
            for await event in events {
                self?.handle(inputEvent: event)
            }
            // Stream ended (e.g. after an error) – the capability stays attached, so reattach
            guard !Task.isCancelled, let self, self.inputs === attached, let session = self.deviceSession else { return }
            self.retryInputs(on: session)
        }
    }

    /// Reattach inputs, at most `maxInputsRetries` times in a row (reset as soon as they are active)
    private func retryInputs(on session: DeviceSession) {
        guard !inputsBlocked, inputsAttachTask == nil else { return }
        guard inputsRetries < maxInputsRetries else {
            gestureHint = "Glasses gestures are not responding – switch the glasses off and on"
            return
        }
        inputsRetries += 1
        scheduleInputsAttach(to: session, waitForDevice: false)
    }

    private func detachInputs(from session: DeviceSession?) {
        inputsDrain?.cancel()
        inputsDrain = nil
        inputsTokens.clear()
        if inputs != nil { try? session?.removeInputs() }
        inputs = nil
        inputsLeftInactive = false
        gesturesActive = false
    }

    private func handle(inputsState state: InputsState, of capability: Inputs) {
        guard inputs === capability, let session = deviceSession else { return }
        switch state {
        case .active:
            inputsLeftInactive = true
            inputsRetries = 0
            gesturesActive = true
            gestureHint = nil
        case .activating, .deactivating:
            inputsLeftInactive = true
        case .inactive:
            gesturesActive = false
            // “inactive” is also the initial state – only a relapse counts (e.g. after a photo
            // or an activation that timed out after 10 s)
            guard inputsLeftInactive else { return }
            retryInputs(on: session)
        @unknown default:
            break
        }
    }

    private func handle(inputsError error: InputsError, of capability: Inputs) {
        guard inputs === capability else { return }
        print("[Glasses] Gesture error: \(error.description)")
        switch error {
        case .permissionDenied:
            inputsBlocked = true
            gesturesActive = false
            gestureHint = "Gestures not enabled – is developer mode on in the Meta AI app?"
        case .capabilityUnavailable:
            inputsBlocked = true
            gesturesActive = false
            gestureHint = "These glasses offer no gestures to apps"
        default:
            // Reattaching handles everything else (errors leave the capability attached)
            if let session = deviceSession { retryInputs(on: session) }
        }
    }

    /// Translate a glasses gesture into the app's language. Everything is logged – how the real
    /// glasses split double press and swipe has not yet been measured on hardware.
    private func handle(inputEvent event: InputEvent) {
        print("[Glasses] Gesture: \(event)")
        switch event {
        case .select:
            // Double tap on the touchpad (single tap and hold stay with the system)
            onGesture?(.listen)
        case .capture(let pressType, _, _):
            // Short press only – hold and double press stay unused
            guard pressType == .shortPress else { return }
            onGesture?(.photo)
        case .button:
            // Action button (Oakley Meta Vanguard) like double tap
            onGesture?(.listen)
        case .back:
            onGesture?(.cancel)
        case .nav, .drag:
            // Swipe (otherwise the glasses' volume) – deliberately no action
            break
        @unknown default:
            break
        }
    }

    // MARK: - Device state (name, battery, temples)

    private func observeDevice(_ device: Device?) {
        deviceTokens.clear()
        guard let device else { return }
        hasActiveDevice = true
        glassesName = device.name.isEmpty ? device.nameOrId() : device.name
        deviceModel = Self.modelName(device.deviceType())
        apply(DeviceState(linkState: device.linkState, batteryLevel: device.batteryLevel, hingeState: device.hingeState))
        switch device.compatibility() {
        case .deviceUpdateRequired: updateHint = "Glasses update required: open the Meta AI app and update the firmware."
        case .sdkUpdateRequired: updateHint = "This app version is too old for the glasses firmware – please update RayBan Claude."
        default: updateHint = nil
        }
        device.addDeviceStateListener { [weak self] state in
            Task { @MainActor [weak self] in self?.apply(state) }
        }.store(in: deviceTokens)
    }

    private func apply(_ state: DeviceState) {
        // Temples open again or glasses reconnected → rebuild the gesture session
        let returned = (state.hingeState == .open && hingesOpen == false)
            || (state.linkState == .connected && !hasActiveDevice)
        batteryLevel = state.batteryLevel
        hasActiveDevice = state.linkState == .connected
        switch state.hingeState {
        case .open: hingesOpen = true
        case .closed: hingesOpen = false
        default: hingesOpen = nil
        }
        // The camera restarts at the next photo anyway – only the session for gestures comes back
        if returned { ensureGestureSession(resetRetries: true) }
    }

    static func modelName(_ type: DeviceType) -> String {
        switch type {
        case .rayBanMeta: return "Ray-Ban Meta"
        case .rayBanMetaOptics: return "Ray-Ban Meta Optics"
        case .metaRayBanDisplay: return "Meta Ray-Ban Display"
        case .oakleyMetaHSTN: return "Oakley Meta HSTN"
        case .oakleyMetaVanguard: return "Oakley Meta Vanguard"
        case .metaGlasses: return "Meta glasses"
        default: return "Unknown glasses"
        }
    }

    // MARK: - Error texts

    private func handleUpdateRequirement(_ error: DeviceSessionError) async {
        guard error == .datAppOnTheGlassesUpdateRequired else { return }
        try? await wearables.openDATGlassesAppUpdate()
    }

    private func describe(_ error: DeviceSessionError) -> String {
        switch error {
        case .noEligibleDevice: return "No glasses found. Switch them on, open the temples, connected in the Meta AI app?"
        case .sessionAlreadyExists: return "The glasses are already in use by another app."
        case .thermalCritical, .thermalEmergency: return "Glasses too warm – let them cool down briefly."
        case .batteryCritical: return "Glasses battery almost empty – please charge."
        case .peakPowerShutdown: return "Glasses shut down due to a power spike – wait a moment."
        case .datAppOnTheGlassesUpdateRequired: return "Update needed on the glasses – the Meta AI app will open."
        case .insufficientSDKVersion: return "This app version is too old for the glasses – please update RayBan Claude."
        case .dwaUnavailable, .dwaOutOfStuRange: return "Glasses software reports a problem – open the Meta AI app and update the glasses."
        default: return "Glasses session failed: \(error.localizedDescription)"
        }
    }

    private func describe(_ error: StreamError) -> String {
        switch error {
        case .deviceNotFound: return "Glasses not found. Switch them on and open the temples."
        case .deviceNotConnected: return "Glasses disconnected – check Bluetooth."
        case .permissionDenied: return "Camera permission missing – allow it in the Meta AI app."
        case .hingesClosed: return "Temples closed – open them to continue."
        case .thermalHot: return "Glasses too warm – stream paused."
        case .batteryLow: return "Glasses battery low – please charge."
        case .peakPowerLimit: return "Power limit reached – wait a moment."
        case .timeout: return "Timed out – try again."
        case .videoStreamingError, .audioStreamingError: return "Video stream interrupted – reconnect."
        case .internalError: return "Internal SDK error – restart the app."
        default: return "Glasses error: \(error.localizedDescription)"
        }
    }
}

/// Throttles JPEG generation (thread-safe, runs in the glasses listener).
final class FrameGate: @unchecked Sendable {
    private let lock = NSLock()
    private var frameInterval: TimeInterval = 1.0
    private var jpegQuality: CGFloat = 0.85
    private var lastCapture: Date = .distantPast

    func update(frameInterval: TimeInterval, jpegQuality: CGFloat) {
        lock.lock(); defer { lock.unlock() }
        self.frameInterval = frameInterval
        self.jpegQuality = jpegQuality
    }

    func jpegIfDue(_ image: UIImage) -> Data? {
        lock.lock()
        let now = Date()
        guard now.timeIntervalSince(lastCapture) >= frameInterval else {
            lock.unlock()
            return nil
        }
        lastCapture = now
        let quality = jpegQuality
        lock.unlock()
        return image.jpegData(compressionQuality: quality)
    }
}

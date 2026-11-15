import Foundation
import AVFoundation

/// Manages the audio session for speaking and listening.
///
/// Important for Ray-Ban Meta Gen 2: the session is configured only ONCE as
/// `.playAndRecord` + Bluetooth HFP and is not switched constantly afterwards –
/// Meta advises against reconfiguring the AVAudioSession while a glasses session
/// is open (otherwise it results in “Device unavailable”).
final class AudioSessionManager {
    static let shared = AudioSessionManager()

    private let options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP]

    private init() {
        setupNotifications()
    }

    /// Voice chat with Bluetooth microphone (glasses). Idempotent: changes nothing if already suitable.
    func configureForVoiceChat() throws {
        let session = AVAudioSession.sharedInstance()
        let alreadyConfigured = session.category == .playAndRecord
            && session.mode == .voiceChat
            && session.categoryOptions.isSuperset(of: options)
        if !alreadyConfigured {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
        }
        try session.setActive(true)
        routeToBluetoothMicIfAvailable()
    }

    /// Order for microphone and speaker: Ray-Ban Meta → other Bluetooth headset → iPhone.
    /// With Bluetooth voice connections (HFP), the speaker automatically follows the microphone.
    func routeToBluetoothMicIfAvailable() {
        let session = AVAudioSession.sharedInstance()
        guard let inputs = session.availableInputs else { return }
        let current = session.currentRoute.inputs.first

        // 1. The glasses always take priority – also over car, AirPods & co.
        if let glasses = inputs.first(where: Self.isMetaGlasses) {
            if current?.uid != glasses.uid { setPreferred(glasses, in: session) }
            return
        }
        // 2. Otherwise another Bluetooth headset, if one is already active or available
        if let current, Self.isBluetooth(current) { return }
        if let headset = inputs.first(where: { $0.portType == .bluetoothHFP }) ?? inputs.first(where: { $0.portType == .bluetoothLE }) {
            setPreferred(headset, in: session)
            return
        }
        print("[Audio] No glasses and no Bluetooth microphone – using the iPhone")
    }

    private func setPreferred(_ input: AVAudioSessionPortDescription, in session: AVAudioSession) {
        do {
            try session.setPreferredInput(input)
            print("[Audio] Microphone and speaker: \(input.portName)")
        } catch {
            print("[Audio] Switching to \(input.portName) failed: \(error)")
        }
    }

    private static func isBluetooth(_ port: AVAudioSessionPortDescription) -> Bool {
        port.portType == .bluetoothHFP || port.portType == .bluetoothLE
    }

    /// Ray-Ban Meta / Oakley Meta is recognized by the Bluetooth device name
    static func isMetaGlasses(_ port: AVAudioSessionPortDescription) -> Bool {
        guard isBluetooth(port) else { return false }
        let name = port.portName.lowercased()
        return ["ray-ban", "rayban", "ray ban", "meta", "oakley"].contains { name.contains($0) }
    }

    var isBluetoothInputActive: Bool {
        AVAudioSession.sharedInstance().currentRoute.inputs.contains(where: Self.isBluetooth)
    }

    /// For display: what are the microphone and voice currently routed through?
    var currentRouteLabel: String {
        let route = AVAudioSession.sharedInstance().currentRoute
        guard let input = route.inputs.first else { return "–" }
        if Self.isMetaGlasses(input) { return "Glasses (\(input.portName))" }
        return Self.isBluetooth(input) ? input.portName : "iPhone"
    }

    func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification, object: nil
        )
    }

    @objc private func handleRouteChange(notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        // Glasses (back) or route changed externally → take the glasses back
        if reason == .newDeviceAvailable || reason == .override || reason == .routeConfigurationChange {
            routeToBluetoothMicIfAvailable()
        }
    }

    @objc private func handleInterruption(notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            NotificationCenter.default.post(name: .audioInterruptionBegan, object: nil)
        case .ended:
            let optionsRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            if AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume) {
                try? configureForVoiceChat()
                NotificationCenter.default.post(name: .audioInterruptionEnded, object: nil)
            }
        @unknown default:
            break
        }
    }
}

extension Notification.Name {
    static let audioInterruptionBegan = Notification.Name("audioInterruptionBegan")
    static let audioInterruptionEnded = Notification.Name("audioInterruptionEnded")
}

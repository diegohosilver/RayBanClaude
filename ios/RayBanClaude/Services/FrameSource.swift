import Foundation
import Combine

enum FrameSourceType: String, CaseIterable, Identifiable {
    case iPhone = "iPhone camera"
    case rayBan = "Ray-Ban Meta"

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .iPhone: return "iPhone"
        case .rayBan: return "Glasses"
        }
    }

    var icon: String {
        switch self {
        case .iPhone: return "camera.fill"
        case .rayBan: return "eyeglasses"
        }
    }

    /// Value for the `source` field on the server
    var wireName: String {
        switch self {
        case .iPhone: return "iphone"
        case .rayBan: return "rayban"
        }
    }
}

@MainActor
protocol FrameSource: AnyObject {
    var latestFrame: Data? { get }
    var isRunning: Bool { get }
    var sourceType: FrameSourceType { get }
    var connectionStatus: FrameSourceStatus { get }
    func start() throws
    func stop()
    func consumeFrame() -> Data?
    /// A fresh, ideally sharp photo (briefly starts the camera if needed)
    func capturePhoto() async -> Data?
    /// Wake the camera early – e.g. as soon as “What is this …” is recognized
    func prepareCapture()
}

enum FrameSourceStatus: Equatable {
    case disconnected
    case connecting
    case connected
    /// Ready, camera off – only takes photos on demand (glasses)
    case standby
    case error(String)

    var label: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting …"
        case .connected: return "Connected"
        case .standby: return "Ready – camera only on demand"
        case .error(let msg): return msg
        }
    }

    /// Connected or ready for a photo
    var isReady: Bool {
        switch self {
        case .connected, .standby: return true
        default: return false
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

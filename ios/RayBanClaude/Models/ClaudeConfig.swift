import Foundation

/// How the app talks to Claude.
enum ConnectionMode: String, Codable, CaseIterable, Identifiable {
    /// Claude Code + Channel on the PC – free with the Claude subscription, all MCP tools and skills
    case channel
    /// Standalone gateway server on the PC with an Anthropic API key (pay per use)
    case gateway
    /// No PC: the iPhone calls the Claude API directly (your own API key, pay per question)
    case direct

    var id: String { rawValue }

    var label: String {
        switch self {
        case .channel: return "PC: Claude Code (free)"
        case .gateway: return "PC: Gateway (API-Key)"
        case .direct: return "No PC (API key)"
        }
    }

    var usesPC: Bool { self != .direct }
}

struct ClaudeConfig: Codable, Equatable {
    var gatewayHost: String = ""
    /// PC address for when you are away (Tailscale) – the app tries it when the home Wi-Fi is not available
    var remoteHost: String = ""
    var gatewayPort: Int = ClaudeConfig.defaultPort
    var connectionMode: ConnectionMode = .channel
    var videoFrameInterval: TimeInterval = 1.0
    var videoJPEGQuality: Double = 0.85
    var speechPauseThreshold: TimeInterval = 1.5
    var elevenLabsVoiceId: String = "XB0fDUnXU5powFXDhCwa" // Charlotte (multilingual)
    /// Language for speech recognition and voice, e.g. "de-DE"
    var speechLanguage: String = ClaudeConfig.defaultLanguage
    /// Automatically listen again after Claude's reply (hands-free with the glasses)
    var autoListen: Bool = true
    /// Wake word "Hey Claude" / "Claudi" – the app waits hands-free for you
    var wakeWordEnabled: Bool = true
    /// No PC: model for the direct Claude API
    var directModel: String = DirectClaudeClient.defaultModel
    /// PC unreachable → automatically ask directly (only with an API key)
    var directFallback: Bool = true
    /// Web search in direct mode (weather, opening hours …; costs extra per search)
    var webSearchEnabled: Bool = true
    /// Memory: Claude remembers what you tell it about yourself (stored only on this iPhone)
    var memoryEnabled: Bool = true
    /// Pocket mode: listen for "Hey Claude" even when the iPhone is locked (like Meta AI)
    var listenWhenLocked: Bool = true
    /// Don't auto-lock the display while the app is open (uses more battery)
    var keepScreenOn: Bool = false
    /// Glasses gestures: double tap = listen, capture button = "What do you see?" (keeps the session open).
    /// Off by default – experimental until tested on real glasses.
    var glassesGestures: Bool = false

    // Secrets are stored in the Keychain, not in UserDefaults
    var channelToken: String = ""
    var elevenLabsAPIKey: String = ""
    var anthropicAPIKey: String = ""

    /// Direct mode usable? (API key present)
    var hasDirectKey: Bool { anthropicAPIKey.hasPrefix("sk-ant-") && anthropicAPIKey.count >= 20 }

    static let defaultPort = 18790
    static let supportedLanguages: [(code: String, name: String)] = [
        ("de-DE", "Deutsch"), ("de-AT", "Deutsch (Österreich)"), ("de-CH", "Deutsch (Schweiz)"),
        ("en-US", "English (US)"), ("en-GB", "English (UK)"), ("fr-FR", "French"),
        ("es-MX", "Spanish (Mexico)"), ("es-US", "Spanish (US)"), ("es-ES", "Spanish (Spain)"),("it-IT", "Italian"), ("tr-TR", "Turkish"), ("pl-PL", "Polish"),
    ]

    static var defaultLanguage: String {
        let preferred = Locale.preferredLanguages.first ?? "en-US"
        return supportedLanguages.first { preferred.hasPrefix($0.code) }?.code
            ?? supportedLanguages.first { preferred.hasPrefix(String($0.code.prefix(2))) }?.code
            ?? "en-US"
    }

    private enum CodingKeys: String, CodingKey {
        case gatewayHost, remoteHost, gatewayPort, connectionMode, videoFrameInterval, videoJPEGQuality
        case speechPauseThreshold, elevenLabsVoiceId, speechLanguage, autoListen, wakeWordEnabled
        case directModel, directFallback, webSearchEnabled, memoryEnabled, listenWhenLocked, keepScreenOn
        case glassesGestures
    }

    var isConfigured: Bool { baseURL != nil && !channelToken.isEmpty }

    // MARK: - URLs (never force-unwrapped – invalid input must not crash)

    private func url(scheme: String, path: String) -> URL? {
        let host = gatewayHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, (1...65535).contains(gatewayPort) else { return nil }
        var comps = URLComponents()
        comps.scheme = scheme
        comps.host = host
        comps.port = gatewayPort
        comps.path = path
        return comps.url
    }

    var baseURL: URL? { url(scheme: "http", path: "") }
    var wsURL: URL? { url(scheme: "ws", path: "/ws") }
    var chatURL: URL? { url(scheme: "http", path: "/chat") }
    var healthURL: URL? { url(scheme: "http", path: "/health") }
    var uploadURL: URL? { url(scheme: "http", path: "/upload") }
    /// Endpoint that requires a valid token – used to test pairing
    var authCheckURL: URL? {
        url(scheme: "http", path: connectionMode == .channel ? "/api/status" : "/health/details")
    }

    func fileURL(_ path: String) -> URL? {
        guard path.hasPrefix("/files/") else { return nil }
        return url(scheme: "http", path: path)
    }

    /// The same settings, but with a different PC address (Wi-Fi or Tailscale)
    func using(host: String) -> ClaudeConfig {
        guard !host.isEmpty else { return self }
        var copy = self
        copy.gatewayHost = host
        return copy
    }

    /// Is a second address (Tailscale) stored for when you are away?
    var hasRemoteHost: Bool {
        let remote = remoteHost.trimmingCharacters(in: .whitespacesAndNewlines)
        return !remote.isEmpty && remote != gatewayHost.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Saving / Loading

    private static let storageKey = "RayBanClaudeConfig"

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
        KeychainStore.set(channelToken, for: .channelToken)
        KeychainStore.set(elevenLabsAPIKey, for: .elevenLabsAPIKey)
        KeychainStore.set(anthropicAPIKey, for: .anthropicAPIKey)
    }

    static func load() -> ClaudeConfig {
        var config = UserDefaults.standard.data(forKey: storageKey)
            .flatMap { try? JSONDecoder().decode(ClaudeConfig.self, from: $0) } ?? ClaudeConfig()
        config.channelToken = KeychainStore.get(.channelToken)
        config.elevenLabsAPIKey = KeychainStore.get(.elevenLabsAPIKey)
        config.anthropicAPIKey = KeychainStore.get(.anthropicAPIKey)
        return config
    }
}

extension ClaudeConfig {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ClaudeConfig()
        gatewayHost = try c.decodeIfPresent(String.self, forKey: .gatewayHost) ?? defaults.gatewayHost
        remoteHost = try c.decodeIfPresent(String.self, forKey: .remoteHost) ?? defaults.remoteHost
        gatewayPort = try c.decodeIfPresent(Int.self, forKey: .gatewayPort) ?? defaults.gatewayPort
        connectionMode = try c.decodeIfPresent(ConnectionMode.self, forKey: .connectionMode) ?? defaults.connectionMode
        videoFrameInterval = try c.decodeIfPresent(TimeInterval.self, forKey: .videoFrameInterval) ?? defaults.videoFrameInterval
        videoJPEGQuality = try c.decodeIfPresent(Double.self, forKey: .videoJPEGQuality) ?? defaults.videoJPEGQuality
        speechPauseThreshold = try c.decodeIfPresent(TimeInterval.self, forKey: .speechPauseThreshold) ?? defaults.speechPauseThreshold
        elevenLabsVoiceId = try c.decodeIfPresent(String.self, forKey: .elevenLabsVoiceId) ?? defaults.elevenLabsVoiceId
        speechLanguage = try c.decodeIfPresent(String.self, forKey: .speechLanguage) ?? defaults.speechLanguage
        autoListen = try c.decodeIfPresent(Bool.self, forKey: .autoListen) ?? defaults.autoListen
        wakeWordEnabled = try c.decodeIfPresent(Bool.self, forKey: .wakeWordEnabled) ?? defaults.wakeWordEnabled
        directModel = try c.decodeIfPresent(String.self, forKey: .directModel) ?? defaults.directModel
        directFallback = try c.decodeIfPresent(Bool.self, forKey: .directFallback) ?? defaults.directFallback
        webSearchEnabled = try c.decodeIfPresent(Bool.self, forKey: .webSearchEnabled) ?? defaults.webSearchEnabled
        memoryEnabled = try c.decodeIfPresent(Bool.self, forKey: .memoryEnabled) ?? defaults.memoryEnabled
        listenWhenLocked = try c.decodeIfPresent(Bool.self, forKey: .listenWhenLocked) ?? defaults.listenWhenLocked
        keepScreenOn = try c.decodeIfPresent(Bool.self, forKey: .keepScreenOn) ?? defaults.keepScreenOn
        glassesGestures = try c.decodeIfPresent(Bool.self, forKey: .glassesGestures) ?? defaults.glassesGestures
    }
}

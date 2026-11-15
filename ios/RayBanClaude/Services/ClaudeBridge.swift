import Foundation
import Network

/// Connection to the PC:
/// - Channel mode: WebSocket to the Claude Code session (all MCP tools and skills, free with a subscription)
/// - Gateway mode: REST to the standalone gateway server (Anthropic API key)
///
/// The PC can have two addresses: the one on the home Wi-Fi and – for on the go – its Tailscale address.
/// The app tries them in order (without Wi-Fi, only Tailscale) and sticks with the one that responds.
@MainActor
final class ClaudeBridge: NSObject, ObservableObject {
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    @Published private(set) var state: ConnectionState = .disconnected
    /// Connected via the on-the-go address (Tailscale) instead of the home Wi-Fi
    @Published private(set) var isRemote = false
    var isConnected: Bool { state == .connected }

    // MARK: Callbacks to the ViewModel

    struct Reply {
        let id: String
        let text: String
        let audioPath: String?
        let replyTo: String?
        let attachments: [Attachment]
    }

    var onReply: ((Reply) -> Void)?
    var onEdit: ((_ id: String, _ text: String) -> Void)?
    var onAck: ((String) -> Void)?
    var onCaptureRequest: ((_ id: String, _ reason: String?) -> Void)?
    var onPermissionRequest: ((PermissionRequest) -> Void)?
    var onPermissionResolved: ((String) -> Void)?
    var onPhoneAction: ((PhoneAction) -> Void)?
    /// Claude remembered or forgot something (on the PC): op = "add" | "remove"
    var onMemory: ((_ op: String, _ items: [String]) -> Void)?
    var onServerError: ((String) -> Void)?
    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?

    private var config: ClaudeConfig
    private var urlSession: URLSession?
    private var webSocket: URLSessionWebSocketTask?
    private var conversationId: String?
    private var reconnectAttempts = 0
    private var reconnectWork: DispatchWorkItem?
    private var isManualDisconnect = false
    /// Set on 401/429 – then do not reconnect endlessly, leave the message in place
    private var authFailure: String?
    private var pingTimer: Timer?
    private let maxReconnectAttempts = 8

    /// Address currently being connected to or connected with
    private var activeHost = ""
    /// Addresses of the current round not yet tried
    private var hostQueue: [String] = []
    /// Does the iPhone currently have Wi-Fi (or a cable)? Without Wi-Fi the PC at home is only reachable via Tailscale.
    private var onLocalNetwork = true
    private var networkReachable = true
    private let pathMonitor = NWPathMonitor()

    init(config: ClaudeConfig) {
        self.config = config
        super.init()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let local = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
                || path.availableInterfaces.contains { $0.type == .wifi || $0.type == .wiredEthernet }
            let reachable = path.status == .satisfied
            Task { @MainActor [weak self] in self?.networkChanged(local: local, reachable: reachable) }
        }
        pathMonitor.start(queue: .main)
    }

    /// Settings with the address currently in use
    private var activeConfig: ClaudeConfig { config.using(host: activeHost) }

    /// Order of addresses: at home Wi-Fi first, then Tailscale; on mobile data only Tailscale.
    private var candidateHosts: [String] {
        let lan = config.gatewayHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let remote = config.remoteHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard config.hasRemoteHost else { return [lan] }
        return onLocalNetwork ? [lan, remote] : [remote]
    }

    /// Network changed (Wi-Fi ↔ mobile data, Tailscale on): retry a connection that was given up.
    private func networkChanged(local: Bool, reachable: Bool) {
        let changed = local != onLocalNetwork || reachable != networkReachable
        onLocalNetwork = local
        networkReachable = reachable
        guard changed, reachable, !isManualDisconnect, authFailure == nil, config.connectionMode.usesPC else { return }
        // Wi-Fi gone but still connected via the home address → the connection is dead: go straight to Tailscale
        if state == .connected, !isRemote, !local, config.hasRemoteHost, config.connectionMode == .channel {
            closeSocket()
            hostQueue.removeAll()
            state = .connecting
            openWebSocket()
            return
        }
        guard case .failed = state else { return }
        reconnectAttempts = 0
        reconnectWork?.cancel()
        reconnectWork = nil
        hostQueue.removeAll()
        Task { await connect() }
    }

    func updateConfig(_ config: ClaudeConfig) {
        let needsReconnect = config.gatewayHost != self.config.gatewayHost
            || config.remoteHost != self.config.remoteHost
            || config.gatewayPort != self.config.gatewayPort
            || config.channelToken != self.config.channelToken
            || config.connectionMode != self.config.connectionMode
        self.config = config
        if needsReconnect && state != .disconnected { disconnect() }
    }

    // MARK: - Connecting

    func connect() async {
        isManualDisconnect = false
        reconnectAttempts = 0
        hostQueue.removeAll()
        switch config.connectionMode {
        case .channel: openWebSocket()
        case .gateway: await connectGateway()
        case .direct: state = .disconnected // without a PC – no connection needed
        }
    }

    func disconnect() {
        isManualDisconnect = true
        reconnectWork?.cancel()
        reconnectWork = nil
        closeSocket()
        hostQueue.removeAll()
        isRemote = false
        state = .disconnected
        onDisconnected?()
    }

    private func openWebSocket() {
        // New round: all addresses in the current order
        if hostQueue.isEmpty { hostQueue = candidateHosts }
        activeHost = hostQueue.removeFirst()
        guard let wsURL = activeConfig.wsURL else {
            state = .failed("PC address missing – scan the QR code in the dashboard")
            return
        }
        guard !config.channelToken.isEmpty else {
            state = .failed("Token missing – scan the QR code in the dashboard")
            return
        }
        closeSocket()
        authFailure = nil
        state = .connecting
        // Release the old session – previously sessions with their delegate stuck around on every reconnect
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        urlSession = session
        var request = URLRequest(url: wsURL)
        request.setValue("Bearer \(config.channelToken)", forHTTPHeaderField: "Authorization")
        // Keep it short: if the PC is not at this address, the next one is tried right away
        request.timeoutInterval = 6
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 16 * 1024 * 1024
        webSocket = task
        task.resume()
        receive(on: task)
    }

    private func closeSocket() {
        pingTimer?.invalidate()
        pingTimer = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }

    private func connectGateway() async {
        state = .connecting
        var lastError: Error = BridgeError.notConfigured
        for host in candidateHosts {
            activeHost = host
            do {
                try await checkAuthorized()
                isRemote = host != config.gatewayHost
                state = .connected
                onConnected?()
                return
            } catch {
                lastError = error
            }
        }
        isRemote = false
        state = .failed(lastError.localizedDescription)
    }

    // MARK: - Receiving

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, task === self.webSocket else { return } // ignore stale connection
                switch result {
                case .success(.string(let text)):
                    self.handle(text)
                    self.receive(on: task)
                case .success(.data(let data)):
                    self.handle(String(decoding: data, as: UTF8.self))
                    self.receive(on: task)
                case .success:
                    self.receive(on: task)
                case .failure(let error):
                    print("[Connection] Receive ended: \(error.localizedDescription)")
                    self.connectionLost()
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "status":
            if json["status"] as? String == "connected" {
                isRemote = activeHost != config.gatewayHost.trimmingCharacters(in: .whitespacesAndNewlines)
                hostQueue.removeAll()
                state = .connected
                reconnectAttempts = 0
                startPingTimer()
                onConnected?()
            }
        case "ack":
            if let id = json["id"] as? String { onAck?(id) }
        case "reply":
            let files = (json["files"] as? [[String: Any]] ?? []).compactMap { f -> Attachment? in
                guard let name = f["name"] as? String, let url = f["url"] as? String else { return nil }
                return Attachment(name: name, path: url)
            }
            onReply?(Reply(
                id: json["id"] as? String ?? UUID().uuidString,
                text: json["text"] as? String ?? "",
                audioPath: json["audio_url"] as? String,
                replyTo: json["reply_to"] as? String,
                attachments: files
            ))
        case "edit":
            if let id = json["id"] as? String, let newText = json["text"] as? String { onEdit?(id, newText) }
        case "capture_request":
            if let id = json["id"] as? String { onCaptureRequest?(id, json["reason"] as? String) }
        case "permission_request":
            if let id = json["request_id"] as? String {
                onPermissionRequest?(PermissionRequest(
                    id: id,
                    toolName: json["tool_name"] as? String ?? "Tool",
                    description: json["description"] as? String ?? "",
                    inputPreview: json["input_preview"] as? String ?? ""
                ))
            }
        case "permission_resolved":
            if let id = json["request_id"] as? String { onPermissionResolved?(id) }
        case "phone_action":
            guard let id = json["id"] as? String,
                  let kind = (json["action"] as? String).flatMap(PhoneAction.Kind.init(rawValue:)) else { return }
            onPhoneAction?(PhoneAction(
                id: id, kind: kind,
                durationSeconds: json["duration_seconds"] as? Int,
                time: json["time"] as? String,
                date: json["date"] as? String,
                label: json["label"] as? String,
                contact: json["contact"] as? String,
                number: json["number"] as? String,
                text: json["text"] as? String,
                destination: json["destination"] as? String
            ))
        case "memory":
            guard let op = json["op"] as? String, let items = json["items"] as? [String] else { return }
            onMemory?(op, items)
        case "error":
            onServerError?(json["message"] as? String ?? "Unknown server error")
        default:
            break
        }
    }

    // MARK: - Reconnecting

    private func connectionLost() {
        let wasConnecting = state == .connecting
        closeSocket()
        if let authFailure {
            state = .failed(authFailure)
            return
        }
        guard state != .disconnected else { return }
        // PC not reachable at this address → immediately try the next one (e.g. Tailscale)
        if wasConnecting, !hostQueue.isEmpty, !isManualDisconnect {
            openWebSocket()
            return
        }
        hostQueue.removeAll()
        isRemote = false
        state = .failed(wasConnecting ? unreachableMessage : "Connection to the PC lost")
        onDisconnected?()
        scheduleReconnect()
    }

    private var unreachableMessage: String {
        if config.hasRemoteHost { return "PC not reachable – is it running, and is Tailscale on on the iPhone?" }
        return onLocalNetwork
            ? "PC not reachable – is Claude Code running with the channel?"
            : "On the go without Tailscale the PC is not reachable – see Settings"
    }

    /// Exponential backoff; the counter used to be reset on every attempt
    /// and two paths triggered reconnects in parallel.
    private func scheduleReconnect() {
        guard !isManualDisconnect, authFailure == nil, config.connectionMode == .channel, reconnectWork == nil else { return }
        guard reconnectAttempts < maxReconnectAttempts else {
            state = .failed(unreachableMessage) // A network change starts a new attempt
            return
        }
        reconnectAttempts += 1
        let delay = min(pow(2.0, Double(reconnectAttempts - 1)), 30.0)
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.reconnectWork = nil
                guard !self.isManualDisconnect, self.authFailure == nil else { return }
                self.openWebSocket()
            }
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func startPingTimer() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let socket = self?.webSocket else { return }
                socket.sendPing { error in
                    guard let error else { return }
                    print("[Connection] Ping failed: \(error.localizedDescription)")
                    // Don't leave a dead connection standing (e.g. tunnel gone)
                    Task { @MainActor [weak self] in
                        guard let self, socket === self.webSocket else { return }
                        self.connectionLost()
                    }
                }
            }
        }
    }

    // MARK: - Sending (channel)

    struct Outgoing {
        let id: String
        let text: String
        let source: FrameSourceType
        let mode: VisionMode
        var image: Data?
        var inReplyTo: String?
    }

    /// Sends over the WebSocket; large images via HTTP upload (avoids Base64 bloat).
    func send(_ message: Outgoing) async throws {
        guard state == .connected else { throw BridgeError.notConnected }
        if let image = message.image, image.count > 100_000 {
            do {
                try await upload(message, image: image)
                return
            } catch {
                print("[Connection] Upload failed, sending via WebSocket: \(error.localizedDescription)")
            }
        }
        var payload: [String: Any] = [
            "type": "message",
            "id": message.id,
            "text": message.text,
            "source": message.source.wireName,
            "mode": message.mode.name,
            "mode_prompt": message.mode.systemPrompt,
        ]
        if let image = message.image { payload["image"] = image.base64EncodedString() }
        if let reply = message.inReplyTo { payload["in_reply_to"] = reply }
        try await sendJSON(payload)
    }

    /// Report the result of a phone action back to Claude
    func sendActionResult(id: String, result: ActionResult) async throws {
        try await sendJSON(["type": "action_result", "id": id, "ok": result.ok, "message": result.message])
    }

    func sendPermission(requestId: String, allow: Bool) async throws {
        try await sendJSON(["type": "permission", "request_id": requestId, "behavior": allow ? "allow" : "deny"])
    }

    /// Memory list to the PC – Claude gets it with the next message (only in the PC's memory)
    func sendMemory(_ items: [String], enabled: Bool) async throws {
        guard state == .connected, config.connectionMode == .channel else { return }
        try await sendJSON(["type": "memory_sync", "items": enabled ? items : [], "enabled": enabled])
    }

    private func sendJSON(_ payload: [String: Any]) async throws {
        guard let socket = webSocket else { throw BridgeError.notConnected }
        let data = try JSONSerialization.data(withJSONObject: payload)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func upload(_ message: Outgoing, image: Data) async throws {
        guard let url = activeConfig.uploadURL else { throw BridgeError.notConfigured }
        var request = authorizedRequest(url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        let boundary = "RayBanClaude-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var fields: [(String, String)] = [
            ("id", message.id), ("text", message.text), ("source", message.source.wireName),
            ("mode", message.mode.name), ("mode_prompt", message.mode.systemPrompt),
        ]
        if let reply = message.inReplyTo { fields.append(("in_reply_to", reply)) }

        var body = Data()
        for (key, value) in fields {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"frame.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
        body.append(image)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let (_, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // The server responds with 202 (previously only 204 was accepted)
        guard (200...299).contains(status) else { throw BridgeError.http(status) }
    }

    // MARK: - Gateway mode (REST)

    func chatREST(text: String, images: [Data]) async throws -> ChatResponse {
        guard let url = activeConfig.chatURL else { throw BridgeError.notConfigured }
        var request = authorizedRequest(url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try JSONEncoder().encode(ChatRequest(
            text: text, images: images.map { $0.base64EncodedString() }, conversation_id: conversationId
        ))
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw BridgeError.http(status) }
        let chat = try JSONDecoder().decode(ChatResponse.self, from: data)
        conversationId = chat.conversation_id
        return chat
    }

    func resetConversation() {
        conversationId = nil
    }

    // MARK: - Helpers

    /// Request with token – as Bearer for the channel, additionally as X-Gateway-Key for the gateway.
    func authorizedRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(config.channelToken)", forHTTPHeaderField: "Authorization")
        request.setValue(config.channelToken, forHTTPHeaderField: "X-Gateway-Key")
        return request
    }

    func fileRequest(_ path: String) -> URLRequest? {
        activeConfig.fileURL(path).map(authorizedRequest)
    }

    /// Checks reachability AND token (the public /health endpoint alone is not enough for that).
    func checkAuthorized() async throws {
        guard let url = activeConfig.authCheckURL else { throw BridgeError.notConfigured }
        var request = authorizedRequest(url)
        request.timeoutInterval = 8
        let (_, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw BridgeError.http(status) }
    }
}

// MARK: - WebSocket delegate

extension ClaudeBridge: URLSessionWebSocketDelegate {
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Task { @MainActor [weak self] in
            guard let self, webSocketTask === self.webSocket else { return }
            self.connectionLost()
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let response = task.response as? HTTPURLResponse, response.statusCode == 401 || response.statusCode == 429 else { return }
        let status = response.statusCode
        Task { @MainActor [weak self] in
            guard let self else { return }
            let message = BridgeError.http(status).localizedDescription
            self.authFailure = message // wrong token: don't retry endlessly
            self.reconnectWork?.cancel()
            self.reconnectWork = nil
            self.state = .failed(message)
        }
    }
}

enum BridgeError: LocalizedError {
    case notConnected
    case notConfigured
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to the PC"
        case .notConfigured: return "PC address missing – scan the QR code in the dashboard"
        case .http(401): return "Wrong token – rescan the QR code in the dashboard"
        case .http(429): return "Too many failed attempts – wait 15 minutes"
        case .http(503): return "Claude is currently overloaded – try again in a moment"
        case .http(let code): return "PC responded with error \(code)"
        }
    }
}

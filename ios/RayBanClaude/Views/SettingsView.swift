import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: SessionViewModel
    @ObservedObject var rayBanManager: RayBanManager
    @ObservedObject var modeManager: ModeManager
    @Environment(\.dismiss) private var dismiss

    @State private var portText = ""
    @State private var testResult: (ok: Bool, text: String)?
    @State private var isTesting = false
    @State private var showRayBanInstructions = false
    @State private var showAddCustomMode = false

    private let accent = Color.hudCyan

    var body: some View {
        NavigationStack {
            List {
                Group {
                    connectionSection
                    directSection
                    memorySection
                    modesSection
                    cameraSection
                    rayBanSection
                    voiceSection
                    aboutSection
                }
                .hudSection()
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .hudList()
            .sheet(isPresented: $showRayBanInstructions) { RayBanInstructionsView() }
            .sheet(isPresented: $showAddCustomMode) { AddCustomModeView(modeManager: modeManager) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(viewModel.isConnected ? "Reconnect" : "Connect") {
                        Task { await viewModel.connect() }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear { portText = String(viewModel.config.gatewayPort) }
        }
    }

    // MARK: - Connection

    private var connectionSection: some View {
        Section {
            HStack(spacing: 14) {
                let statusColor = viewModel.isConnected ? Color.hudOK : Color.hudBad
                Image(systemName: viewModel.isConnected ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(statusColor)
                    .hudGlow(statusColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.isConnected ? "Connected" : "Not connected")
                        .font(.hudDisplay(15))
                        .textCase(.uppercase)
                        .foregroundStyle(Color.hudInk)
                    Text(connectionDetail)
                        .font(.caption).foregroundStyle(Color.hudMuted)
                }
            }
            .padding(.vertical, 4)

            Picker("Connection type", selection: $viewModel.config.connectionMode) {
                ForEach(ConnectionMode.allCases) { Text($0.label).tag($0) }
            }

            if viewModel.config.connectionMode.usesPC {
                LabeledContent("PC address") {
                    TextField("192.168.178.20", text: $viewModel.config.gatewayHost)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
                LabeledContent("Away (Tailscale)") {
                    TextField("100.x.y.z – optional", text: $viewModel.config.remoteHost)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
                LabeledContent("Port") {
                    // Separate text state: the field used to jump straight back to 18790 when deleting
                    TextField("18790", text: $portText)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numberPad)
                        .onChange(of: portText) { _, text in
                            if let port = Int(text), (1024...65535).contains(port) { viewModel.config.gatewayPort = port }
                        }
                }
                LabeledContent("Token") {
                    SecureField("from the dashboard", text: $viewModel.config.channelToken)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Button {
                    testConnection()
                } label: {
                    HStack {
                        Label("Test connection", systemImage: "bolt.horizontal.circle")
                        Spacer()
                        if isTesting {
                            ProgressView()
                        } else if let testResult {
                            Text(testResult.text).font(.caption).foregroundStyle(testResult.ok ? Color.hudOK : Color.hudBad)
                        }
                    }
                }
            }
        } header: {
            HUDLabel("Connection")
        } footer: {
            Text(connectionFooter)
        }
    }

    private var connectionDetail: String {
        guard viewModel.isConnected else { return "Scan the QR code or enter the details" }
        return viewModel.viaTailscale ? "Away via Tailscale – runs on your Claude subscription" : "PC reachable, token valid"
    }

    private var connectionFooter: String {
        switch viewModel.config.connectionMode {
        case .channel:
            return "Easiest way: double-click start.cmd on the PC and scan the QR code in the dashboard with the iPhone camera. Free with your Claude subscription, all PC tools available. Away from home: install Tailscale (free) on the PC and iPhone and pair again – then the app reaches your PC at home over mobile data too, still on your subscription."
        case .gateway:
            return "Gateway mode: standalone server on the PC with an Anthropic API key (pay per request). The token is shown in the server window at startup."
        case .direct:
            return "No PC: the iPhone asks Claude directly over the internet (mobile data works too). Needs an API key, see below."
        }
    }

    // MARK: - No PC

    private var directSection: some View {
        Section {
            LabeledContent("API key") {
                SecureField("sk-ant-…", text: $viewModel.config.anthropicAPIKey)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            if !viewModel.config.anthropicAPIKey.isEmpty && !viewModel.config.hasDirectKey {
                Label("This does not look like an Anthropic API key (starts with sk-ant-)", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Color.hudWarn)
            }
            Picker("Model", selection: $viewModel.config.directModel) {
                ForEach(DirectClaudeClient.models) { model in
                    VStack(alignment: .leading) {
                        Text(model.name)
                        Text(model.hint).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(model.id)
                }
            }
            if viewModel.config.connectionMode.usesPC {
                Toggle("Automatic when the PC is unreachable", isOn: $viewModel.config.directFallback)
            }
            Toggle("Web search (weather, opening hours …)", isOn: $viewModel.config.webSearchEnabled)
            if let url = URL(string: "https://console.anthropic.com/settings/keys") {
                Link(destination: url) { Label("Create an API key at Anthropic", systemImage: "key") }
            }
        } header: {
            HUDLabel("No PC (on the go)")
        } footer: {
            Text("Costs per question – with Claude Opus 5.5 usually 1–3 cents, Sonnet about half, Haiku a fraction; each web search about 1 cent. Your Claude subscription does not apply here – on the go it only works through your subscription with Tailscale (see above). PC tools (email, files) are not available without the PC – timers, calls, navigation and photos are. The key is stored only in this iPhone's Keychain.")
        }
    }

    // MARK: - Memory

    private var memorySection: some View {
        Section {
            NavigationLink {
                MemoryView(memory: viewModel.memory, enabled: $viewModel.config.memoryEnabled)
            } label: {
                LabeledContent {
                    Text(viewModel.config.memoryEnabled ? "\(viewModel.memory.items.count) entries" : "off")
                } label: {
                    Label("What Claude knows about you", systemImage: "brain.head.profile")
                }
            }
        } header: {
            HUDLabel("Memory")
        } footer: {
            Text("\"Hey Claude, remember …\" – Claude keeps it, with or without the PC. Knowledge from your Claude chats comes in by pasting or directly through the Claude desktop app on the PC (\"Transfer what you know about me to the glasses\").")
        }
    }

    // MARK: - Modes

    private var modesSection: some View {
        Section {
            ForEach(VisionMode.builtInModes) { mode in
                Toggle(isOn: Binding(
                    get: { modeManager.isBuiltInModeVisible(mode.id) },
                    set: { _ in modeManager.toggleBuiltInModeVisibility(id: mode.id) }
                )) {
                    Label { Text(mode.name) } icon: { Image(systemName: mode.icon).foregroundStyle(mode.swiftColor) }
                }
                .disabled(mode.id == VisionMode.general.id)
            }
            ForEach(modeManager.customModes) { mode in
                Label { Text(mode.name) } icon: { Image(systemName: mode.icon).foregroundStyle(mode.swiftColor) }
            }
            .onDelete { indexSet in
                let modes = modeManager.customModes
                indexSet.map { modes[$0].id }.forEach { modeManager.deleteCustomMode(id: $0) }
            }
            Button {
                showAddCustomMode = true
            } label: {
                Label("Create custom mode", systemImage: "plus.circle.fill")
            }
        } header: {
            HUDLabel("Expert modes")
        } footer: {
            Text("Modes give Claude expertise and an answer style. Active mode: \(modeManager.activeMode.name). Swipe left to delete custom modes.")
        }
    }

    // MARK: - Camera

    private var cameraSection: some View {
        Section {
            Picker("Camera", selection: $viewModel.activeFrameSource) {
                ForEach(FrameSourceType.allCases) { Label($0.rawValue, systemImage: $0.icon).tag($0) }
            }
            .pickerStyle(.segmented)

            LabeledContent("Status", value: viewModel.frameSourceStatus.label)

            VStack(alignment: .leading) {
                LabeledContent("Send image to Claude every", value: String(format: "%.1f s", viewModel.config.videoFrameInterval))
                Slider(value: $viewModel.config.videoFrameInterval, in: 0.5...5.0, step: 0.5)
            }
            VStack(alignment: .leading) {
                LabeledContent("JPEG quality", value: "\(Int(viewModel.config.videoJPEGQuality * 100)) %")
                Slider(value: $viewModel.config.videoJPEGQuality, in: 0.3...1.0, step: 0.05)
            }
        } header: {
            HUDLabel("Camera")
        } footer: {
            Text("With every question the current image goes to Claude. Higher quality helps with reading text but uses more data.")
        }
    }

    // MARK: - Glasses

    private var rayBanSection: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: "eyeglasses").font(.system(size: 22)).foregroundStyle(accent).hudGlow(accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(rayBanManager.deviceModel ?? rayBanManager.glassesName).font(.body)
                    if rayBanManager.deviceModel != nil {
                        Text(rayBanManager.glassesName).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let battery = rayBanManager.batteryLevel {
                    Label("\(battery) %", systemImage: batteryIcon(battery)).font(.caption)
                }
            }
            LabeledContent("Registration", value: rayBanManager.registrationLabel)
            LabeledContent("Microphone & voice", value: AudioSessionManager.shared.currentRouteLabel)
            if let open = rayBanManager.hingesOpen {
                LabeledContent("Temples", value: open ? "open" : "closed")
            }
            if let hint = rayBanManager.updateHint {
                Label(hint, systemImage: "arrow.down.circle").font(.caption).foregroundStyle(Color.hudWarn)
            }
            Toggle("Gestures (experimental)", isOn: $viewModel.config.glassesGestures)
            if viewModel.config.glassesGestures, rayBanManager.isRegistered {
                LabeledContent("Gestures", value: rayBanManager.gesturesActive ? "active" : "not active")
                if let hint = rayBanManager.gestureHint {
                    Label(hint, systemImage: "hand.tap").font(.caption).foregroundStyle(Color.hudWarn)
                }
            }
            if rayBanManager.isRegistered {
                Button("Unregister glasses", role: .destructive) {
                    Task { await rayBanManager.unregister() }
                }
            } else {
                Button {
                    Task { await viewModel.connectGlasses() }
                } label: {
                    Label("Connect glasses via Meta AI", systemImage: "link.circle.fill")
                }
            }
            Button {
                showRayBanInstructions = true
            } label: {
                Label("Ray-Ban Meta Gen 2 guide", systemImage: "book.closed.fill")
            }
        } header: {
            HUDLabel("Ray-Ban Meta")
        } footer: {
            Text("Register once: the Meta AI app opens for confirmation. After that the glasses always take priority – camera, microphone and speakers of the Ray-Ban Meta first, the iPhone only as a fallback. The glasses' camera only turns on for a photo when you ask something that needs an image. Gestures (experimental, off by default, not yet tested on real glasses): double-tap the touchpad – Claude listens immediately; short press of the capture button – Claude describes what you see. For this the connection to the glasses stays open.")
        }
    }

    private func batteryIcon(_ level: Int) -> String {
        switch level {
        case ..<15: return "battery.0percent"
        case ..<40: return "battery.25percent"
        case ..<65: return "battery.50percent"
        case ..<90: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    // MARK: - Language

    private var voiceSection: some View {
        Section {
            Picker("Language", selection: $viewModel.config.speechLanguage) {
                ForEach(ClaudeConfig.supportedLanguages, id: \.code) { Text($0.name).tag($0.code) }
            }
            VStack(alignment: .leading) {
                LabeledContent("Send after speech pause", value: String(format: "%.1f s", viewModel.config.speechPauseThreshold))
                Slider(value: $viewModel.config.speechPauseThreshold, in: 0.5...3.0, step: 0.25)
            }
            Toggle("Wake word \"Hey Claude\" / \"Claudi\"", isOn: $viewModel.config.wakeWordEnabled)
            Toggle("Keep listening briefly after the answer", isOn: $viewModel.config.autoListen)
            Toggle("Keep listening when the iPhone is locked", isOn: $viewModel.config.listenWhenLocked)
            Toggle("Keep display on while the app is open", isOn: $viewModel.config.keepScreenOn)

            if viewModel.config.connectionMode != .channel {
                LabeledContent("ElevenLabs key") {
                    SecureField("optional", text: $viewModel.config.elevenLabsAPIKey)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                if !viewModel.config.elevenLabsAPIKey.isEmpty {
                    Picker("Voice", selection: $viewModel.config.elevenLabsVoiceId) {
                        ForEach(ElevenLabsVoice.allVoices) { Text("\($0.name) – \($0.description)").tag($0.id) }
                    }
                }
            }
        } header: {
            HUDLabel("Language & Voice")
        } footer: {
            Text((viewModel.config.wakeWordEnabled
                  ? "With the wake word the app listens hands-free – like Meta AI, even with the iPhone locked in your pocket (the orange microphone dot then appears at the top right). Say \"Hey Claude\" or \"Claudi\" and then your question. Recognition runs only on the iPhone. "
                  : "")
                 + (viewModel.config.connectionMode == .channel
                 ? "The default is the free iPhone voice. You set an ElevenLabs voice in the PC dashboard. Tip: under iOS Settings → Accessibility → Spoken Content → Voices, download a \"Premium\" voice – it sounds much more natural."
                 : "Without an ElevenLabs key the free iPhone voice is used."))
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–") (build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"))")
            if let url = URL(string: "https://github.com/MoinMornhart/RayBanClaude") {
                Link(destination: url) { Label("Project on GitHub", systemImage: "chevron.left.forwardslash.chevron.right") }
            }
        } header: {
            HUDLabel("About RayBan Claude")
        } footer: {
            Text("Open source (MIT), fork of visionclaude. Unofficial project – not affiliated with Meta, Ray-Ban/EssilorLuxottica or Anthropic.")
        }
    }

    private func testConnection() {
        isTesting = true
        testResult = nil
        Task {
            do {
                try await viewModel.bridge.checkAuthorized()
                testResult = (true, "OK – token valid")
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                testResult = (false, error.localizedDescription)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            isTesting = false
        }
    }
}

// MARK: - Custom mode

struct AddCustomModeView: View {
    @ObservedObject var modeManager: ModeManager
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var selectedIcon = "star.fill"
    @State private var selectedColor = "#E87B35"
    @State private var systemPrompt = ""
    @State private var quickActionsText = ""

    private let iconOptions = [
        "star.fill", "heart.fill", "flame.fill", "leaf.fill", "hammer.fill", "paintbrush.fill", "wrench.fill", "scissors",
        "cart.fill", "bag.fill", "house.fill", "car.fill", "cross.case.fill", "stethoscope", "pill.fill", "book.fill",
        "graduationcap.fill", "music.note", "camera.fill", "fork.knife", "cup.and.saucer.fill", "pawprint.fill",
        "map.fill", "lightbulb.fill",
    ]
    private let colorOptions = [
        "#E87B35", "#EF4444", "#F59E0B", "#EAB308", "#22C55E", "#06B6D4",
        "#3B82F6", "#6366F1", "#A855F7", "#EC4899", "#F43F5E", "#84CC16",
    ]

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section(hud: "Name") {
                        TextField("e.g. Chef, Gardener, Tutor", text: $name)
                    }
                    Section(hud: "Icon") {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 8) {
                            ForEach(iconOptions, id: \.self) { icon in
                                let isSelected = selectedIcon == icon
                                Button { selectedIcon = icon } label: {
                                    Image(systemName: icon)
                                        .frame(width: 34, height: 34)
                                        .foregroundStyle(isSelected ? Color.white : Color.hudInk)
                                        .background(RoundedRectangle(cornerRadius: HUDMetrics.radius)
                                            .fill(isSelected ? (Color(hex: selectedColor) ?? .orange) : Color.hudSurface))
                                        .overlay(RoundedRectangle(cornerRadius: HUDMetrics.radius)
                                            .strokeBorder(isSelected ? Color.clear : Color.hudLine, lineWidth: HUDMetrics.hairline))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    Section(hud: "Color") {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 8) {
                            ForEach(colorOptions, id: \.self) { hex in
                                Button { selectedColor = hex } label: {
                                    Circle()
                                        .fill(Color(hex: hex) ?? .orange)
                                        .frame(width: 34, height: 34)
                                        .overlay(Circle().strokeBorder(.white, lineWidth: selectedColor == hex ? 3 : 0))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    Section {
                        TextEditor(text: $systemPrompt)
                            .frame(minHeight: 110)
                            .scrollContentBackground(.hidden)
                    } header: {
                        HUDLabel("Instructions for Claude")
                    } footer: {
                        Text("Describe the field of expertise and answer style, e.g. \"You are a chef. Identify ingredients and suggest quick dishes.\"")
                    }
                    Section {
                        TextField("What is this?, How do I cook this?", text: $quickActionsText)
                    } header: {
                        HUDLabel("Quick commands (comma-separated)")
                    }
                }
                .hudSection()
            }
            .hudList()
            .navigationTitle("New mode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                                  || systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save() {
        let actions = quickActionsText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        modeManager.addCustomMode(
            name: name.trimmingCharacters(in: .whitespaces),
            icon: selectedIcon,
            color: selectedColor,
            prompt: systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
            quickActions: actions
        )
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss()
    }
}

// MARK: - Glasses guide

struct RayBanInstructionsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Group {
                    Section(hud: "Requirements") {
                        Text("Ray-Ban Meta (Gen 2 or Gen 1), Oakley Meta or Meta Ray-Ban Display")
                        Text("Meta AI app (version 290 or later) – glasses paired there")
                        Text("Current glasses firmware (V128 or later) – the Meta AI app prompts for updates")
                        linkRow("Get the Meta AI app", "https://apps.apple.com/app/meta-ai/id1662457680")
                    }
                    Section(hud: "1 · Turn on developer mode") {
                        step(1, "Meta AI app → Settings → your glasses → Developer mode → on")
                        step(2, "Restart the glasses: hold the button for 15 seconds, then press briefly")
                        Text("Developer mode can switch itself off after firmware updates – if so, turn it on again.")
                            .font(.caption).foregroundStyle(Color.hudMuted)
                    }
                    Section(hud: "2 · Connect in RayBan Claude") {
                        step(3, "Settings → \"Connect glasses via Meta AI\"")
                        step(4, "In the Meta AI app tap \"Allow\" – you will land back here")
                        step(5, "Switch to \"Glasses\" at the bottom right and confirm the camera permission")
                    }
                    Section(hud: "Tips for Gen 2") {
                        Text("Unfold the temples – the stream stops when they are closed (it restarts automatically when you open them).")
                        Text("One tap on the touchpad pauses the connection, another resumes it.")
                        Text("With gestures turned on (Settings → Ray-Ban Meta): double-tap the touchpad – Claude listens immediately, no \"Hey Claude\" needed. Short press of the capture button – photo, and Claude tells you what you see.")
                        Text("While gestures are on, tap-and-hold ends the connection (the app reconnects after a few seconds), and swiping on the temple may not change the volume – adjust it on the iPhone or turn the gestures off.")
                        Text("Claude can take a sharp photo with the glasses on its own, e.g. to read text.")
                        Text("Below 10 % battery the glasses refuse the camera stream.")
                    }
                    Section(hud: "Problems?") {
                        Text("No glasses found: switched on, temples open, connected in the Meta AI app?")
                        Text("\"Device not available\": switch the glasses off and on, then connect again.")
                        linkRow("Meta Wearables docs", "https://wearables.developer.meta.com/docs/develop/")
                    }
                }
                .hudSection()
            }
            .hudList()
            .navigationTitle("Set up Ray-Ban Meta")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.fontWeight(.semibold) }
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            HUDStepBadge(number: number)
            Text(text)
        }
    }

    @ViewBuilder
    private func linkRow(_ title: String, _ urlString: String) -> some View {
        if let url = URL(string: urlString) {
            Link(destination: url) { Label(title, systemImage: "arrow.up.right.square") }
        }
    }
}

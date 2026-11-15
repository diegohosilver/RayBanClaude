import SwiftUI
import MWDATCore

/// Whether the Meta SDK is ready – without a successful configuration, Wearables.shared must not be used
@MainActor
enum WearablesSupport {
    static var isConfigured = false
}

@main
struct RayBanClaudeApp: App {
    @StateObject private var viewModel: SessionViewModel

    init() {
        // The DAT SDK must be configured before any access to Wearables.shared
        do {
            try Wearables.configure()
            WearablesSupport.isConfigured = true
        } catch {
            print("[App] Could not configure Meta SDK: \(error)")
        }
        _viewModel = StateObject(wrappedValue: SessionViewModel())
        HUDAppearance.apply()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .preferredColorScheme(.dark)
                .tint(.hudCyan)
                // Pairing QR code (raybanclaude://pair?…) and callbacks from the Meta AI app
                .onOpenURL { url in viewModel.handleIncomingURL(url) }
        }
    }
}

#if canImport(Sparkle)
import SwiftUI
import Combine
import Sparkle

// The website (direct-download) build auto-updates with Sparkle. This whole
// file compiles ONLY when Sparkle is linked — which is the direct target only.
// The Mac App Store target does not link Sparkle, so `canImport(Sparkle)` is
// false there, the "Check for Updates…" menu item disappears, and updates
// route through the App Store instead (Sparkle is not permitted in MAS builds).

/// Publishes the updater's `canCheckForUpdates` so the menu item enables and
/// disables itself correctly (e.g. it greys out while an update is already in
/// flight), across macOS versions.
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

/// The "Check for Updates…" menu command, wired to Sparkle's standard updater.
struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!viewModel.canCheckForUpdates)
    }
}
#endif

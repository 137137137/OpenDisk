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
@MainActor
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

/// The "Check for Updates…" menu command, wired to Sparkle's standard updater.
/// The view model is created once at app level and passed in — building it
/// here would open a fresh KVO subscription (and reset `canCheckForUpdates`)
/// on every menu re-render.
struct CheckForUpdatesView: View {
    @ObservedObject var viewModel: CheckForUpdatesViewModel
    let updater: SPUUpdater

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!viewModel.canCheckForUpdates)
    }
}
#endif

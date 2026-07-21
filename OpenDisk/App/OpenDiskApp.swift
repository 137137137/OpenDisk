import SwiftUI
#if canImport(Sparkle)
import Sparkle
#endif

@main
struct OpenDiskApp: App {
    @AppStorage("fda_show_prompt_at_startup") private var showPromptAtStartup = true
    @State private var hasCheckedFullDiskAccess = false

    #if canImport(Sparkle)
    // Direct-download build only: drives auto-updates + the "Check for
    // Updates…" menu item. Absent from the Mac App Store build.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
    )
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear(perform: checkFullDiskAccessAtStartup)
        }
        .windowToolbarStyle(.unified)
        // The window tracks each screen's content size: compact around the
        // disk picker, expanding when the analysis screen is pushed.
        .windowResizability(.contentSize)
        .commands {
            ToolbarCommands()
            #if canImport(Sparkle)
            // Adds "Check for Updates…" under the app menu (direct build only).
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
            #endif
        }

        Settings {
            SettingsView()
        }
    }

    private func checkFullDiskAccessAtStartup() {
        // The sandboxed App Store build never uses Full Disk Access — it scans
        // folders/volumes the user grants — so there's nothing to prompt for.
        guard !ScanAccess.isSandboxed else { return }
        guard !hasCheckedFullDiskAccess else { return }
        hasCheckedFullDiskAccess = true
        guard showPromptAtStartup else { return }

        // Slightly delayed so the window is on screen before the alert.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.5))
            FullDiskAccess.promptIfNotGranted(
                title: "Full Disk Access Required",
                message: "OpenDisk needs Full Disk Access to analyze all files and folders on your system. You can grant this permission in System Settings > Privacy & Security > Full Disk Access."
            )
        }
    }
}

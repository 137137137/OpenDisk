import SwiftUI
#if canImport(Sparkle)
import Sparkle
#endif

@main
struct OpenDiskApp: App {
    @AppStorage("fda_show_prompt_at_startup") private var showPromptAtStartup = true
    @State private var hasCheckedFullDiskAccess = false

    #if canImport(Sparkle)
    private let updaterController: SPUStandardUpdaterController
    private let checkForUpdatesViewModel: CheckForUpdatesViewModel

    init() {
        let controller = SoftwareUpdater.controller
        updaterController = controller
        checkForUpdatesViewModel = CheckForUpdatesViewModel(updater: controller.updater)
    }
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear(perform: checkFullDiskAccessAtStartup)
        }
        .windowToolbarStyle(.unified)
        .windowResizability(.contentSize)
        .commands {
            ToolbarCommands()
            #if canImport(Sparkle)
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(
                    viewModel: checkForUpdatesViewModel,
                    updater: updaterController.updater
                )
            }
            #endif
        }

        Settings {
            SettingsView()
        }
    }

    private func checkFullDiskAccessAtStartup() {
        guard !ScanAccess.isSandboxed else { return }
        guard !hasCheckedFullDiskAccess else { return }
        hasCheckedFullDiskAccess = true

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.5))
            #if canImport(Sparkle)
            if MoveToApplications.promptIfNeeded() { return }
            #endif
            guard showPromptAtStartup else { return }
            FullDiskAccess.promptIfNotGranted(
                title: "Full Disk Access Required",
                message: "OpenDisk needs Full Disk Access to analyze all files and folders on your system. You can grant this permission in System Settings > Privacy & Security > Full Disk Access."
            )
        }
    }
}

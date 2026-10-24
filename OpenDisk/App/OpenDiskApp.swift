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
        .windowResizability(.contentMinSize)
        .commands {
            ToolbarCommands()
            TextSizeCommands()
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

private struct TextSizeCommands: Commands {
    @AppStorage(ListScale.defaultsKey) private var level = ListScale.defaultLevel

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Divider()
            Button("Make Text Bigger") { level = ListScale(level: level + 1).level }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(level >= ListScale.fontSizes.count - 1)
            Button("Make Text Smaller") { level = ListScale(level: level - 1).level }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(level <= 0)
            Button("Actual Size") { level = ListScale.defaultLevel }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(level == ListScale.defaultLevel)
        }
    }
}

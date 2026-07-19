import SwiftUI

@main
struct DiskManagerApp: App {
    @AppStorage("fda_show_prompt_at_startup") private var showPromptAtStartup = true
    @State private var hasCheckedFullDiskAccess = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 800, minHeight: 600)
                .onAppear(perform: checkFullDiskAccessAtStartup)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1000, height: 700)
        .commands {
            ToolbarCommands()
        }

        Settings {
            SettingsView()
        }
    }

    private func checkFullDiskAccessAtStartup() {
        guard !hasCheckedFullDiskAccess else { return }
        hasCheckedFullDiskAccess = true
        guard showPromptAtStartup else { return }

        // Slightly delayed so the window is on screen before the alert.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            FullDiskAccess.promptIfNotGranted(
                title: "Full Disk Access Required",
                message: "Disk Manager needs Full Disk Access to analyze all files and folders on your system. You can grant this permission in System Settings > Privacy & Security > Full Disk Access."
            )
        }
    }
}

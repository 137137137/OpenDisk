import SwiftUI

@main
struct DiskManagerApp: App {
    @AppStorage("fda_show_prompt_at_startup") private var showPromptAtStartup = true
    @State private var hasCheckedFullDiskAccess = false

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

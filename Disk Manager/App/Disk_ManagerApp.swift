//
//  Disk_ManagerApp.swift
//  Disk Manager
//
//  Created by 137137137 on 9/2/25.
//

import SwiftUI

@main
struct Disk_ManagerApp: App {
    @AppStorage("fda_show_prompt_at_startup") private var showPromptAtStartup: Bool = true
    @State private var hasCheckedFDA = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 800, minHeight: 600)
                .onAppear {
                    configureWindowForLiquidGlass()
                    checkFullDiskAccessAtStartup()
                }
        }
        .windowToolbarStyle(.unified)
        .windowStyle(.automatic)
        .defaultSize(width: 1000, height: 700)
        .commands {
            SidebarCommands()
            ToolbarCommands()
        }

        // Native Settings window (⌘,)
        Settings {
            SettingsView()
        }
    }

    /// Configures the window with iOS 26 Liquid Glass optimizations
    private func configureWindowForLiquidGlass() {
        DispatchQueue.main.async {
            guard let window = NSApplication.shared.windows.first else { return }

            // Enable full-size content view for edge-to-edge glass effect
            window.styleMask.insert(.fullSizeContentView)

            // Set minimum viable size for glass effect visibility
            window.minSize = NSSize(width: 800, height: 600)
        }
    }

    private func checkFullDiskAccessAtStartup() {
        guard !hasCheckedFDA else { return }
        hasCheckedFDA = true

        // Only check if user hasn't disabled the prompt
        guard showPromptAtStartup else { return }

        // Check Full Disk Access status and prompt if needed
        // Delayed to allow window glass effects to render first
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            FullDiskAccess.promptIfNotGranted(
                title: "Full Disk Access Required",
                message: "Disk Manager needs Full Disk Access to analyze all files and folders on your system. This ensures accurate disk usage calculations and complete visibility of your storage.\n\nYou can grant this permission in System Settings > Privacy & Security > Full Disk Access.",
                settingsButtonTitle: "Open Settings",
                skipButtonTitle: "Later",
                skipHandler: {
                    // User chose to skip for now
                    print("User skipped Full Disk Access setup")
                },
                canBeSuppressed: true,
                icon: NSApp.applicationIconImage
            )
        }
    }
}

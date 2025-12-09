//
//  SetDefaultsGuideView.swift
//  Disk Manager
//
//  Created by 137137137 on 9/4/25.
//

import SwiftUI
import AppKit

struct SetDefaultsGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Set New Default View Settings")
                        .font(.title)
                        .fontWeight(.bold)

                    Text("Your folder view settings have been reset. Follow these steps to set new defaults.")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(24)
            .background(.bar)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Step 1
                    stepView(number: 1, title: "Open Finder") {
                        HStack(spacing: 12) {
                            Button("Open Finder & Navigate") {
                                openFinderAndNavigateToDocuments()
                            }

                            Text("Opens Finder to your Documents folder")
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Step 2
                    stepView(number: 2, title: "Navigate to a Folder") {
                        Text("Go to any folder that you want to use as a template for your default settings.")
                            .foregroundStyle(.secondary)
                    }

                    // Step 3
                    stepView(number: 3, title: "Customize the View") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Set up the folder exactly how you want all folders to look:")
                                .foregroundStyle(.secondary)
                            Text("• Choose view type: List, Icon, Column, or Gallery")
                            Text("• Adjust column widths and sort order")
                            Text("• Set icon size and arrangement")
                            Text("• Configure sidebar and toolbar visibility")
                        }
                        .font(.callout)
                    }

                    // Step 4
                    stepView(number: 4, title: "Set as Default") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 12) {
                                Button("Open View Options") {
                                    openViewOptionsPanel()
                                }

                                Text("Opens the View Options panel (⌘J)")
                                    .foregroundStyle(.secondary)
                            }

                            Text("Then click **\"Use as Defaults\"** at the bottom of the panel")
                        }
                    }

                    // Success message
                    GroupBox {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("All Done!")
                                    .fontWeight(.semibold)

                                Text("All new folders will now use your default settings.")
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.title2)
                        }
                    }
                }
                .padding(24)
            }
        }
        .frame(width: 550, height: 480)
    }

    @ViewBuilder
    private func stepView(number: Int, title: String, @ViewBuilder content: () -> some View) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: "\(number).circle.fill")
                    .font(.headline)

                content()
            }
        }
    }

    // MARK: - AppleScript Functions
    private func openFinderAndNavigateToDocuments() {
        let script = """
        tell application "Finder"
            activate
            set documentsFolder to (path to documents folder)
            open documentsFolder
            set the current view of the front Finder window to list view
        end tell
        """

        runAppleScript(script)
    }

    private func openViewOptionsPanel() {
        let script = """
        tell application "Finder"
            activate
            tell application "System Events"
                tell process "Finder"
                    key code 38 using command down -- ⌘J to open View Options
                end tell
            end tell
        end tell
        """

        runAppleScript(script)
    }

    private func runAppleScript(_ source: String) {
        let script = NSAppleScript(source: source)
        var error: NSDictionary?
        script?.executeAndReturnError(&error)

        if let error = error {
            print("AppleScript error: \(error)")
        }
    }
}

#Preview {
    SetDefaultsGuideView()
}

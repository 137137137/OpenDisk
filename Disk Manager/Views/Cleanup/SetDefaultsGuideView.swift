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

                    Text("Your folder view settings have been reset. Follow these steps to set new defaults for all folders.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(24)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Step 1
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: "1.circle.fill")
                                    .font(.title2)

                                Text("Open Finder")
                                    .font(.headline)
                                    .fontWeight(.semibold)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 12) {
                                    Button("Open Finder & Navigate") {
                                        openFinderAndNavigateToDocuments()
                                    }
                                    .buttonStyle(.bordered)

                                    Text("This will open Finder and navigate to your Documents folder")
                                        .font(.body)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 8)
                    }

                    // Step 2
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: "2.circle.fill")
                                    .font(.title2)

                                Text("Navigate to a Folder")
                                    .font(.headline)
                                    .fontWeight(.semibold)
                            }

                            Text("Go to any folder (like Documents or Desktop) that you want to use as a template for your default settings.")
                                .font(.body)
                        }
                        .padding(.vertical, 8)
                    }

                    // Step 3
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: "3.circle.fill")
                                    .font(.title2)

                                Text("Customize the View")
                                    .font(.headline)
                                    .fontWeight(.semibold)
                            }

                            Text("Set up the folder exactly how you want all folders to look:")
                                .font(.body)

                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    Text("•")
                                        .foregroundStyle(.secondary)
                                    Text("Choose view type: List, Icon, Column, or Gallery")
                                }
                                HStack(spacing: 8) {
                                    Text("•")
                                        .foregroundStyle(.secondary)
                                    Text("Adjust column widths and sort order")
                                }
                                HStack(spacing: 8) {
                                    Text("•")
                                        .foregroundStyle(.secondary)
                                    Text("Set icon size and arrangement")
                                }
                                HStack(spacing: 8) {
                                    Text("•")
                                        .foregroundStyle(.secondary)
                                    Text("Configure sidebar and toolbar visibility")
                                }
                            }
                            .padding(.leading, 16)
                        }
                        .padding(.vertical, 8)
                    }

                    // Step 4
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: "4.circle.fill")
                                    .font(.title2)

                                Text("Set as Default")
                                    .font(.headline)
                                    .fontWeight(.semibold)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Once your folder looks perfect:")
                                    .font(.body)

                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 12) {
                                        Button("Open View Options") {
                                            openViewOptionsPanel()
                                        }
                                        .buttonStyle(.bordered)

                                        Text("This will open the View Options panel (⌘J)")
                                            .font(.body)
                                            .foregroundStyle(.secondary)
                                    }

                                    HStack {
                                        Text("Then click")
                                        Text("\"Use as Defaults\"")
                                            .fontWeight(.semibold)
                                        Text("at the bottom of the panel")
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 8)
                    }

                    // Final note
                    GroupBox {
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.green)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("All Done!")
                                    .font(.headline)
                                    .fontWeight(.semibold)

                                Text("All new folders and folders without .DS_Store files will now use your default settings.")
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()
                        }
                        .padding(.vertical, 8)
                    }
                }
                .padding(24)
            }
        }
        .frame(width: 600, height: 500)
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

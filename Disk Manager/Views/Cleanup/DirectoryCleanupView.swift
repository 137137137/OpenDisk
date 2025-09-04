//
//  DirectoryCleanupView.swift
//  Disk Manager
//
//  Created by 137137137 on 9/4/25.
//

import SwiftUI

struct DirectoryCleanupView: View {
    @StateObject private var cleanupManager = DirectoryCleanupManager()
    @StateObject private var diskUtility = DiskSpaceUtility()
    @State private var showingConfirmation = false
    @State private var showingDefaultsGuide = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Main content area
            ScrollView {
                VStack(spacing: 0) {
                    // Header section with native spacing
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Reset Finder View Settings")
                                .font(.largeTitle)
                                .fontWeight(.bold)
                            
                            Text("Remove .DS_Store files to reset all folder view preferences to their default settings.")
                                .font(.body)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        
                        // Target location info
                        if let computerDevice = diskUtility.devices.first(where: { $0.name == "Computer" }) {
                            GroupBox {
                                HStack(spacing: 12) {
                                    Image(systemName: "internaldrive")
                                        .font(.title2)
                                        .foregroundColor(.blue)
                                        .frame(width: 32, height: 32)
                                    
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Target Location")
                                            .font(.headline)
                                            .fontWeight(.medium)
                                        
                                        Text("Computer (Root Directory)")
                                            .font(.body)
                                            .foregroundColor(.primary)
                                        
                                        Text("Total Used Space: \(computerDevice.formattedUsedStorage)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    
                                    Spacer()
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                    .padding(.bottom, 20)
                    
                    // Main content card
                    VStack(spacing: 20) {
                        // .DS_Store explanation
                        GroupBox {
                            VStack(alignment: .leading, spacing: 16) {
                                HStack(spacing: 12) {
                                    Image(systemName: "folder.badge.gearshape")
                                        .font(.largeTitle)
                                        .foregroundColor(.accentColor)
                                        .frame(width: 40, height: 40)
                                    
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(".DS_Store Files")
                                            .font(.title2)
                                            .fontWeight(.semibold)
                                        
                                        Text("Desktop Services Store")
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                    }
                                    
                                    Spacer()
                                }
                                
                                Text("These hidden files store folder view preferences including:")
                                    .font(.body)
                                    .foregroundColor(.primary)
                                
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 8) {
                                        Text("•")
                                            .foregroundColor(.secondary)
                                        Text("Icon positions and arrangement")
                                            .font(.body)
                                    }
                                    HStack(spacing: 8) {
                                        Text("•")
                                            .foregroundColor(.secondary)
                                        Text("Sort order and view type (list, icon, column)")
                                            .font(.body)
                                    }
                                    HStack(spacing: 8) {
                                        Text("•")
                                            .foregroundColor(.secondary)
                                        Text("Column widths and window size")
                                            .font(.body)
                                    }
                                    HStack(spacing: 8) {
                                        Text("•")
                                            .foregroundColor(.secondary)
                                        Text("Background images and colors")
                                            .font(.body)
                                    }
                                }
                                .padding(.leading, 16)
                                
                                if cleanupManager.hasScanned {
                                    Divider()
                                        .padding(.vertical, 4)
                                    
                                    HStack {
                                        Image(systemName: "magnifyingglass")
                                            .foregroundColor(.secondary)
                                        
                                        Text("Scan Results:")
                                            .font(.headline)
                                            .fontWeight(.medium)
                                        
                                        Spacer()
                                        
                                        Text("\(cleanupManager.scanResults.dsStoreCount)")
                                            .font(.title2)
                                            .fontWeight(.bold)
                                            .foregroundColor(cleanupManager.scanResults.dsStoreCount > 0 ? .accentColor : .secondary)
                                        
                                        Text("files found")
                                            .font(.body)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            .padding(.vertical, 8)
                        }
                        
                        // Progress section
                        if cleanupManager.isScanning || cleanupManager.isCleaning {
                            GroupBox {
                                VStack(spacing: 12) {
                                    if cleanupManager.isScanning && cleanupManager.totalBytes > 0 {
                                        VStack(spacing: 8) {
                                            HStack {
                                                Text(cleanupManager.progressMessage)
                                                    .font(.body)
                                                    .fontWeight(.medium)
                                                
                                                Spacer()
                                                
                                                Text("\(cleanupManager.formattedScannedBytes) / \(cleanupManager.formattedTotalBytes)")
                                                    .font(.body)
                                                    .foregroundColor(.secondary)
                                                    .monospacedDigit()
                                            }
                                            
                                            ProgressView(value: cleanupManager.progressPercentage, total: 100.0)
                                                .scaleEffect(y: 1.2)
                                        }
                                    } else {
                                        HStack {
                                            ProgressView()
                                                .scaleEffect(0.8)
                                            
                                            Text(cleanupManager.progressMessage)
                                                .font(.body)
                                                .fontWeight(.medium)
                                            
                                            Spacer()
                                        }
                                    }
                                }
                                .padding(.vertical, 8)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
            }
            
            // Bottom toolbar
            VStack(spacing: 0) {
                Divider()
                
                HStack(spacing: 16) {
                    Button("Scan for .DS_Store Files") {
                        if let computerDevice = diskUtility.devices.first(where: { $0.name == "Computer" }) {
                            Task {
                                await cleanupManager.scanDirectory("/", totalUsedSpace: Int64(computerDevice.usedStorage))
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(cleanupManager.isScanning || cleanupManager.isCleaning)
                    
                    Spacer()
                    
                    if cleanupManager.hasScanned && cleanupManager.scanResults.dsStoreCount > 0 {
                        Text("\(cleanupManager.scanResults.dsStoreCount) files ready to remove")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    
                    Button("Reset All View Settings") {
                        if let computerDevice = diskUtility.devices.first(where: { $0.name == "Computer" }) {
                            Task {
                                await cleanupManager.performCleanup("/", totalUsedSpace: Int64(computerDevice.usedStorage))
                                // Show guide after cleanup completes
                                showingDefaultsGuide = true
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!cleanupManager.hasScanned || cleanupManager.isScanning || cleanupManager.isCleaning || cleanupManager.totalSelectedItems == 0)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(.regularMaterial, in: Rectangle())
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .sheet(isPresented: $showingDefaultsGuide) {
            SetDefaultsGuideView()
        }
    }
}

struct CleanupOptionCard: View {
    let title: String
    let description: String
    let icon: String
    let isEnabled: Bool
    let foundCount: Int
    let isWarning: Bool
    let warningText: String?
    let onToggle: () -> Void
    
    init(title: String, description: String, icon: String, isEnabled: Bool, foundCount: Int, isWarning: Bool = false, warningText: String? = nil, onToggle: @escaping () -> Void) {
        self.title = title
        self.description = description
        self.icon = icon
        self.isEnabled = isEnabled
        self.foundCount = foundCount
        self.isWarning = isWarning
        self.warningText = warningText
        self.onToggle = onToggle
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 12) {
                    Image(systemName: icon)
                        .font(.title2)
                        .foregroundColor(isWarning ? .orange : .blue)
                        .frame(width: 24)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.headline)
                        
                        Text(description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    if foundCount > 0 {
                        Text("\(foundCount) found")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Toggle("", isOn: Binding(
                        get: { isEnabled },
                        set: { _ in onToggle() }
                    ))
                    .toggleStyle(SwitchToggleStyle())
                }
            }
            
            if isWarning, let warningText = warningText {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.caption)
                    
                    Text(warningText)
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                .padding(.horizontal, 36)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        )
    }
}

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
                        .foregroundColor(.secondary)
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
                                    .foregroundColor(.accentColor)
                                
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
                                        .foregroundColor(.secondary)
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
                                    .foregroundColor(.accentColor)
                                
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
                                    .foregroundColor(.accentColor)
                                
                                Text("Customize the View")
                                    .font(.headline)
                                    .fontWeight(.semibold)
                            }
                            
                            Text("Set up the folder exactly how you want all folders to look:")
                                .font(.body)
                            
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    Text("•")
                                        .foregroundColor(.secondary)
                                    Text("Choose view type: List, Icon, Column, or Gallery")
                                }
                                HStack(spacing: 8) {
                                    Text("•")
                                        .foregroundColor(.secondary)
                                    Text("Adjust column widths and sort order")
                                }
                                HStack(spacing: 8) {
                                    Text("•")
                                        .foregroundColor(.secondary)
                                    Text("Set icon size and arrangement")
                                }
                                HStack(spacing: 8) {
                                    Text("•")
                                        .foregroundColor(.secondary)
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
                                    .foregroundColor(.accentColor)
                                
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
                                            .foregroundColor(.secondary)
                                    }
                                    
                                    HStack {
                                        Text("Then click")
                                        Text("\"Use as Defaults\"")
                                            .fontWeight(.semibold)
                                            .foregroundColor(.accentColor)
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
                                .foregroundColor(.green)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("All Done!")
                                    .font(.headline)
                                    .fontWeight(.semibold)
                                
                                Text("All new folders and folders without .DS_Store files will now use your default settings.")
                                    .font(.body)
                                    .foregroundColor(.secondary)
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
        .background(Color(NSColor.windowBackgroundColor))
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
    DirectoryCleanupView()
}
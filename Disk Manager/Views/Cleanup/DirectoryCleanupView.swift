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
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Reset Finder View Settings")
                            .font(.title2)
                            .fontWeight(.semibold)
                        
                        Text("Remove .DS_Store files to reset all folder view preferences to default")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                }
                
                // Show root path info like analysis tab
                if let computerDevice = diskUtility.devices.first(where: { $0.name == "Computer" }) {
                    HStack {
                        Image(systemName: "internaldrive")
                            .foregroundColor(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Computer (Root)")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text("Used: \(computerDevice.formattedUsedStorage)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(6)
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // DS_Store info and count
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "folder.badge.gearshape")
                            .font(.title2)
                            .foregroundColor(.blue)
                            .frame(width: 32)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text(".DS_Store Files")
                                .font(.headline)
                                .fontWeight(.medium)
                            
                            Text("Desktop Services Store files contain folder view preferences like icon positions, sorting options, column widths, and background images. Removing them will reset all folders to default Finder view settings.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        
                        Spacer()
                    }
                    
                    if cleanupManager.hasScanned {
                        HStack {
                            Text("Found:")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            
                            Text("\(cleanupManager.scanResults.dsStoreCount) files")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundColor(cleanupManager.scanResults.dsStoreCount > 0 ? .primary : .secondary)
                            
                            Spacer()
                        }
                        .padding(.horizontal, 32)
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
            .padding()
            
            Divider()
            
            // Action buttons and progress
            VStack(spacing: 12) {
                if cleanupManager.isScanning || cleanupManager.isCleaning {
                    VStack(spacing: 8) {
                        if cleanupManager.isScanning && cleanupManager.totalBytes > 0 {
                            // Progress bar like in analysis tab
                            HStack {
                                Text(cleanupManager.progressMessage)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                
                                Spacer()
                                
                                Text("\(cleanupManager.formattedScannedBytes) / \(cleanupManager.formattedTotalBytes)")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .monospacedDigit()
                            }
                            
                            ProgressView(value: cleanupManager.progressPercentage, total: 100.0)
                                .progressViewStyle(LinearProgressViewStyle())
                        } else {
                            ProgressView(cleanupManager.progressMessage)
                                .progressViewStyle(LinearProgressViewStyle())
                        }
                    }
                }
                
                HStack(spacing: 12) {
                    Button("Scan Directory") {
                        if let computerDevice = diskUtility.devices.first(where: { $0.name == "Computer" }) {
                            Task {
                                await cleanupManager.scanDirectory("/", totalUsedSpace: Int64(computerDevice.usedStorage))
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(cleanupManager.isScanning || cleanupManager.isCleaning)
                    
                    Spacer()
                    
                    Button("Reset View Settings") {
                        if let computerDevice = diskUtility.devices.first(where: { $0.name == "Computer" }) {
                            Task {
                                await cleanupManager.performCleanup("/", totalUsedSpace: Int64(computerDevice.usedStorage))
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!cleanupManager.hasScanned || cleanupManager.isScanning || cleanupManager.isCleaning || cleanupManager.totalSelectedItems == 0)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
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

#Preview {
    DirectoryCleanupView()
}
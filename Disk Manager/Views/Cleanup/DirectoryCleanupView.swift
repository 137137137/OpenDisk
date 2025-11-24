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
                                        .foregroundStyle(.blue)
                                        .frame(width: 32, height: 32)

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Target Location")
                                            .font(.headline)
                                            .fontWeight(.semibold)

                                        Text("Computer (Root Directory)")
                                            .font(.body)
                                            .foregroundStyle(.primary)

                                        Text("Total Used Space: \(computerDevice.formattedUsedStorage)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
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
                                        .frame(width: 40, height: 40)

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(".DS_Store Files")
                                            .font(.title2)
                                            .fontWeight(.semibold)

                                        Text("Desktop Services Store")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()
                                }

                                Text("These hidden files store folder view preferences including:")
                                    .font(.body)
                                    .foregroundStyle(.primary)

                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 8) {
                                        Text("•")
                                            .foregroundStyle(.secondary)
                                        Text("Icon positions and arrangement")
                                            .font(.body)
                                    }
                                    HStack(spacing: 8) {
                                        Text("•")
                                            .foregroundStyle(.secondary)
                                        Text("Sort order and view type (list, icon, column)")
                                            .font(.body)
                                    }
                                    HStack(spacing: 8) {
                                        Text("•")
                                            .foregroundStyle(.secondary)
                                        Text("Column widths and window size")
                                            .font(.body)
                                    }
                                    HStack(spacing: 8) {
                                        Text("•")
                                            .foregroundStyle(.secondary)
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
                                            .foregroundStyle(.secondary)

                                        Text("Scan Results:")
                                            .font(.headline)
                                            .fontWeight(.medium)

                                        Spacer()

                                        Text("\(cleanupManager.scanResults.dsStoreCount)")
                                            .font(.title2)
                                            .fontWeight(.bold)
                                            .foregroundStyle(cleanupManager.scanResults.dsStoreCount > 0 ? .accent : .secondary)

                                        Text("files found")
                                            .font(.body)
                                            .foregroundStyle(.secondary)
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
                                                    .foregroundStyle(.secondary)
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
                            .foregroundStyle(.secondary)
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
        .sheet(isPresented: $showingDefaultsGuide) {
            SetDefaultsGuideView()
        }
    }
}

#Preview {
    DirectoryCleanupView()
}
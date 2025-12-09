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
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Reset Finder View Settings")
                            .font(.largeTitle)
                            .fontWeight(.bold)

                        Text("Remove .DS_Store files to reset all folder view preferences to their default settings.")
                            .foregroundStyle(.secondary)
                    }

                    // Target location info
                    if let computerDevice = diskUtility.devices.first(where: { $0.name == "Computer" }) {
                        LabeledContent {
                            Text("Total Used: \(computerDevice.formattedUsedStorage)")
                                .foregroundStyle(.secondary)
                        } label: {
                            Label("Computer (Root Directory)", systemImage: "internaldrive")
                        }
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }

                    // DS_Store explanation
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Label(".DS_Store Files", systemImage: "folder.badge.gearshape")
                                .font(.headline)

                            Text("These hidden files store folder view preferences including:")
                                .foregroundStyle(.secondary)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("• Icon positions and arrangement")
                                Text("• Sort order and view type (list, icon, column)")
                                Text("• Column widths and window size")
                                Text("• Background images and colors")
                            }
                            .font(.callout)
                            .foregroundStyle(.secondary)

                            if cleanupManager.hasScanned {
                                Divider()

                                HStack {
                                    Text("Scan Results:")
                                        .fontWeight(.medium)

                                    Spacer()

                                    Text("\(cleanupManager.scanResults.dsStoreCount) files found")
                                        .fontWeight(.semibold)
                                        .foregroundStyle(cleanupManager.scanResults.dsStoreCount > 0 ? .primary : .secondary)
                                }
                            }
                        }
                    }

                    // Progress section
                    if cleanupManager.isScanning || cleanupManager.isCleaning {
                        GroupBox {
                            VStack(spacing: 8) {
                                if cleanupManager.isScanning && cleanupManager.totalBytes > 0 {
                                    HStack {
                                        Text(cleanupManager.progressMessage)
                                            .fontWeight(.medium)

                                        Spacer()

                                        Text("\(cleanupManager.formattedScannedBytes) / \(cleanupManager.formattedTotalBytes)")
                                            .foregroundStyle(.secondary)
                                            .monospacedDigit()
                                    }

                                    ProgressView(value: cleanupManager.progressPercentage, total: 100.0)
                                } else {
                                    HStack {
                                        ProgressView()
                                            .controlSize(.small)

                                        Text(cleanupManager.progressMessage)
                                            .fontWeight(.medium)

                                        Spacer()
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(24)
            }

            // Bottom toolbar
            HStack(spacing: 16) {
                Button("Scan for .DS_Store Files") {
                    if let computerDevice = diskUtility.devices.first(where: { $0.name == "Computer" }) {
                        Task {
                            await cleanupManager.scanDirectory("/", totalUsedSpace: Int64(computerDevice.usedStorage))
                        }
                    }
                }
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
            .background(.bar)
        }
        .sheet(isPresented: $showingDefaultsGuide) {
            SetDefaultsGuideView()
        }
    }
}

#Preview {
    DirectoryCleanupView()
}

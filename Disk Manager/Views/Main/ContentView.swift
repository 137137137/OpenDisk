//
//  ContentView.swift
//  Disk Manager
//
//  Created by 137137137 on 9/2/25.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var diskUtility = DiskSpaceUtility()
    @State private var selectedDevice: DeviceInfo?
    @State private var selectedTab: Tab = .analysis
    
    enum Tab: String, CaseIterable {
        case analysis = "Analysis"
        case cleanup = "Reset Views"
        case settings = "Settings"

        var icon: String {
            switch self {
            case .analysis: return "chart.pie"
            case .cleanup: return "folder.badge.gearshape"
            case .settings: return "gearshape"
            }
        }
    }
    
    var body: some View {
        HStack(spacing: 0) {
            // Fixed non-resizable sidebar
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack {
                    Text("Devices & Locations")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(NSColor.controlBackgroundColor))
                
                Divider()
                
                // Device list
                List(diskUtility.devices, selection: $selectedDevice) { device in
                    DeviceRow(device: device) {
                        selectedDevice = device
                    }
                }
                .listStyle(SidebarListStyle())
                
                Divider()
                
                // Tab selector
                VStack(spacing: 8) {
                    ForEach(Tab.allCases, id: \.self) { tab in
                        Button(action: {
                            selectedTab = tab
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: tab.icon)
                                Text(tab.rawValue)
                                Spacer()
                            }
                            .foregroundColor(selectedTab == tab ? .primary : .secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(selectedTab == tab ? Color.accentColor.opacity(0.1) : Color.clear)
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
            }
            .frame(width: 350) // Fixed width - cannot be resized
            .background(Color(NSColor.controlBackgroundColor))
            
            // Separator line (non-draggable)
            Rectangle()
                .fill(Color(NSColor.separatorColor))
                .frame(width: 1)
            
            // Detail view based on selected tab
            Group {
                switch selectedTab {
                case .analysis:
                    if let selectedDevice = selectedDevice {
                        DiskAnalysisView(rootPath: selectedDevice.path, totalUsedSpace: Int64(selectedDevice.usedStorage)) {
                            self.selectedDevice = nil
                        }
                    } else {
                        VStack(spacing: 16) {
                            Image(systemName: "externaldrive")
                                .font(.system(size: 48))
                                .foregroundColor(.secondary)

                            Text("Select a device to analyze")
                                .font(.headline)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(NSColor.controlBackgroundColor))
                    }

                case .cleanup:
                    DirectoryCleanupView()

                case .settings:
                    SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            // Auto-select Computer device
            if let computerDevice = diskUtility.devices.first(where: { $0.name == "Computer" }) {
                selectedDevice = computerDevice
            }
        }
    }
    
}

struct DeviceRow: View {
    let device: DeviceInfo
    let onTap: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: device.icon)
                .font(.title2)
                .foregroundColor(.primary)
                .frame(width: 24, height: 24)
            
            VStack(alignment: .leading, spacing: 2) {
                // Device name
                Text(device.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.primary)
                
                // Subtitle for home folder or storage info
                if device.totalStorage > 0 {
                    // Used/Total storage format with available
                    Text("\(device.formattedUsedStorage)/\(device.formattedTotalStorage), \(device.formattedAvailableStorage) available")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    
                    // Storage progress bar
                    StorageProgressBar(
                        totalStorage: device.totalStorage,
                        availableStorage: device.availableStorage
                    )
                    .padding(.top, 2)
                } else {
                    Text(device.subtitle ?? "")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            // Chevron
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
    }
}

#Preview {
    ContentView()
}

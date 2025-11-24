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
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                
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
                            .foregroundStyle(selectedTab == tab ? .primary : .secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .frame(width: 350) // Fixed width - cannot be resized
            
            // Separator line (non-draggable)
            Divider()
            
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
                                .foregroundStyle(.secondary)

                            Text("Select a device to analyze")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

#Preview {
    ContentView()
}

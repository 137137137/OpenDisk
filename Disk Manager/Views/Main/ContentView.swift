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
        NavigationSplitView {
            List(selection: $selectedDevice) {
                Section("Devices") {
                    ForEach(diskUtility.devices) { device in
                        DeviceRow(device: device) {
                            selectedDevice = device
                        }
                        .tag(device)
                    }
                }

                Section("Views") {
                    ForEach(Tab.allCases, id: \.self) { tab in
                        Button {
                            selectedTab = tab
                        } label: {
                            Label(tab.rawValue, systemImage: tab.icon)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(selectedTab == tab ? Color.accentColor.opacity(0.2) : Color.clear)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Disk Manager")
        } detail: {
            switch selectedTab {
            case .analysis:
                if let selectedDevice = selectedDevice {
                    DiskAnalysisView(rootPath: selectedDevice.path, totalUsedSpace: Int64(selectedDevice.usedStorage)) {
                        self.selectedDevice = nil
                    }
                } else {
                    ContentUnavailableView(
                        "Select a device to analyze",
                        systemImage: "externaldrive",
                        description: Text("Choose a device from the sidebar to view its disk usage")
                    )
                }

            case .cleanup:
                DirectoryCleanupView()

            case .settings:
                SettingsView()
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            if let computerDevice = diskUtility.devices.first(where: { $0.name == "Computer" }) {
                selectedDevice = computerDevice
            }
        }
    }
}

#Preview {
    ContentView()
}

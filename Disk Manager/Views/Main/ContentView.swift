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

    var body: some View {
        NavigationSplitView {
            List(diskUtility.devices, selection: $selectedDevice) { device in
                DeviceRow(device: device) {
                    selectedDevice = device
                }
                .tag(device)
            }
            .listStyle(.sidebar)
            .navigationTitle("Devices")
        } detail: {
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

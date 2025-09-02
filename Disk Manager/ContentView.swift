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
            // Sidebar
            List(diskUtility.devices, selection: $selectedDevice) { device in
                DeviceRow(device: device) {
                    selectedDevice = device
                }
            }
            .navigationTitle("Devices & Locations")
        } detail: {
            // Detail view
            if let selectedDevice = selectedDevice, selectedDevice.name == "Computer" {
                DiskAnalysisView(rootPath: "/") {
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
            }
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
                    HStack(spacing: 4) {
                        Text(device.formattedAvailableStorage)
                            .font(.system(size: 12))
                            .foregroundColor(.primary)
                        
                        Text("Available")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    
                    // Storage progress bar
                    StorageProgressBar(
                        totalStorage: device.totalStorage,
                        availableStorage: device.availableStorage
                    )
                    .padding(.top, 2)
                    
                    // Total storage
                    Text(device.subtitle ?? "")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
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

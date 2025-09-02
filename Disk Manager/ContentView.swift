//
//  ContentView.swift
//  Disk Manager
//
//  Created by 137137137 on 9/2/25.
//

import SwiftUI

struct ContentView: View {
    @State private var devices: [DeviceInfo] = []
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Devices & Locations")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Spacer()
                
                // Window controls placeholder
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.yellow)
                        .frame(width: 12, height: 12)
                    Circle()
                        .fill(Color.green)
                        .frame(width: 12, height: 12)
                    Circle()
                        .fill(Color.red)
                        .frame(width: 12, height: 12)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)
            
            Divider()
            
            // This Device Section
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("This Device")
                        .font(.headline)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        .padding(.bottom, 8)
                    
                    Spacer()
                }
                
                // Device items
                ForEach(devices) { device in
                    DeviceRow(device: device)
                        .padding(.horizontal, 4)
                }
            }
            
            Spacer()
        }
        .background(Color(NSColor.controlBackgroundColor))
        .frame(minWidth: 400, minHeight: 300)
        .onAppear {
            loadDeviceInfo()
        }
    }
    
    private func loadDeviceInfo() {
        // Simple static data first to avoid crashes
        devices = [
            DeviceInfo(
                name: "Home Folder",
                icon: "house",
                totalStorage: 0,
                availableStorage: 0,
                subtitle: NSHomeDirectory()
            ),
            DeviceInfo(
                name: "Computer",
                icon: "desktopcomputer",
                totalStorage: 1000000000000, // 1TB placeholder
                availableStorage: 100000000000, // 100GB placeholder
                subtitle: "1 TB Total"
            )
        ]
    }
}

struct DeviceRow: View {
    let device: DeviceInfo
    
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
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.clear)
                .contentShape(Rectangle())
        )
        .onHover { isHovering in
            // Add hover effect if needed
        }
    }
}

#Preview {
    ContentView()
}

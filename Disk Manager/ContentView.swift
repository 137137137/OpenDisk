//
//  ContentView.swift
//  Disk Manager
//
//  Created by 137137137 on 9/2/25.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var diskUtility = DiskSpaceUtility()
    @State private var showingDiskAnalysis = false
    
    var body: some View {
        if showingDiskAnalysis {
            DiskAnalysisView(rootPath: "/") {
                showingDiskAnalysis = false
            }
        } else {
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("Devices & Locations")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Spacer()
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
                    ForEach(diskUtility.devices) { device in
                        DeviceRow(device: device) {
                            if device.name == "Computer" {
                                showingDiskAnalysis = true
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                }
                
                Spacer()
            }
            .background(Color(NSColor.controlBackgroundColor))
            .frame(minWidth: 400, minHeight: 300)
            .onAppear {
                // DiskSpaceUtility automatically loads device info on init
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
        .onTapGesture {
            onTap()
        }
    }
}

#Preview {
    ContentView()
}

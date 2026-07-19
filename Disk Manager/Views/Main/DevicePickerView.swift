import SwiftUI

/// Opening screen: just the list of scannable disks. Selecting one pushes
/// the analysis screen. Standard components only — the list, navigation
/// links and toolbar pick up the system's current look automatically.
struct DevicePickerView: View {
    let devices: [DeviceInfo]

    var body: some View {
        List(devices) { device in
            NavigationLink(value: device) {
                DeviceRow(device: device)
                    .padding(.vertical, 4)
            }
        }
        .navigationTitle("Select a Disk")
        .overlay {
            if devices.isEmpty {
                ContentUnavailableView(
                    "No Disks Found",
                    systemImage: "externaldrive.badge.questionmark",
                    description: Text("Connected volumes appear here automatically")
                )
            }
        }
    }
}

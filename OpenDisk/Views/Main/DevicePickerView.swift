import AppKit
import SwiftUI

/// Opening screen: a compact, centered card listing the scannable disks
/// (DaisyDisk-style), plus a "Scan Folder…" button for analyzing a single
/// directory. The card hugs its natural size instead of stretching to
/// fill the window.
struct DevicePickerView: View {
    let devices: [DeviceInfo]
    /// Called with a synthesized device for a user-chosen folder.
    let onScanFolder: (DeviceInfo) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox {
                if devices.isEmpty {
                    ContentUnavailableView(
                        "No Disks Found",
                        systemImage: "externaldrive.badge.questionmark",
                        description: Text("Connected volumes appear here automatically")
                    )
                    .padding(.vertical, 8)
                } else {
                    VStack(spacing: 0) {
                        ForEach(devices) { device in
                            DevicePickerRow(device: device)
                            if device.id != devices.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }

            Button("Scan Folder…", systemImage: "folder.badge.plus") {
                chooseFolder()
            }
        }
        // Fixed compact width, natural height: the window (sized to
        // content) fits snugly around the disk list, DaisyDisk-style.
        .frame(width: 460)
        .padding(20)
        .navigationTitle("Select a Disk")
    }

    /// Standard open panel; the chosen folder scans like a device.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder to analyze"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        onScanFolder(DeviceInfo(
            name: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent,
            icon: "folder",
            path: url.path,
            totalBytes: 0,
            availableBytes: 0
        ))
    }
}

/// One disk row: pushes the analysis screen when clicked.
private struct DevicePickerRow: View {
    let device: DeviceInfo

    var body: some View {
        NavigationLink(value: device) {
            HStack {
                DeviceRow(device: device)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .hoverHighlight()
        }
        .buttonStyle(.plain)
    }
}

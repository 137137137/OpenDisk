import SwiftUI

struct StorageOverview: View {
    let devices: [DeviceInfo]
    let folders: [DeviceInfo]
    let onOpen: (DeviceInfo) -> Void
    let onAddFolder: () -> Void

    @Environment(ScanAccess.self) private var scanAccess

    var body: some View {
        Form {
            Section {
                if devices.isEmpty {
                    Text("No disks are connected.")
                        .foregroundStyle(.secondary)
                }
                ForEach(devices) { device in
                    DiskOverviewRow(
                        device: device,
                        actionTitle: ScanAccess.isSandboxed && !scanAccess.isGranted(device.path)
                            ? "Allow…" : "Scan",
                        onOpen: { onOpen(device) }
                    )
                }
            } header: {
                Text("Disks")
            } footer: {
                if ScanAccess.isSandboxed {
                    Text("OpenDisk asks for access the first time you scan a disk, and remembers your choice.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach(folders) { folder in
                    FolderOverviewRow(folder: folder, onOpen: { onOpen(folder) })
                }
                Button(action: onAddFolder) {
                    Label(
                        ScanAccess.isSandboxed ? "Choose a Folder…" : "Scan a Folder…",
                        systemImage: "folder.badge.plus"
                    )
                }
                .buttonStyle(.borderless)
            } header: {
                Text("Folders")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .navigationTitle("OpenDisk")
    }
}

private struct DiskOverviewRow: View {
    let device: DeviceInfo
    let actionTitle: String
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: FileIcon.icon(for: device.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(device.name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if device.totalBytes > 0 {
                        Text("\(ByteFormatter.formatCapacity(device.availableBytes)) available")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                if device.totalBytes > 0 {
                    Gauge(
                        value: Double(device.usedBytes),
                        in: 0...Double(device.totalBytes)
                    ) {
                        EmptyView()
                    }
                    .gaugeStyle(.accessoryLinearCapacity)
                    .tint(.secondary)
                    Text("\(ByteFormatter.formatCapacity(device.usedBytes)) used of \(device.formattedTotalStorage)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            Button(actionTitle, action: onOpen)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onOpen)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: actionTitle, onOpen)
    }
}

private struct FolderOverviewRow: View {
    let folder: DeviceInfo
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: FileIcon.icon(for: folder.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(folder.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text((folder.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button("Scan", action: onOpen)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onOpen)
        .help(folder.path)
    }
}

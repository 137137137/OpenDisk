import AppKit
import SwiftUI

struct LocationsSidebar: View {
    let devices: [DeviceInfo]
    let folders: [DeviceInfo]
    @Binding var selection: String?
    let onAddFolder: () -> Void
    let onRemoveFolder: (DeviceInfo) -> Void

    @Environment(ScanAccess.self) private var scanAccess

    var body: some View {
        List(selection: $selection) {
            Section("Locations") {
                if devices.isEmpty {
                    Text("No Disks Found")
                        .foregroundStyle(.secondary)
                }
                ForEach(devices) { device in
                    LocationRow(
                        location: device,
                        needsAccess: ScanAccess.isSandboxed && !scanAccess.isGranted(device.path)
                    )
                    .tag(device.path)
                    .contextMenu {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: device.path)])
                        }
                    }
                }
            }

            if !folders.isEmpty {
                Section("Folders") {
                    ForEach(folders) { folder in
                        LocationRow(location: folder, needsAccess: false)
                            .tag(folder.path)
                            .contextMenu {
                                Button("Show in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder.path)])
                                }
                                Divider()
                                Button("Remove from Sidebar") { onRemoveFolder(folder) }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button(
                ScanAccess.isSandboxed ? "Choose a Folder…" : "Scan Folder…",
                systemImage: "plus",
                action: onAddFolder
            )
            .buttonStyle(SidebarFooterButtonStyle())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}

private struct SidebarFooterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FooterLabel(configuration: configuration)
    }

    private struct FooterLabel: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .foregroundStyle(isHovered || configuration.isPressed ? .primary : .secondary)
                .opacity(configuration.isPressed ? 0.7 : 1)
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
        }
    }
}

private struct LocationRow: View {
    let location: DeviceInfo
    let needsAccess: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(nsImage: FileIcon.icon(for: location.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(location.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if needsAccess {
                        Spacer(minLength: 4)
                        Image(systemName: "lock")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .help("OpenDisk asks for access the first time you scan this disk.")
                    }
                }

                if location.totalBytes > 0 {
                    Gauge(value: Double(location.usedBytes), in: 0...Double(location.totalBytes)) {
                        EmptyView()
                    }
                    .gaugeStyle(.accessoryLinearCapacity)
                    .controlSize(.mini)
                    .tint(.secondary)

                    Text("\(ByteFormatter.formatCapacity(location.availableBytes)) available of \(location.formattedTotalStorage)")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, location.totalBytes > 0 ? 3 : 0)
        .help(location.path)
        .accessibilityElement(children: .combine)
    }
}

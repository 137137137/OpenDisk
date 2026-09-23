import AppKit
import SwiftUI
#if canImport(Sparkle)
import Sparkle
#endif

struct DevicePickerView: View {
    let devices: [DeviceInfo]
    let onScanFolder: (DeviceInfo) -> Void

    @Environment(ScanAccess.self) private var scanAccess

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if ScanAccess.isSandboxed {
                grantedLocations
            } else {
                mountedVolumes
            }
        }
        .frame(width: 460)
        .padding(20)
        .navigationTitle(ScanAccess.isSandboxed ? "Scan a Location" : "Select a Disk")
    }

    @ViewBuilder
    private var mountedVolumes: some View {
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
                        if device.id != devices.last?.id { Divider() }
                    }
                }
            }
        }

        HStack {
            Button("Scan Folder…", systemImage: "folder.badge.plus") {
                chooseFolder()
            }
            #if canImport(Sparkle)
            Spacer()
            CheckForUpdatesButton()
            #endif
        }
    }

    @ViewBuilder
    private var grantedLocations: some View {
        GroupBox {
            if devices.isEmpty && folderGrants.isEmpty {
                ContentUnavailableView {
                    Label("Choose What to Scan", systemImage: "externaldrive.badge.plus")
                } description: {
                    Text("Grant OpenDisk access to your startup disk to analyze your whole Mac — or to any folder or volume. Your choice is remembered.")
                }
                .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(devices) { device in
                        VolumeShortcutRow(
                            device: device,
                            granted: scanAccess.isGranted(device.path),
                            onOpen: { openVolume(device) }
                        )
                        if device.id != devices.last?.id || !folderGrants.isEmpty { Divider() }
                    }
                    ForEach(folderGrants) { grant in
                        GrantRow(
                            grant: grant,
                            onOpen: { open(grant) },
                            onRemove: { scanAccess.removeGrant(grant) }
                        )
                        if grant.id != folderGrants.last?.id { Divider() }
                    }
                }
            }
        }

        Button("Choose a Folder…", systemImage: "folder.badge.plus") {
            if let grant = scanAccess.requestGrant() { open(grant) }
        }
    }

    #if canImport(Sparkle)
    private struct CheckForUpdatesButton: View {
        @StateObject private var viewModel = CheckForUpdatesViewModel(
            updater: SoftwareUpdater.controller.updater
        )

        var body: some View {
            Button("Check for Updates…", systemImage: "arrow.triangle.2.circlepath") {
                SoftwareUpdater.controller.updater.checkForUpdates()
            }
            .disabled(!viewModel.canCheckForUpdates)
        }
    }
    #endif

    private var folderGrants: [ScanAccess.Grant] {
        scanAccess.grants.filter { grant in !devices.contains { $0.path == grant.path } }
    }

    private func openVolume(_ device: DeviceInfo) {
        if scanAccess.isGranted(device.path) {
            onScanFolder(device)
            return
        }
        // NSOpenPanel cannot select "/" from its parent level, so the boot volume gets no suggested name.
        let isBootVolume = device.path == "/"
        let start = isBootVolume
            ? URL(fileURLWithPath: "/")
            : URL(fileURLWithPath: device.path).deletingLastPathComponent()
        guard let grant = scanAccess.requestGrant(
            startingAt: start,
            suggestedName: isBootVolume ? nil : device.name
        ) else { return }
        let matched = grant.path == device.path
        onScanFolder(DeviceInfo(
            name: grant.name, icon: device.icon, path: grant.path,
            totalBytes: matched ? device.totalBytes : 0,
            availableBytes: matched ? device.availableBytes : 0
        ))
    }

    private func open(_ grant: ScanAccess.Grant) {
        onScanFolder(DeviceInfo(
            name: grant.name, icon: "folder", path: grant.path,
            totalBytes: 0, availableBytes: 0
        ))
    }

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

private struct GrantRow: View {
    let grant: ScanAccess.Grant
    let onOpen: () -> Void
    let onRemove: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                Image(nsImage: FileIcon.icon(for: grant.path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(grant.name).fontWeight(.medium)
                    Text(grant.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

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
        .contextMenu {
            Button(role: .destructive, action: onRemove) {
                Label("Remove from List", systemImage: "xmark.circle")
            }
        }
    }
}

private struct VolumeShortcutRow: View {
    let device: DeviceInfo
    let granted: Bool
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack {
                DeviceRow(device: device)
                Spacer()
                if granted {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                        .help("Access granted — scans in one click")
                }
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

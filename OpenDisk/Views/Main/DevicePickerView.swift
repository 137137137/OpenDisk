import AppKit
import SwiftUI

/// Opening screen: a compact, centered card of scannable locations plus a
/// grant/scan button. It adapts to the distribution build:
///   • Website (non-sandboxed): lists mounted volumes and offers "Scan Folder…".
///   • App Store (sandboxed): lists folders/volumes the user has granted, and
///     offers "Grant a Folder or Volume…" (which persists a security-scoped
///     bookmark so the choice is remembered).
struct DevicePickerView: View {
    let devices: [DeviceInfo]
    /// Called with a device/location to push the analysis screen for it.
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
        // Fixed compact width, natural height: the window (sized to content)
        // fits snugly around the list, DaisyDisk-style.
        .frame(width: 460)
        .padding(20)
        .navigationTitle(ScanAccess.isSandboxed ? "Scan a Location" : "Select a Disk")
    }

    // MARK: - Website build: mounted volumes

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

        Button("Scan Folder…", systemImage: "folder.badge.plus") {
            chooseFolder()
        }
    }

    // MARK: - App Store build: granted locations

    @ViewBuilder
    private var grantedLocations: some View {
        GroupBox {
            if scanAccess.grants.isEmpty {
                ContentUnavailableView {
                    Label("Choose What to Scan", systemImage: "externaldrive.badge.plus")
                } description: {
                    Text("Grant OpenDisk access to your startup disk to analyze your whole Mac — or to any folder or volume. Your choice is remembered.")
                }
                .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(scanAccess.grants) { grant in
                        GrantRow(
                            grant: grant,
                            onOpen: { open(grant) },
                            onRemove: { scanAccess.removeGrant(grant) }
                        )
                        if grant.id != scanAccess.grants.last?.id { Divider() }
                    }
                }
            }
        }

        Button("Choose a Disk or Folder to Scan…", systemImage: "externaldrive.badge.plus") {
            if let grant = scanAccess.requestGrant() { open(grant) }
        }
    }

    private func open(_ grant: ScanAccess.Grant) {
        onScanFolder(DeviceInfo(
            name: grant.name, icon: "folder", path: grant.path,
            totalBytes: 0, availableBytes: 0
        ))
    }

    // MARK: - Folder chooser (website build)

    /// Standard open panel; the chosen folder scans like a device. In the
    /// non-sandboxed build this needs no bookmark — the app can read it directly.
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

/// One mounted-volume row: pushes the analysis screen when clicked.
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

/// One granted-location row: opens on click, with a right-click "Remove".
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

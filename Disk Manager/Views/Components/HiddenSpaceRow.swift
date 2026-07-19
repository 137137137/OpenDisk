import SwiftUI

/// Bottom-of-list entry for space the scan could not see: purgeable
/// system data, local Time Machine snapshots, and unreadable remainders.
/// Clicking it opens a popover explaining each part.
struct HiddenSpaceRow: View {
    let info: HiddenSpaceInfo

    @State private var showingDetails = false

    var body: some View {
        Button {
            showingDetails.toggle()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "eye.slash.circle.fill")
                    .font(.title3)
                    .foregroundStyle(ChartPalette.hiddenSpace.color)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Hidden Space")
                        .fontWeight(.medium)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                Text(ByteFormatter.formatFileSize(info.totalBytes))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
            .hoverHighlight()
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingDetails, arrowEdge: .top) {
            HiddenSpaceDetails(info: info)
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if info.purgeableBytes > 0 { parts.append("purgeable space") }
        if info.snapshotCount > 0 {
            parts.append("\(info.snapshotCount) snapshot\(info.snapshotCount == 1 ? "" : "s")")
        }
        if info.unexplainedBytes > 0 { parts.append("not scannable") }
        return parts.isEmpty ? "Space outside the scan" : parts.joined(separator: " · ")
    }
}

/// The breakdown popover: what each hidden component is and what, if
/// anything, to do about it.
private struct HiddenSpaceDetails: View {
    let info: HiddenSpaceInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Hidden Space")
                    .font(.headline)
                Spacer()
                Text(ByteFormatter.formatFileSize(info.totalBytes))
                    .font(.headline)
                    .monospacedDigit()
            }

            Text("The system reports more space in use than the scan can see in files and folders. Here is where the rest lives:")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            detailSection(
                title: "Purgeable Space",
                amount: ByteFormatter.formatFileSize(info.purgeableBytes),
                explanation: "Caches and temporary system data — including local Time Machine snapshots — that macOS frees automatically whenever an app needs the room. No action is required; the system reclaims it on demand. Part of this pool overlaps with files the scan already counted, so it can be larger than the hidden total."
            )

            detailSection(
                title: info.snapshotCount > 0
                    ? "Snapshots (\(info.snapshotCount))"
                    : "Snapshots",
                amount: info.snapshotCount > 0 ? nil : "none",
                explanation: info.snapshotCount > 0
                    ? "Local Time Machine snapshots are temporary backups that macOS manages and usually deletes within 24 hours. Their space counts toward the purgeable pool above (macOS does not report exact per-snapshot sizes). To remove them immediately, run “tmutil deletelocalsnapshots /” in Terminal."
                    : "No local Time Machine snapshots are present on this volume."
            )

            if info.unexplainedBytes > 0 {
                detailSection(
                    title: "Still Hidden",
                    amount: ByteFormatter.formatFileSize(info.unexplainedBytes),
                    explanation: "Space in directories the app cannot read (system-protected areas), filesystem bookkeeping, and volume-management overhead. Granting Full Disk Access in System Settings can shrink this number."
                )
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    @ViewBuilder
    private func detailSection(title: String, amount: String?, explanation: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                if let amount {
                    Text(amount)
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

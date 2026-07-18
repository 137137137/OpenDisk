import SwiftUI

/// Scan results list with a bottom bar totaling the visible items.
///
/// Shown from the first moments of a scan: rows appear and re-sort live as
/// sizes stream in, and while the scan runs the bottom bar carries a thin
/// progress meter with throughput instead of the finished-scan duration.
struct ScanResultsView: View {
    let items: [FolderItem]
    let scanDuration: TimeInterval
    let isScanning: Bool
    /// Fraction of the volume's used bytes scanned so far; nil shows an
    /// indeterminate bar.
    let progressFraction: Double?
    let scanStatus: String
    let filesPerSecond: String
    let onFolderTap: (FolderItem) -> Void

    init(
        items: [FolderItem],
        scanDuration: TimeInterval,
        isScanning: Bool = false,
        progressFraction: Double? = nil,
        scanStatus: String = "",
        filesPerSecond: String = "",
        onFolderTap: @escaping (FolderItem) -> Void
    ) {
        self.items = items
        self.scanDuration = scanDuration
        self.isScanning = isScanning
        self.progressFraction = progressFraction
        self.scanStatus = scanStatus
        self.filesPerSecond = filesPerSecond
        self.onFolderTap = onFolderTap
    }

    var body: some View {
        VStack(spacing: 0) {
            List(items) { item in
                FolderRowView(item: item) {
                    onFolderTap(item)
                }
            }
            .listStyle(.plain)
            .animation(.default, value: items)

            totalBar
        }
    }

    @ViewBuilder
    private var totalBar: some View {
        VStack(spacing: 0) {
            if isScanning {
                ProgressView(value: progressFraction)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
            }

            HStack(spacing: 12) {
                if isScanning {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                        Text(scanStatus.isEmpty ? "Scanning…" : scanStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if !filesPerSecond.isEmpty {
                            Text("· \(filesPerSecond)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                } else {
                    Text("Total")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)

                    if scanDuration > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "clock.badge.checkmark")
                                .font(.caption)
                                .foregroundStyle(.green)
                            Text(DurationFormatter.scanDuration(scanDuration))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                Text(ByteFormatter.formatFileSize(items.reduce(0) { $0 + $1.size }))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .contentTransition(.numericText())

                Text("(\(items.count) items)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }
}

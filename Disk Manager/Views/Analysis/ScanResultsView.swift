import SwiftUI

struct ScanResultsView: View {
    let items: [FolderItem]
    let scanDuration: TimeInterval
    let isScanning: Bool
    let onFolderTap: (FolderItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            List(items) { item in
                FolderRowView(item: item) {
                    if item.isDirectory {
                        onFolderTap(item)
                    }
                }
            }
            .listStyle(.plain)

            totalBar
        }
    }

    @ViewBuilder
    private var totalBar: some View {
        HStack(spacing: 12) {
            Text("Total")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            if scanDuration > 0 && !isScanning {
                HStack(spacing: 4) {
                    Image(systemName: "clock.badge.checkmark")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Text(formatScanDuration(scanDuration))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            let totalSize = items.reduce(0) { $0 + $1.size }
            Text(ByteFormatter.formatFileSize(totalSize))
                .font(.subheadline)
                .fontWeight(.semibold)

            Text("(\(items.count) items)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func formatScanDuration(_ duration: TimeInterval) -> String {
        if duration < 1 {
            return String(format: "Scanned in %.1f ms", duration * 1000)
        } else if duration < 60 {
            return String(format: "Scanned in %.1f seconds", duration)
        } else {
            let minutes = Int(duration / 60)
            let seconds = Int(duration.truncatingRemainder(dividingBy: 60))
            return String(format: "Scanned in %d:%02d", minutes, seconds)
        }
    }
}

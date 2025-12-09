import SwiftUI

/// Displays the scan results as a list of folders and files.
///
/// Shows:
/// - List of folder items sorted by size
/// - Total size and item count footer
/// - Scan duration when available
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

#Preview {
    ScanResultsView(
        items: [
            FolderItem(name: "Documents", path: "/Users/test/Documents", size: 5_000_000_000, isDirectory: true, itemCount: 150, lastModified: Date()),
            FolderItem(name: "Downloads", path: "/Users/test/Downloads", size: 3_000_000_000, isDirectory: true, itemCount: 45, lastModified: Date()),
            FolderItem(name: "large_file.zip", path: "/Users/test/large_file.zip", size: 1_500_000_000, isDirectory: false, itemCount: 1, lastModified: Date())
        ],
        scanDuration: 2.5,
        isScanning: false,
        onFolderTap: { _ in }
    )
    .frame(width: 500, height: 400)
}

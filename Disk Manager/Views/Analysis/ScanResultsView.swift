import SwiftUI

/// Scan results list with a bottom bar totaling the visible items.
struct ScanResultsView: View {
    let items: [FolderItem]
    let scanDuration: TimeInterval
    let onFolderTap: (FolderItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            List(items) { item in
                FolderRowView(item: item) {
                    onFolderTap(item)
                }
            }
            .listStyle(.plain)

            totalBar
        }
    }

    private var totalBar: some View {
        HStack(spacing: 12) {
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

            Spacer()

            Text(ByteFormatter.formatFileSize(items.reduce(0) { $0 + $1.size }))
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
}

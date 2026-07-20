import SwiftUI

/// Sidebar row for one scannable device. Selection is handled by the
/// enclosing `List`.
struct DeviceRow: View {
    let device: DeviceInfo

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .fontWeight(.medium)

                if device.totalBytes > 0 {
                    Text("\(device.formattedUsedStorage) / \(device.formattedTotalStorage)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    StorageProgressBar(
                        totalBytes: device.totalBytes,
                        availableBytes: device.availableBytes
                    )
                }
            }
        } icon: {
            Image(systemName: device.icon)
                .foregroundStyle(.tint)
        }
    }
}

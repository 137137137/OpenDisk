import SwiftUI

/// One scannable-device row in the disk picker. Uses the real macOS volume
/// icon (the actual startup-disk, external-drive, or Time Machine artwork the
/// Finder shows) rather than a generic SF Symbol, so the picker reads as
/// native — the way DaisyDisk presents disks.
struct DeviceRow: View {
    let device: DeviceInfo

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: FileIcon.icon(for: device.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 3) {
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
        }
    }
}

import Foundation
import Observation

/// Enumerates the devices offered in the sidebar: the boot volume group
/// plus mounted external volumes.
@MainActor
@Observable
final class DeviceMonitor {

    private(set) var devices: [DeviceInfo] = []

    init() {
        Task { await refresh() }
    }

    /// Rebuilds the device list from the currently mounted volumes.
    func refresh() async {
        devices = await Task.detached(priority: .utility) {
            Self.currentDevices()
        }.value
    }

    // MARK: - Enumeration (off the main actor)

    private nonisolated static func currentDevices() -> [DeviceInfo] {
        var devices: [DeviceInfo] = []

        if let capacity = volumeCapacity(ofPath: "/") {
            devices.append(DeviceInfo(
                name: "Computer",
                icon: "desktopcomputer",
                path: "/",
                totalBytes: capacity.total,
                availableBytes: capacity.available
            ))
        }

        let bootDevice = VolumeAttributes.deviceID(ofPath: "/")
        // `mountedVolumeURLs` with `.skipHiddenVolumes` already excludes the
        // system-managed APFS volumes in the boot container (Recovery,
        // Preboot, VM, Update), which report the whole container's capacity
        // and are not separately scannable devices.
        let keys: [URLResourceKey] = [
            .volumeIsBrowsableKey, .volumeNameKey,
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        ]
        let volumeURLs = (FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []).sorted { $0.path < $1.path }
        for url in volumeURLs {
            let path = url.path
            let values = try? url.resourceValues(forKeys: Set(keys))
            // Belt-and-suspenders: only user-browsable volumes, never the
            // boot volume (matched by device ID rather than by name).
            guard values?.volumeIsBrowsable == true,
                  VolumeAttributes.deviceID(ofPath: path) != bootDevice,
                  FileManager.default.isReadableFile(atPath: path),
                  let capacity = volumeCapacity(ofPath: path) else {
                continue
            }
            devices.append(DeviceInfo(
                name: values?.volumeName ?? url.lastPathComponent,
                icon: "externaldrive",
                path: path,
                totalBytes: capacity.total,
                availableBytes: capacity.available
            ))
        }

        return devices
    }

    private nonisolated static func volumeCapacity(
        ofPath path: String
    ) -> (total: Int64, available: Int64)? {
        let url = URL(fileURLWithPath: path)
        if let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey
        ]), let total = values.volumeTotalCapacity {
            return (Int64(total), Int64(values.volumeAvailableCapacity ?? 0))
        }

        // Fallback for volumes where resource values fail.
        if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path),
           let total = attributes[.systemSize] as? Int64,
           let free = attributes[.systemFreeSize] as? Int64 {
            return (total, free)
        }
        return nil
    }
}

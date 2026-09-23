import Foundation
import Observation

@MainActor
@Observable
final class DeviceMonitor {

    private(set) var devices: [DeviceInfo] = []

    init() {
        Task { await refresh() }
    }

    func refresh() async {
        devices = await Task.detached(priority: .utility) {
            Self.currentDevices()
        }.value
    }

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

    nonisolated static func volumeCapacity(ofPath path: String) -> VolumeCapacity? {
        let url = URL(fileURLWithPath: path)
        if let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey
        ]), let total = values.volumeTotalCapacity {
            return VolumeCapacity(
                total: Int64(total),
                available: Int64(values.volumeAvailableCapacity ?? 0)
            )
        }

        if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path),
           let total = attributes[.systemSize] as? Int64,
           let free = attributes[.systemFreeSize] as? Int64 {
            return VolumeCapacity(total: total, available: free)
        }
        return nil
    }
}

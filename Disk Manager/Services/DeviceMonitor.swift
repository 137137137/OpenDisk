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
                availableBytes: capacity.available,
                isBootVolume: true
            ))
        }

        let volumeNames = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
        for name in volumeNames.sorted() {
            guard !shouldSkipVolume(named: name) else { continue }
            let path = "/Volumes/" + name
            guard FileManager.default.isReadableFile(atPath: path),
                  let capacity = volumeCapacity(ofPath: path) else {
                continue
            }
            devices.append(DeviceInfo(
                name: name,
                icon: "externaldrive",
                path: path,
                totalBytes: capacity.total,
                availableBytes: capacity.available,
                isBootVolume: false
            ))
        }

        return devices
    }

    private nonisolated static func shouldSkipVolume(named name: String) -> Bool {
        // Hidden volumes, the boot volume's own mount alias, and Time
        // Machine snapshots are not separately scannable devices.
        name.hasPrefix(".")
            || name == "Macintosh HD"
            || name.contains("com.apple.TimeMachine")
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

import AppKit
import Observation

@MainActor
@Observable
final class DeviceMonitor {
    private(set) var devices: [DeviceInfo] = []
    @ObservationIgnored private var volumeObservers: [NSObjectProtocol] = []

    private static let refreshInterval: Duration = .seconds(3)

    init() {
        Task { await refresh() }
        observeVolumeChanges()
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.refreshInterval)
                guard let self else { return }
                await self.refresh()
            }
        }
    }

    private func observeVolumeChanges() {
        let center = NSWorkspace.shared.notificationCenter
        let names = [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification,
            NSWorkspace.didActivateApplicationNotification,
        ]
        volumeObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Task { await self.refresh() }
                }
            }
        }
    }

    func refresh() async {
        let current = await Task.detached(priority: .utility) {
            Self.currentDevices()
        }.value
        if current != devices { devices = current }
    }

    private nonisolated static func currentDevices() -> [DeviceInfo] {
        var devices: [DeviceInfo] = []

        if let capacity = volumeCapacity(ofPath: "/") {
            devices.append(DeviceInfo(
                name: String(localized: "Computer"),
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
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]), let total = values.volumeTotalCapacity {
            return VolumeCapacity(
                total: Int64(total),
                free: Int64(values.volumeAvailableCapacity ?? 0),
                availableForImportantUsage: values.volumeAvailableCapacityForImportantUsage
            )
        }

        if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path),
           let total = attributes[.systemSize] as? Int64,
           let free = attributes[.systemFreeSize] as? Int64 {
            return VolumeCapacity(total: total, free: free)
        }
        return nil
    }
}

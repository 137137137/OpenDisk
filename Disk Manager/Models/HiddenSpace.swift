import Foundation

/// The gap between a volume's reported used space and what a scan could
/// see, broken down as far as public APIs allow.
struct HiddenSpaceInfo: Equatable, Sendable {
    /// Volume used bytes minus scanned bytes.
    let totalBytes: Int64
    /// Space macOS can reclaim automatically (caches, local Time Machine
    /// snapshots, ...): the difference between the capacity available for
    /// important usage and the actually free capacity.
    let purgeableBytes: Int64
    /// Local Time Machine snapshots present on the volume. macOS offers no
    /// public API for their exact sizes; their space is typically part of
    /// `purgeableBytes`.
    let snapshotCount: Int

    /// Hidden space not explained by the purgeable pool: unreadable
    /// directories, filesystem overhead, other volumes' bookkeeping.
    var unexplainedBytes: Int64 { max(0, totalBytes - purgeableBytes) }

    /// Display name of the synthetic top-level folder that carries this
    /// space in the list and chart.
    static let folderName = "Purgeable Space"
    /// Row identity for the synthetic folder. The "::" prefix marks paths
    /// that do not exist on disk; navigation and Finder actions skip them.
    static var sentinelPath: String { "::" + folderName }
}

/// Measures hidden space for a volume. Blocking (runs `tmutil` and stats
/// the volume): call off the main thread.
enum HiddenSpaceProbe {

    /// Ignore gaps under this size — rounding and churn noise.
    private static let minimumReportableBytes: Int64 = 100 * 1024 * 1024

    static func probe(volumePath: String, scannedBytes: Int64) -> HiddenSpaceInfo? {
        let used = VolumeAttributes.usedBytes(ofVolumeContaining: volumePath)
        let hidden = used - scannedBytes
        guard hidden >= minimumReportableBytes else { return nil }

        var purgeable: Int64 = 0
        let url = URL(fileURLWithPath: volumePath, isDirectory: true)
        if let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ]),
            let important = values.volumeAvailableCapacityForImportantUsage,
            let available = values.volumeAvailableCapacity {
            purgeable = max(0, important - Int64(available))
        }

        // Purgeable is reported raw, not clamped to the hidden gap: the
        // purgeable pool overlaps with files the scan already counted
        // (caches are ordinary files), so it can legitimately exceed the
        // unscanned remainder.
        return HiddenSpaceInfo(
            totalBytes: hidden,
            purgeableBytes: purgeable,
            snapshotCount: localSnapshotCount(volumePath: volumePath)
        )
    }

    /// Counts local Time Machine snapshots via `tmutil listlocalsnapshots`.
    private static func localSnapshotCount(volumePath: String) -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = ["listlocalsnapshots", volumePath]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return 0
        }
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n")
            .filter { $0.contains("com.apple.TimeMachine") }
            .count
    }
}

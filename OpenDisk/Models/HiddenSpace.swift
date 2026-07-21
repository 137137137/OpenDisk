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
    /// that do not exist on disk; Finder actions skip them, and
    /// `DiskAnalyzer` resolves navigation into them specially.
    static var sentinelPath: String { "::" + folderName }
    /// Row identity for the auto-managed system-purgeable leaf shown
    /// inside the synthetic folder.
    static var systemLeafPath: String { sentinelPath + "/system" }
}

/// Curated cache locations that are safe to clear: caches that macOS or
/// the owning tool rebuilds (or re-downloads) on demand. Shown inside the
/// synthetic "Purgeable Space" folder with their scanned sizes.
///
/// Deliberately conservative — no application-support data, no browser
/// profiles, nothing whose loss changes user-visible state beyond a slower
/// next launch.
enum CleanableCacheCatalog {

    struct Location {
        let name: String
        let path: String
    }

    /// Candidate locations; callers keep only the ones present in the
    /// scanned tree with nonzero size. Entries are disjoint on disk so no
    /// bytes are listed twice within this view.
    static var locations: [Location] {
        let home = NSHomeDirectory()
        return [
            // Package / build tool caches (rebuilt or re-downloaded on demand).
            Location(name: "Homebrew Cache", path: home + "/Library/Caches/Homebrew"),
            Location(name: "npm Cache", path: home + "/.npm/_cacache"),
            Location(name: "Yarn Cache", path: home + "/Library/Caches/Yarn"),
            Location(name: "pnpm Store", path: home + "/Library/pnpm/store"),
            Location(name: "pip Cache", path: home + "/Library/Caches/pip"),
            Location(name: "Cargo Registry Cache", path: home + "/.cargo/registry/cache"),
            Location(name: "Go Build Cache", path: home + "/Library/Caches/go-build"),
            Location(name: "Go Module Cache", path: home + "/go/pkg/mod/cache"),
            Location(name: "Gradle Cache", path: home + "/.gradle/caches"),
            Location(name: "CocoaPods Cache", path: home + "/Library/Caches/CocoaPods"),
            Location(name: "Composer Cache", path: home + "/.composer/cache"),
            // Developer tooling.
            Location(name: "Xcode DerivedData", path: home + "/Library/Developer/Xcode/DerivedData"),
            Location(name: "Xcode iOS DeviceSupport", path: home + "/Library/Developer/Xcode/iOS DeviceSupport"),
            Location(name: "Xcode Archives", path: home + "/Library/Developer/Xcode/Archives"),
            Location(name: "Playwright Browsers", path: home + "/.cache/ms-playwright"),
            Location(name: "Puppeteer Browsers", path: home + "/.cache/puppeteer"),
            // App / ML / browser caches.
            Location(name: "Chrome Cache", path: home + "/Library/Caches/Google/Chrome"),
            Location(name: "Safari Cache", path: home + "/Library/Caches/com.apple.Safari"),
            Location(name: "Hugging Face Cache", path: home + "/.cache/huggingface"),
            Location(name: "PyTorch Hub Cache", path: home + "/.cache/torch"),
            // General.
            Location(name: "User Logs", path: home + "/Library/Logs"),
            Location(name: "Trash", path: home + "/.Trash"),
            Location(name: "System Caches", path: "/Library/Caches"),
        ]
    }
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

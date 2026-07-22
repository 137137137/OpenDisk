import Foundation

/// The finished result of a scan: a compact tree plus the path it covers.
struct ScanResult: Sendable {
    let rootPath: String
    let tree: FileTree
    /// Directories the scan could not open (permissions, revoked sandbox
    /// grant, volume ejected mid-scan). Lets the UI distinguish "empty"
    /// from "couldn't read".
    var unreadableDirectories: Int = 0
}

/// A partial snapshot of a scan in flight: the tree as discovered so far,
/// already merged across volumes and rolled up, so it can be displayed
/// exactly like a finished result. Sizes only ever grow between snapshots.
struct PartialScanResult: Sendable {
    /// Monotonically increasing within one scan. Snapshots are produced
    /// and delivered asynchronously; consumers must drop any snapshot
    /// whose sequence is not greater than the last one they applied.
    let sequence: Int
    let tree: FileTree
}

/// A thread-safe closure that snapshots a scanner's partially built tree.
/// Scanners hand one to their caller before scanning begins; it may be
/// invoked from any thread, any number of times, while the scan runs.
typealias PartialTreeProvider = @Sendable () -> FileTree

/// A live update emitted while a scan runs.
enum ScanEvent: Sendable {
    /// Lightweight counters, emitted many times per second.
    case progress(ScanProgress)
    /// A displayable snapshot of the partially scanned tree, emitted a few
    /// times per second at most. Short scans may finish without emitting
    /// any.
    case partial(PartialScanResult)
}

/// Anything that can scan a directory hierarchy and stream updates.
///
/// The production implementation is `ScanEngine`; tests inject fakes that
/// return canned trees.
protocol DiskScanning: Sendable {
    /// Scans `path` and returns the resulting tree.
    ///
    /// - Parameters:
    ///   - path: Absolute path of the directory or volume to scan.
    ///   - onEvent: Called from an arbitrary context while the scan runs:
    ///     `.progress` periodically (and once more with final numbers
    ///     before return), `.partial` whenever a new displayable snapshot
    ///     is ready.
    func scan(
        path: String,
        onEvent: @escaping @Sendable (ScanEvent) -> Void
    ) async -> ScanResult
}

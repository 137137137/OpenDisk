import Foundation

/// The finished result of a scan: a compact tree plus the path it covers.
struct ScanResult: Sendable {
    let rootPath: String
    let tree: FileTree

    static func empty(rootPath: String) -> ScanResult {
        ScanResult(rootPath: rootPath, tree: FileTree(rootName: rootPath))
    }
}

/// Anything that can scan a directory hierarchy and report progress.
///
/// The production implementation is `ScanEngine`; tests inject fakes that
/// return canned trees.
protocol DiskScanning: Sendable {
    /// Scans `path` and returns the resulting tree.
    ///
    /// - Parameters:
    ///   - path: Absolute path of the directory or volume to scan.
    ///   - onProgress: Called periodically from an arbitrary context while
    ///     the scan runs, and once more with final numbers before return.
    func scan(
        path: String,
        onProgress: @escaping @Sendable (ScanProgress) -> Void
    ) async -> ScanResult
}

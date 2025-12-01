import Foundation

// MARK: - Scanner Protocol

/// Protocol defining the contract for disk scanning operations.
///
/// Implementations must handle concurrent access and progress reporting.
/// This protocol enables dependency injection for testing with mock scanners.
///
/// ## Usage
/// ```swift
/// let analyzer = DiskAnalyzer(scanner: HyperScanner())
/// // or for testing:
/// let analyzer = DiskAnalyzer(scanner: MockScanner())
/// ```
protocol ScannerProtocol: Sendable {
    /// Scans the specified URL and returns a hierarchical scan result.
    ///
    /// - Parameters:
    ///   - url: The root URL to scan
    ///   - onProgress: Callback for progress updates (called on arbitrary thread)
    /// - Returns: The root scan item containing the complete hierarchy
    func scan(
        url: URL,
        onProgress: @escaping @Sendable (HyperScanProgress) -> Void
    ) async -> HyperScanItem
}

// MARK: - Progress Tracking Protocol

/// Protocol for receiving scan progress updates.
protocol ProgressReportingProtocol {
    /// Reports current scan progress.
    ///
    /// - Parameter progress: The current scan progress state
    func reportProgress(_ progress: HyperScanProgress)
}

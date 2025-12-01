import Foundation
import Darwin

// MARK: - File System ID

/// Represents a unique file system identifier combining device and inode.
///
/// Used for hard link detection and cycle prevention during scanning.
struct FileSystemID: Hashable, Sendable {
    let device: dev_t
    let inode: ino_t
}

// MARK: - Scan Context

/// Aggregates scan statistics and inode tracking for a single scan operation.
/// Provides a convenient API that matches the existing HyperScanner interface.
///
/// ## Thread Safety
/// This class is `Sendable` because it only contains `Sendable` components:
/// - `ScanStatistics`: Uses Darwin atomic operations
/// - `InodeTracker`: Uses lock-free bloom filter + sharded locks
///
/// ## Swift 6 Sendable Conformance
/// Uses `@unchecked Sendable` as it contains `@unchecked Sendable` components
/// that manually guarantee thread safety through atomic operations and locks.
///
/// ## Usage
/// Create one context per scan operation. The context tracks:
/// - Bytes scanned and items processed (for progress reporting)
/// - Visited inodes (for hardlink deduplication)
final class ScanContext: @unchecked Sendable {
    let stats = ScanStatistics()
    let inodeTracker = InodeTracker()

    /// Add progress for bytes and items scanned.
    @inline(__always)
    func addProgress(bytes: Int64, items: Int) {
        stats.add(bytes: bytes, items: items)
    }

    /// Set the total bytes on disk (for percentage calculation).
    func setTotalBytes(_ bytes: Int64) {
        stats.setTotalBytes(bytes)
    }

    /// Get current scan progress.
    func getProgress(currentPath: String) -> HyperScanProgress {
        stats.snapshot(path: currentPath)
    }

    /// Reset all tracking state for a new scan.
    func reset() {
        stats.reset()
        inodeTracker.reset()
    }

    /// Check if inode is new (first visit). Returns true if new, false if seen before.
    /// Used for hardlink deduplication.
    @inline(__always)
    func visit(inode: FileSystemID) -> Bool {
        return inodeTracker.visit(device: inode.device, inode: inode.inode)
    }
}

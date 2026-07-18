import Foundation

/// One row of scan results as shown in the UI: a file or directory with its
/// aggregate size. Built on demand from the scan's `FileTree`; only the
/// items actually displayed are ever materialized.
struct FolderItem: Identifiable, Hashable, Comparable, Sendable {
    /// Paths are unique among siblings, which is all a list needs — and
    /// unlike a random UUID they are stable across conversions, so SwiftUI
    /// can diff successive snapshots of the same directory.
    var id: String { path }

    let name: String
    let path: String
    let size: Int64
    let isDirectory: Bool
    /// Number of direct children (directories only; zero for files).
    let itemCount: Int

    var formattedSize: String {
        ByteFormatter.formatFileSize(size)
    }

    /// Sorts largest first, the only order the app displays.
    static func < (lhs: FolderItem, rhs: FolderItem) -> Bool {
        lhs.size > rhs.size
    }
}

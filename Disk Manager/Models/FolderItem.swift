import Foundation

/// One row of scan results as shown in the UI: a file or directory with its
/// aggregate size. Built on demand from the scan's `FileTree`; only the
/// items actually displayed are ever materialized.
struct FolderItem: Identifiable, Hashable, Sendable {
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
    /// False for skeleton rows shown before the scan has produced any
    /// numbers for this entry; the UI renders a placeholder instead of
    /// "Zero KB". Rows built from a (partial or final) scan tree are
    /// always known, even while still growing.
    var sizeIsKnown: Bool = true

    var formattedSize: String {
        ByteFormatter.formatFileSize(size)
    }
}

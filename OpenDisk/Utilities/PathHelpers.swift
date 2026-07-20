import Foundation

extension String {
    /// This path as a directory prefix: guaranteed to end in exactly one
    /// trailing "/" so a child name can be appended directly.
    ///
    /// Load-bearing app-wide: `FileTree.path(of:)`, the skeleton reader,
    /// chart items and navigation all build child paths with this rule,
    /// and SwiftUI row identity relies on every layer agreeing.
    var directoryPrefix: String {
        hasSuffix("/") ? self : self + "/"
    }
}

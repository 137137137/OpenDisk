import AppKit
import UniformTypeIdentifiers

/// Caches Finder file icons so a fast-scrolling list doesn't re-hit
/// IconServices (`NSWorkspace.icon(forFile:)`) for every row. Keyed by path;
/// `NSCache` evicts under memory pressure.
enum FileIcon {
    // NSCache is internally thread-safe, so cross-actor access is fine.
    nonisolated(unsafe) private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 4000
        return cache
    }()

    /// The generic macOS folder icon, for synthetic folder rows (e.g.
    /// Purgeable Space) that have no real on-disk path to look up.
    static let folder = NSWorkspace.shared.icon(for: .folder)

    static func icon(for path: String) -> NSImage {
        let key = path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(image, forKey: key)
        return image
    }
}

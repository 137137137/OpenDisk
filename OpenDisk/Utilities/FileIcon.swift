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

    /// Display size (points) every cached icon is pre-rasterized to.
    /// Rows then blit a tiny bitmap instead of downscaling a multi-rep
    /// 512px IconServices image on the main thread per row per frame.
    private static let rowPointSize: CGFloat = 22

    static func icon(for path: String) -> NSImage {
        let key = path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = rasterized(NSWorkspace.shared.icon(forFile: path))
        cache.setObject(image, forKey: key)
        return image
    }

    /// Flattens an icon to a single `rowPointSize`@2x bitmap rep. Safe off
    /// the main thread (draws into a private bitmap context).
    private static func rasterized(_ image: NSImage) -> NSImage {
        let points = rowPointSize
        let pixels = Int(points * 2)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return image }
        rep.size = NSSize(width: points, height: points)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(
            in: NSRect(x: 0, y: 0, width: points, height: points),
            from: .zero, operation: .copy, fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
        let flattened = NSImage(size: NSSize(width: points, height: points))
        flattened.addRepresentation(rep)
        return flattened
    }

    /// Resolves icons for many paths into the cache, in display order, off
    /// the calling actor. Fired when a result list lands so icons are
    /// ready before rows scroll into view; per-row loads then find the
    /// cache already hot. Respects task cancellation between lookups.
    static func prewarm(_ paths: [String]) async {
        await Task.detached(priority: .utility) {
            for path in paths.prefix(800) {
                if Task.isCancelled { return }
                _ = icon(for: path)
            }
        }.value
    }

    /// The already-cached icon, or nil — never a blocking IconServices
    /// lookup. Scrolling rows draw with this (falling back to a type
    /// icon) so the main thread never waits on icon I/O.
    static func cached(for path: String) -> NSImage? {
        cache.object(forKey: path as NSString)
    }

    /// Resolves `path`'s real icon into the cache off the calling actor.
    /// Returns nothing — the caller re-reads `cached(for:)` afterwards, so
    /// no NSImage ever crosses an isolation boundary.
    static func warm(_ path: String) async {
        await Task.detached(priority: .utility) {
            _ = icon(for: path)
        }.value
    }

    // Type icons (keyed by lowercased path extension) resolve without
    // touching the file system, so they are safe to fetch synchronously
    // in a scrolling row. Handful of distinct extensions per list.
    nonisolated(unsafe) private static let typeCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 512
        return cache
    }()

    /// Instant stand-in icon: the generic folder for directories, the
    /// file-type icon for files. Visually right for almost everything
    /// except custom-icon items (apps, badged folders), which refine to
    /// their real icon once `warm(_:)` completes.
    static func typeIcon(forPathExtension ext: String, isDirectory: Bool) -> NSImage {
        if isDirectory { return folder }
        let key = ext.lowercased() as NSString
        if let cached = typeCache.object(forKey: key) { return cached }
        let type = UTType(filenameExtension: ext.lowercased()) ?? .data
        let image = rasterized(NSWorkspace.shared.icon(for: type))
        typeCache.setObject(image, forKey: key)
        return image
    }
}

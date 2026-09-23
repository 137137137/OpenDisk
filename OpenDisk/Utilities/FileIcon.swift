import AppKit
import UniformTypeIdentifiers

enum FileIcon {
    nonisolated(unsafe) private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 4000
        return cache
    }()

    static let folder = NSWorkspace.shared.icon(for: .folder)

    private static let rowPointSize: CGFloat = 22

    static func icon(for path: String) -> NSImage {
        let key = path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = rasterized(NSWorkspace.shared.icon(forFile: path))
        cache.setObject(image, forKey: key)
        return image
    }

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

    static func prewarm(_ paths: [String]) async {
        await Task.detached(priority: .utility) {
            for path in paths.prefix(800) {
                if Task.isCancelled { return }
                _ = icon(for: path)
            }
        }.value
    }

    static func cached(for path: String) -> NSImage? {
        cache.object(forKey: path as NSString)
    }

    static func warm(_ path: String) async {
        await Task.detached(priority: .utility) {
            _ = icon(for: path)
        }.value
    }

    nonisolated(unsafe) private static let typeCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 512
        return cache
    }()

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

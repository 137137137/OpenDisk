import Foundation

/// Manages caching for folder trees and directory sizes
actor CacheManager {
    private var folderTree: [String: [FolderItem]] = [:]
    private var sizeCache: [String: Int64] = [:]

    func getCachedChildren(for path: String) -> [FolderItem]? {
        return folderTree[path]
    }

    func cacheChildren(_ children: [FolderItem], for path: String) {
        folderTree[path] = children
    }

    func getCachedSize(for path: String) -> Int64? {
        return sizeCache[path]
    }

    func cacheSize(_ size: Int64, for path: String) {
        sizeCache[path] = size
    }

    func invalidatePath(_ path: String) {
        folderTree.removeValue(forKey: path)
        sizeCache.removeValue(forKey: path)

        // Also invalidate parent
        let parentPath = URL(fileURLWithPath: path).deletingLastPathComponent().path
        folderTree.removeValue(forKey: parentPath)
        sizeCache.removeValue(forKey: parentPath)
    }

    func clearAll() {
        folderTree.removeAll()
        sizeCache.removeAll()
    }

    func hasCachedData(for path: String) -> Bool {
        return folderTree[path] != nil
    }
}
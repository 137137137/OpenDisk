import Foundation

/// Manages caching for folder trees and directory sizes.
///
/// Conforms to `CacheProtocol` for dependency injection support.
actor CacheManager: CacheProtocol {
    private var folderTree: [String: [FolderItem]] = [:]
    private var sizeCache: [String: Int64] = [:]

    // MARK: - CacheProtocol Conformance

    func get(for key: String) async -> [FolderItem]? {
        return folderTree[key]
    }

    func set(_ value: [FolderItem], for key: String) async {
        folderTree[key] = value
    }

    func invalidate(for key: String) async {
        folderTree.removeValue(forKey: key)
        sizeCache.removeValue(forKey: key)

        // Also invalidate parent
        let parentPath = URL(fileURLWithPath: key).deletingLastPathComponent().path
        folderTree.removeValue(forKey: parentPath)
        sizeCache.removeValue(forKey: parentPath)
    }

    func clearAll() async {
        folderTree.removeAll()
        sizeCache.removeAll()
    }

    // MARK: - Additional Methods

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

        let parentPath = URL(fileURLWithPath: path).deletingLastPathComponent().path
        folderTree.removeValue(forKey: parentPath)
        sizeCache.removeValue(forKey: parentPath)
    }

    func hasCachedData(for path: String) -> Bool {
        return folderTree[path] != nil
    }
}
import Foundation

// MARK: - Cache Protocol

/// Protocol for caching scan results.
///
/// Implementations should be actor-based for thread safety.
/// This protocol enables dependency injection for testing with mock caches.
///
/// ## Usage
/// ```swift
/// let analyzer = DiskAnalyzer(cache: CacheManager())
/// // or for testing:
/// let analyzer = DiskAnalyzer(cache: MockCacheManager())
/// ```
protocol CacheProtocol: Actor {
    /// Retrieves cached folder items for a given path.
    ///
    /// - Parameter key: The path key to look up
    /// - Returns: Cached folder items if available, nil otherwise
    func get(for key: String) async -> [FolderItem]?

    /// Stores folder items in the cache.
    ///
    /// - Parameters:
    ///   - value: The folder items to cache
    ///   - key: The path key to store under
    func set(_ value: [FolderItem], for key: String) async

    /// Invalidates cache for a specific path.
    ///
    /// - Parameter key: The path key to invalidate
    func invalidate(for key: String) async

    /// Clears all cached data.
    func clearAll() async
}

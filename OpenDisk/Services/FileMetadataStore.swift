import Foundation
import Observation

/// Caches metadata of the listed items so rows can show it and the list can be
/// sorted by date. Cleared on navigation and rescans to keep dates fresh.
@MainActor
@Observable
final class FileMetadataStore {
    private var metadataByPath: [String: FileMetadata] = [:]

    func metadata(for path: String) -> FileMetadata? {
        metadataByPath[path]
    }

    func removeAll() {
        metadataByPath.removeAll()
    }

    func load(_ paths: [String]) async {
        let missingPaths = paths.filter { !$0.hasPrefix("::") && metadataByPath[$0] == nil }
        guard !missingPaths.isEmpty else { return }
        let loaded = await Task.detached(priority: .utility) {
            Self.read(missingPaths)
        }.value
        guard !Task.isCancelled else { return }
        metadataByPath.merge(loaded) { _, newer in newer }
    }

    private nonisolated static func read(_ paths: [String]) -> [String: FileMetadata] {
        var result: [String: FileMetadata] = [:]
        for path in paths {
            result[path] = FileMetadata.read(atPath: path)
        }
        return result
    }
}

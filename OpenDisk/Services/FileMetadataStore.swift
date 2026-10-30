import Foundation
import Observation

@MainActor
@Observable
final class FileMetadataStore {
    private var metadataByPath: [String: FileMetadata] = [:]
    private var pathsWithLastOpenedDate = Set<String>()

    func metadata(for path: String) -> FileMetadata? {
        metadataByPath[path]
    }

    func removeAll() {
        metadataByPath.removeAll()
        pathsWithLastOpenedDate.removeAll()
    }

    func load(_ paths: [String], includingLastOpenedDate: Bool) async {
        let missingPaths = paths.filter { path in
            guard !path.hasPrefix("::") else { return false }
            if metadataByPath[path] == nil { return true }
            return includingLastOpenedDate && !pathsWithLastOpenedDate.contains(path)
        }
        guard !missingPaths.isEmpty else { return }
        let loaded = await Task.detached(priority: .utility) {
            Self.read(missingPaths, includingLastOpenedDate: includingLastOpenedDate)
        }.value
        guard !Task.isCancelled else { return }
        metadataByPath.merge(loaded) { _, newer in newer }
        if includingLastOpenedDate {
            pathsWithLastOpenedDate.formUnion(loaded.keys)
        }
    }

    private nonisolated static func read(
        _ paths: [String],
        includingLastOpenedDate: Bool
    ) -> [String: FileMetadata] {
        var result: [String: FileMetadata] = [:]
        for path in paths {
            result[path] = FileMetadata.read(atPath: path, includingLastOpenedDate: includingLastOpenedDate)
        }
        return result
    }
}

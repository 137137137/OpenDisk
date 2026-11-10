import Foundation
import Observation
import SwiftUI

struct SidebarFolders: Sendable {
    var paths: Set<String> = []
    var add: @MainActor @Sendable (_ path: String, _ size: Int64?) -> Void = { _, _ in }
    var remove: @MainActor @Sendable (_ path: String) -> Void = { _ in }

    func contains(_ path: String) -> Bool { paths.contains(path) }

    static func path(_ path: String, isInside root: String) -> Bool {
        guard path != root else { return true }
        if root == "/" { return path.hasPrefix("/") && !path.hasPrefix("/Volumes/") }
        return path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}

extension EnvironmentValues {
    @Entry var sidebarFolders = SidebarFolders()
}

@MainActor
@Observable
final class FolderSizeStore {
    static let shared = FolderSizeStore()

    private static let defaultsKey = "sidebar_folder_sizes"

    private(set) var sizes: [String: Int64]

    private init() {
        let stored = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) ?? [:]
        sizes = stored.compactMapValues { ($0 as? NSNumber)?.int64Value }
    }

    func record(_ size: Int64, for path: String) {
        guard size >= 0, sizes[path] != size else { return }
        sizes[path] = size
        save()
    }

    func forget(_ path: String) {
        guard sizes.removeValue(forKey: path) != nil else { return }
        save()
    }

    private func save() {
        UserDefaults.standard.set(sizes.mapValues { NSNumber(value: $0) }, forKey: Self.defaultsKey)
    }
}

struct NavigationRequest: Equatable {
    let path: String
    let id = UUID()
}

import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct CollectedFile: Codable, Identifiable, Hashable, Sendable {
    let path: String
    let name: String
    let size: Int64
    let isDirectory: Bool
    var relatedKind: RelatedFiles.Kind?
    var relatedApp: String?

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var formattedSize: String { ByteFormatter.formatFileSize(size) }

    var isApp: Bool { RelatedFiles.isAppBundle(path, isDirectory: isDirectory) }

    init(
        path: String,
        name: String,
        size: Int64,
        isDirectory: Bool,
        relatedKind: RelatedFiles.Kind? = nil,
        relatedApp: String? = nil
    ) {
        self.path = path
        self.name = name
        self.size = size
        self.isDirectory = isDirectory
        self.relatedKind = relatedKind
        self.relatedApp = relatedApp
    }

    init(_ item: FolderItem) {
        self.init(path: item.path, name: item.name, size: item.size, isDirectory: item.isDirectory)
    }
}

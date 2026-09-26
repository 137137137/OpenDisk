import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct CollectedFile: Codable, Identifiable, Hashable, Sendable {
    let path: String
    let name: String
    let size: Int64
    let isDirectory: Bool

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var formattedSize: String { ByteFormatter.formatFileSize(size) }

    init(path: String, name: String, size: Int64, isDirectory: Bool) {
        self.path = path
        self.name = name
        self.size = size
        self.isDirectory = isDirectory
    }

    init(_ item: FolderItem) {
        self.init(path: item.path, name: item.name, size: item.size, isDirectory: item.isDirectory)
    }
}

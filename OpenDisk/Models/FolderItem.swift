import Foundation

struct FolderItem: Identifiable, Hashable, Sendable {
    var id: String { path }

    let name: String
    let path: String
    let size: Int64
    let isDirectory: Bool
    let itemCount: Int
    var sizeIsKnown: Bool = true

    var formattedSize: String {
        ByteFormatter.formatFileSize(size)
    }
}

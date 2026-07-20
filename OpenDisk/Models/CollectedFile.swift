import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// A file or folder the user has dragged into the Collector for deletion.
/// A small value type so it can ride SwiftUI drag-and-drop as `Transferable`
/// and be handed to a background actor for the actual removal.
struct CollectedFile: Codable, Transferable, Identifiable, Hashable, Sendable {
    let path: String
    let name: String
    /// Aggregate on-disk size (for a directory, the whole subtree) as the
    /// scan measured it — reused so the Collector total is instant.
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

    /// Build from a displayed row, preserving the size the scan already knows.
    init(_ item: FolderItem) {
        self.init(path: item.path, name: item.name, size: item.size, isDirectory: item.isDirectory)
    }

    static var transferRepresentation: some TransferRepresentation {
        // Private in-app content type; in-process drags need no Info.plist
        // registration. Also expose a fileURL proxy so an item could be
        // dragged out to Finder/other apps if desired.
        CodableRepresentation(contentType: .openDiskCollectedFile)
        ProxyRepresentation(exporting: \.url)
    }
}

extension UTType {
    /// Dynamically-declared type for the Collector's in-app drags.
    static let openDiskCollectedFile = UTType(exportedAs: "ideals.OpenDisk.collected-file")
}

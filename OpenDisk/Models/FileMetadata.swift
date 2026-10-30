import CoreServices
import Foundation

struct FileMetadata: Sendable, Equatable {
    let modificationDate: Date?
    let creationDate: Date?
    let lastOpenedDate: Date?
    let posixPermissions: UInt16?
    let ownerName: String?

    func date(for column: FileListColumn) -> Date? {
        switch column {
        case .modified: modificationDate
        case .created: creationDate
        case .lastOpened: lastOpenedDate
        case .kind, .permissions, .owner: nil
        }
    }

    static func read(atPath path: String, includingLastOpenedDate: Bool) -> FileMetadata? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        return FileMetadata(
            modificationDate: attributes[.modificationDate] as? Date,
            creationDate: attributes[.creationDate] as? Date,
            lastOpenedDate: includingLastOpenedDate ? lastOpenedDate(atPath: path) : nil,
            posixPermissions: (attributes[.posixPermissions] as? NSNumber)?.uint16Value,
            ownerName: attributes[.ownerAccountName] as? String
        )
    }

    private static func lastOpenedDate(atPath path: String) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}

import Darwin
import Foundation

struct DirectoryFileEntry {
    let name: String
    let size: Int64
    let fileID: UInt64
    let linkCount: UInt32
}

struct DirectoryContents {
    var files: [DirectoryFileEntry] = []
    var subdirectoryNames: [String] = []
    var mountPointNames: [String] = []
}

enum DirectoryReadResult {
    case contents(DirectoryContents, device: dev_t)
    case crossesDeviceBoundary
    case unreadable
}

final class BulkDirectoryReader {

    private static let bufferSize = 256 * 1024

    private let buffer: UnsafeMutableRawPointer

    init() {
        buffer = .allocate(byteCount: Self.bufferSize, alignment: 16)
    }

    deinit {
        buffer.deallocate()
    }

    func read(directoryAt path: String, allowedDevices: Set<dev_t>) -> DirectoryReadResult {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { return .unreadable }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0 else { return .unreadable }
        guard allowedDevices.contains(info.st_dev) else { return .crossesDeviceBoundary }

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(
            UInt32(ATTR_CMN_RETURNED_ATTRS) |
            UInt32(ATTR_CMN_NAME) |
            UInt32(ATTR_CMN_OBJTYPE) |
            UInt32(ATTR_CMN_FILEID)
        )
        // st_dev often matches across APFS volume-group/snapshot mounts; MOUNTSTATUS is the reliable boundary check.
        request.dirattr = attrgroup_t(UInt32(ATTR_DIR_MOUNTSTATUS))
        request.fileattr = attrgroup_t(
            UInt32(ATTR_FILE_LINKCOUNT) | UInt32(ATTR_FILE_ALLOCSIZE)
        )

        var contents = DirectoryContents()
        contents.files.reserveCapacity(128)
        contents.subdirectoryNames.reserveCapacity(32)

        while true {
            let count = getattrlistbulk(fd, &request, buffer, Self.bufferSize, 0)
            if count <= 0 { break }

            var offset = 0
            for _ in 0..<count {
                guard offset + 4 <= Self.bufferSize else { break }
                let record = buffer.advanced(by: offset)
                let length = Int(record.loadUnaligned(as: UInt32.self))
                guard length > 0, offset + length <= Self.bufferSize else { break }
                parseRecord(record, length: length, into: &contents)
                offset += length
            }
        }

        return .contents(contents, device: info.st_dev)
    }

    private func parseRecord(
        _ record: UnsafeMutableRawPointer,
        length: Int,
        into contents: inout DirectoryContents
    ) {
        guard length >= 36 else { return }

        let returnedCommon = record.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
        let returnedDir = record.loadUnaligned(fromByteOffset: 12, as: UInt32.self)
        let returnedFile = record.loadUnaligned(fromByteOffset: 16, as: UInt32.self)

        let nameDataOffset = Int(record.loadUnaligned(fromByteOffset: 24, as: Int32.self))
        let nameLength = Int(record.loadUnaligned(fromByteOffset: 28, as: UInt32.self)) - 1
        let nameStart = 24 + nameDataOffset
        guard nameLength > 0, nameLength < 1_024, nameStart + nameLength <= length else {
            return
        }
        let namePointer = record.advanced(by: nameStart)

        if nameLength <= 2 {
            let firstByte = namePointer.load(as: UInt8.self)
            if firstByte == UInt8(ascii: ".") {
                if nameLength == 1 { return }
                if namePointer.load(fromByteOffset: 1, as: UInt8.self) == UInt8(ascii: ".") {
                    return
                }
            }
        }

        var offset = 32
        var isDirectory = false
        if returnedCommon & UInt32(ATTR_CMN_OBJTYPE) != 0 {
            guard offset + 4 <= length else { return }
            isDirectory = record.loadUnaligned(fromByteOffset: offset, as: UInt32.self) == 2
            offset += 4
        }

        var fileID: UInt64 = 0
        if returnedCommon & UInt32(ATTR_CMN_FILEID) != 0 {
            guard offset + 8 <= length else { return }
            fileID = record.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
            offset += 8
        }

        let name = String(
            decoding: UnsafeRawBufferPointer(start: namePointer, count: nameLength),
            as: UTF8.self
        )

        if isDirectory {
            var mountStatus: UInt32 = 0
            if returnedDir & UInt32(ATTR_DIR_MOUNTSTATUS) != 0 {
                guard offset + 4 <= length else { return }
                mountStatus = record.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                offset += 4
            }
            if mountStatus != 0 {
                contents.mountPointNames.append(name)
            } else {
                contents.subdirectoryNames.append(name)
            }
            return
        }

        var linkCount: UInt32 = 1
        if returnedFile & UInt32(ATTR_FILE_LINKCOUNT) != 0 {
            guard offset + 4 <= length else { return }
            linkCount = record.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            offset += 4
        }

        var size: Int64 = 0
        if returnedFile & UInt32(ATTR_FILE_ALLOCSIZE) != 0 {
            guard offset + 8 <= length else { return }
            size = record.loadUnaligned(fromByteOffset: offset, as: Int64.self)
            if size < 0 || size > 1_000_000_000_000_000 { size = 0 }
        }

        contents.files.append(DirectoryFileEntry(
            name: name, size: size, fileID: fileID, linkCount: linkCount
        ))
    }
}

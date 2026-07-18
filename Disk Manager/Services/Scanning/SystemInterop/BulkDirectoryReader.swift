import Darwin
import Foundation

/// One file entry produced by reading a directory.
struct DirectoryFileEntry {
    let name: String
    /// Physical (allocated) size in bytes. Zero if unknown.
    let size: Int64
    let fileID: UInt64
    let linkCount: UInt32
}

/// The parsed contents of a single directory.
struct DirectoryContents {
    var files: [DirectoryFileEntry] = []
    var subdirectoryNames: [String] = []
}

/// The outcome of attempting to read one directory.
enum DirectoryReadResult {
    case contents(DirectoryContents, device: dev_t)
    /// The directory lives on a device outside the scan's allowlist (mount
    /// point or firmlink boundary) and must not be descended into.
    case crossesDeviceBoundary
    /// The directory could not be opened or read.
    case unreadable
}

/// Reads directories with `getattrlistbulk(2)`, the bulk enumeration API
/// that returns hundreds of entries (with attributes) per syscall.
///
/// - Important: Thread-safety: not `Sendable`. Each scan worker owns its
///   own instance; the reusable read buffer is only touched inside
///   `read(directoryAt:allowedDevices:)`, which is never called
///   concurrently on one instance.
final class BulkDirectoryReader {

    /// 256 KB holds thousands of entries per syscall; both 128 KB and
    /// 256 KB measure near-optimal in published getattrlistbulk tuning.
    private static let bufferSize = 256 * 1024

    private let buffer: UnsafeMutableRawPointer

    init() {
        buffer = .allocate(byteCount: Self.bufferSize, alignment: 16)
    }

    deinit {
        buffer.deallocate()
    }

    /// Reads every entry of the directory at `path`.
    ///
    /// If the opened directory's `st_dev` is not in `allowedDevices`, the
    /// read is abandoned with `.crossesDeviceBoundary`. Checking the device
    /// on the *opened* descriptor is what keeps a scan on its volumes:
    /// opening a firmlink or mount point yields the target volume's device,
    /// so external volumes and virtual filesystems are cut off by the same
    /// rule with no hardcoded path lists (a scan of a System-volume subtree
    /// allowlists the Data volume too, so firmlinks compose as they do in
    /// the live namespace).
    ///
    /// Known limitation (shared with the previous engine): an unresponsive
    /// network mount point can block `open` in the kernel indefinitely;
    /// there is no portable timeout for that.
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
        request.fileattr = attrgroup_t(
            UInt32(ATTR_FILE_LINKCOUNT) | UInt32(ATTR_FILE_ALLOCSIZE)
        )

        var contents = DirectoryContents()
        contents.files.reserveCapacity(128)
        contents.subdirectoryNames.reserveCapacity(32)

        while true {
            let count = getattrlistbulk(fd, &request, buffer, Self.bufferSize, 0)
            // A mid-stream error keeps whatever was already parsed rather
            // than discarding the directory.
            if count <= 0 { break }

            var offset = 0
            for _ in 0..<count {
                // The length prefix drives the walk; validate it so a
                // malformed record can never push reads past the buffer.
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

    /// Parses one variable-length attribute record.
    ///
    /// Layout with our request set (all offsets from the record start):
    ///   0   u32              record length
    ///   4   attribute_set_t  returned attributes (5 x u32)
    ///   24  attrreference    name (dataoffset relative to offset 24)
    ///   32  u32              objtype        - if returned
    ///   ..  u64              fileid         - if returned
    ///   ..  u32              linkcount      - files, if returned
    ///   ..  s64              allocsize      - files, if returned
    /// Fields after the attribute set only exist when the corresponding
    /// bit is set in the returned-attributes bitmap, so the parse walks a
    /// running offset gated on those bits.
    private func parseRecord(
        _ record: UnsafeMutableRawPointer,
        length: Int,
        into contents: inout DirectoryContents
    ) {
        guard length >= 36 else { return }

        let returnedCommon = record.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
        let returnedFile = record.loadUnaligned(fromByteOffset: 16, as: UInt32.self)

        let nameDataOffset = Int(record.loadUnaligned(fromByteOffset: 24, as: Int32.self))
        // Name length includes the trailing NUL.
        let nameLength = Int(record.loadUnaligned(fromByteOffset: 28, as: UInt32.self)) - 1
        let nameStart = 24 + nameDataOffset
        guard nameLength > 0, nameLength < 1_024, nameStart + nameLength <= length else {
            return
        }
        let namePointer = record.advanced(by: nameStart)

        // Skip "." and "..".
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
            isDirectory = record.loadUnaligned(fromByteOffset: offset, as: UInt32.self) == 2 // VDIR
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
            contents.subdirectoryNames.append(name)
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

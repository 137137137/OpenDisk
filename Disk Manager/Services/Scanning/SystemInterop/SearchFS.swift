import Darwin
import Foundation

/// Raw interface to the `searchfs(2)` syscall: a kernel-side walk of a
/// volume's catalog B-tree that streams every file and directory on the
/// volume without opening a single directory. On HFS+ this is by far the
/// fastest way to enumerate a whole volume (the technique behind classic
/// DaisyDisk-class scanners); on APFS it measures ~2x slower than parallel getattrlistbulk traversal.
///
/// The syscall has no prototype in the public headers; the symbol lives in
/// libsystem_kernel and is declared here directly. Struct layouts mirror
/// `bsd/sys/attr.h` exactly.
///
@_silgen_name("searchfs")
private func darwin_searchfs(
    _ path: UnsafePointer<CChar>,
    _ searchBlock: UnsafeMutableRawPointer,
    _ numMatches: UnsafeMutablePointer<UInt>,
    _ scriptCode: UInt32,
    _ options: UInt32,
    _ state: UnsafeMutableRawPointer
) -> Int32

/// One catalog entry streamed out of a `searchfs` volume scan.
struct CatalogEntry {
    let name: String
    let fileID: UInt64
    let parentID: UInt64
    /// Physical (allocated) size in bytes, all forks. Zero for directories.
    let size: Int64
    let isDirectory: Bool
    let linkCount: UInt32
}

/// Errors that abort a catalog scan; callers fall back to traversal.
enum CatalogSearchError: Error {
    /// The volume's filesystem does not implement `searchfs` (ENOTSUP).
    case unsupported
    /// The catalog changed underneath the search too many times (EBUSY).
    case volumeKeptChanging
    /// A result record did not have the expected shape for our attribute set.
    case unexpectedRecordLayout
    /// Any other errno from the syscall.
    case systemError(Int32)
    /// The scan was cancelled by the caller.
    case cancelled
}

/// Streams every entry of one mounted volume via `searchfs(2)`.
///
/// Stateless namespace: each call allocates and frees its own buffers, so
/// concurrent scans of different volumes are safe.
enum CatalogSearch {

    // MARK: Constants (bsd/sys/attr.h)

    private static let srchfsStart: UInt32 = 0x0000_0001
    private static let srchfsMatchDirs: UInt32 = 0x0000_0004
    private static let srchfsMatchFiles: UInt32 = 0x0000_0008

    private static let attrCmnName: UInt32 = 0x0000_0001
    private static let attrCmnObjType: UInt32 = 0x0000_0008
    private static let attrCmnOwnerID: UInt32 = 0x0000_8000
    private static let attrCmnFileID: UInt32 = 0x0200_0000
    private static let attrCmnParentID: UInt32 = 0x0400_0000
    private static let attrFileLinkCount: UInt32 = 0x0000_0001
    private static let attrFileAllocSize: UInt32 = 0x0000_0004

    /// `fsobj_type_t` values from `sys/vnode.h`.
    private static let vdir: UInt32 = 2

    /// UTF-8 script code used by Apple's own sample code (value is ignored
    /// by current kernels but documented in the man page example).
    private static let scriptUTF8: UInt32 = 0x0800_0103

    /// Kernel time slices are clamped to 100 ms anyway (HFS
    /// `kMaxMicroSecsInKernel`); this just tunes per-call batch latency.
    private static let timeLimitMicroseconds: Int32 = 100_000

    private static let resultBufferSize = 2 * 1024 * 1024
    private static let maxMatchesPerCall: UInt = 16_384
    private static let maxCatalogRestarts = 3
    /// `struct searchstate` is 556 bytes packed; over-allocate for safety.
    private static let searchStateSize = 1_024

    /// Mirrors `struct fssearchblock`. Every field is naturally aligned, so
    /// the Swift layout matches the C layout (104 bytes total).
    private struct FSSearchBlock {
        var returnattrs: UnsafeMutablePointer<attrlist>?
        var returnbuffer: UnsafeMutableRawPointer?
        var returnbuffersize: Int
        var maxmatches: UInt
        var timelimit: timeval
        var searchparams1: UnsafeMutableRawPointer?
        var sizeofsearchparams1: Int
        var searchparams2: UnsafeMutableRawPointer?
        var sizeofsearchparams2: Int
        var searchattrs: attrlist
    }

    /// Packed search parameter for a scalar `ATTR_CMN_OWNERID` range match:
    /// a leading buffer length followed by the uid value.
    private struct OwnerIDParam {
        var length: UInt32
        var uid: uid_t
    }

    // MARK: Result record layout

    // With returnattrs = NAME | OBJTYPE | FILEID | PARENTID (common) and
    // LINKCOUNT | ALLOCSIZE (file), each record is packed as:
    //
    //   offset 0   u32            length (includes itself)
    //   offset 4   attrreference  name (dataoffset relative to offset 4)
    //   offset 12  u32            objtype
    //   offset 16  u64            fileid      (only 4-byte aligned!)
    //   offset 24  u64            parentid
    //   -- files only (absent for directories):
    //   offset 32  u32            linkcount
    //   offset 36  s64            allocsize
    //   -- then the UTF-8 name bytes at offset 4 + name.dataoffset
    //
    // searchfs has no ATTR_CMN_RETURNED_ATTRS bitmap, so presence of the
    // file group is derived from the name's dataoffset: 28 for directory
    // records, 40 for file records. Anything else means the filesystem
    // packed the record differently than we expect and we bail out.
    private static let dirNameDataOffset: Int32 = 28
    private static let fileNameDataOffset: Int32 = 40

    /// Enumerates the entire volume containing `mountPoint`.
    ///
    /// `body` is invoked once per catalog entry, in catalog order (not
    /// hierarchical order). Callers should ignore the volume's root
    /// directory (file ID 2) if the filesystem chooses to report it.
    ///
    /// On EBUSY (catalog mutated between continuation calls) the whole scan
    /// restarts from scratch, `onRestart` is called so the caller can throw
    /// away partial state, and a bounded number of restarts is attempted.
    static func enumerateVolume(
        at mountPoint: String,
        isCancelled: () -> Bool,
        onRestart: () -> Void,
        body: (CatalogEntry) -> Void
    ) throws(CatalogSearchError) {
        let resultBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: resultBufferSize, alignment: 16
        )
        let stateBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: searchStateSize, alignment: 16
        )
        defer {
            resultBuffer.deallocate()
            stateBuffer.deallocate()
        }

        var restarts = 0
        while true {
            do {
                try runSingleSearch(
                    mountPoint: mountPoint,
                    resultBuffer: resultBuffer,
                    stateBuffer: stateBuffer,
                    isCancelled: isCancelled,
                    body: body
                )
                return
            } catch CatalogSearchError.volumeKeptChanging {
                restarts += 1
                guard restarts <= maxCatalogRestarts else {
                    throw CatalogSearchError.volumeKeptChanging
                }
                onRestart()
            }
        }
    }

    private static func runSingleSearch(
        mountPoint: String,
        resultBuffer: UnsafeMutableRawPointer,
        stateBuffer: UnsafeMutableRawPointer,
        isCancelled: () -> Bool,
        body: (CatalogEntry) -> Void
    ) throws(CatalogSearchError) {
        var returnAttrs = attrlist()
        returnAttrs.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        returnAttrs.commonattr = attrCmnName | attrCmnObjType | attrCmnFileID | attrCmnParentID
        returnAttrs.fileattr = attrFileLinkCount | attrFileAllocSize

        var searchAttrs = attrlist()
        searchAttrs.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        searchAttrs.commonattr = attrCmnOwnerID

        // Match everything: owner uid in the inclusive range [0, UInt32.max].
        var lowerBound = OwnerIDParam(length: UInt32(MemoryLayout<OwnerIDParam>.size), uid: 0)
        var upperBound = OwnerIDParam(length: UInt32(MemoryLayout<OwnerIDParam>.size), uid: uid_t.max)

        memset(stateBuffer, 0, searchStateSize)

        var options = srchfsStart | srchfsMatchFiles | srchfsMatchDirs

        // The pointer-scoping closures are `rethrows`, which erases typed
        // errors to `any Error`; the loop returns its failure instead so
        // the typed throw happens outside the closures.
        let failure = withUnsafeMutablePointer(to: &returnAttrs) { returnAttrsPtr in
            withUnsafeMutablePointer(to: &lowerBound) { lowerPtr in
                withUnsafeMutablePointer(to: &upperBound) { upperPtr -> CatalogSearchError? in
                    var block = FSSearchBlock(
                        returnattrs: returnAttrsPtr,
                        returnbuffer: resultBuffer,
                        returnbuffersize: resultBufferSize,
                        maxmatches: maxMatchesPerCall,
                        timelimit: timeval(tv_sec: 0, tv_usec: timeLimitMicroseconds),
                        searchparams1: UnsafeMutableRawPointer(lowerPtr),
                        sizeofsearchparams1: MemoryLayout<OwnerIDParam>.size,
                        searchparams2: UnsafeMutableRawPointer(upperPtr),
                        sizeofsearchparams2: MemoryLayout<OwnerIDParam>.size,
                        searchattrs: searchAttrs
                    )

                    while true {
                        if isCancelled() { return .cancelled }

                        var matchCount: UInt = 0
                        let result = withUnsafeMutableBytes(of: &block) { blockBytes in
                            darwin_searchfs(
                                mountPoint,
                                blockBytes.baseAddress!,
                                &matchCount,
                                scriptUTF8,
                                options,
                                stateBuffer
                            )
                        }
                        let err: Int32 = (result == 0) ? 0 : errno
                        options &= ~srchfsStart

                        if err == 0 || err == EAGAIN {
                            do throws(CatalogSearchError) {
                                try parseBatch(
                                    in: resultBuffer,
                                    bufferSize: resultBufferSize,
                                    matchCount: Int(matchCount),
                                    body: body
                                )
                            } catch {
                                return error
                            }
                            if err == 0 { return nil }
                            continue
                        }

                        switch err {
                        case EBUSY:
                            return .volumeKeptChanging
                        case ENOTSUP:
                            return .unsupported
                        default:
                            return .systemError(err)
                        }
                    }
                }
            }
        }
        if let failure { throw failure }
    }

    private static func parseBatch(
        in buffer: UnsafeMutableRawPointer,
        bufferSize: Int,
        matchCount: Int,
        body: (CatalogEntry) -> Void
    ) throws(CatalogSearchError) {
        var offset = 0
        for _ in 0..<matchCount {
            guard offset + 4 <= bufferSize else {
                throw CatalogSearchError.unexpectedRecordLayout
            }
            let record = buffer.advanced(by: offset)
            let recordLength = Int(record.loadUnaligned(as: UInt32.self))
            guard recordLength >= 32, offset + recordLength <= bufferSize else {
                throw CatalogSearchError.unexpectedRecordLayout
            }
            defer { offset += recordLength }

            let nameDataOffset = record.loadUnaligned(fromByteOffset: 4, as: Int32.self)
            // Name length includes the trailing NUL.
            let nameLength = Int(record.loadUnaligned(fromByteOffset: 8, as: UInt32.self)) - 1

            let hasFileAttrs: Bool
            switch nameDataOffset {
            case dirNameDataOffset: hasFileAttrs = false
            case fileNameDataOffset: hasFileAttrs = true
            default: throw CatalogSearchError.unexpectedRecordLayout
            }

            let nameStart = 4 + Int(nameDataOffset)
            guard nameLength > 0, nameStart + nameLength <= recordLength else {
                continue
            }

            let objType = record.loadUnaligned(fromByteOffset: 12, as: UInt32.self)
            let fileID = record.loadUnaligned(fromByteOffset: 16, as: UInt64.self)
            let parentID = record.loadUnaligned(fromByteOffset: 24, as: UInt64.self)

            let isDirectory = (objType == vdir)
            // The file attribute group is only packed for non-directories,
            // which `hasFileAttrs` already encodes; the objtype check guards
            // against a filesystem that packs both groups unconditionally.
            var linkCount: UInt32 = 1
            var size: Int64 = 0
            if hasFileAttrs && !isDirectory {
                linkCount = record.loadUnaligned(fromByteOffset: 32, as: UInt32.self)
                size = record.loadUnaligned(fromByteOffset: 36, as: Int64.self)
                if size < 0 || size > 1_000_000_000_000_000 { size = 0 }
            }

            let name = String(
                decoding: UnsafeRawBufferPointer(
                    start: record.advanced(by: nameStart), count: nameLength
                ),
                as: UTF8.self
            )

            body(CatalogEntry(
                name: name,
                fileID: fileID,
                parentID: parentID,
                size: size,
                isDirectory: isDirectory,
                linkCount: linkCount
            ))
        }
    }
}

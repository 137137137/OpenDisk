import Darwin
import Foundation

@_silgen_name("searchfs")
private func darwin_searchfs(
    _ path: UnsafePointer<CChar>,
    _ searchBlock: UnsafeMutableRawPointer,
    _ numMatches: UnsafeMutablePointer<UInt>,
    _ scriptCode: UInt32,
    _ options: UInt32,
    _ state: UnsafeMutableRawPointer
) -> Int32

struct CatalogEntry {
    let name: String
    let fileID: UInt64
    let parentID: UInt64
    let size: Int64
    let isDirectory: Bool
    let linkCount: UInt32
}

enum CatalogSearchError: Error {
    case unsupported
    case volumeKeptChanging
    case unexpectedRecordLayout
    case systemError(Int32)
    case cancelled
}

enum CatalogSearch {
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

    private static let vdir: UInt32 = 2

    private static let scriptUTF8: UInt32 = 0x0800_0103

    private static let timeLimitMicroseconds: Int32 = 100_000

    private static let resultBufferSize = 2 * 1024 * 1024
    private static let maxMatchesPerCall: UInt = 16_384
    private static let maxCatalogRestarts = 3
    private static let searchStateSize = 1_024

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

    private struct OwnerIDParam {
        var length: UInt32
        var uid: uid_t
    }

    // No RETURNED_ATTRS bitmap in searchfs: name dataoffset 28 = dir, 40 = file record; fileid at offset 16 is only 4-byte aligned.
    private static let dirNameDataOffset: Int32 = 28
    private static let fileNameDataOffset: Int32 = 40

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

        var lowerBound = OwnerIDParam(length: UInt32(MemoryLayout<OwnerIDParam>.size), uid: 0)
        var upperBound = OwnerIDParam(length: UInt32(MemoryLayout<OwnerIDParam>.size), uid: uid_t.max)

        memset(stateBuffer, 0, searchStateSize)

        var options = srchfsStart | srchfsMatchFiles | srchfsMatchDirs

        // rethrows closures erase typed errors, so the loop returns its failure and the typed throw happens outside.
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

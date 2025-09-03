import Foundation
import Darwin

// MARK: - macOS getattrlistbulk Syscall Implementation

// Bulk scanning types moved to SharedTypes.swift

private func createOptimizedAttrList() -> attrlist {
    var attrList = attrlist()
    attrList.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
    
    attrList.commonattr = attrgroup_t(ATTR_CMN_NAME | ATTR_CMN_OBJTYPE | ATTR_CMN_DEVID | ATTR_CMN_FILEID)
    attrList.fileattr = attrgroup_t(ATTR_FILE_ALLOCSIZE)
    attrList.dirattr = 0
    attrList.forkattr = 0
    attrList.volattr = 0
    
    return attrList
}

func bulkScanDirectoryOptimized(dirFd: Int32) throws -> [BulkScanEntry] {
    // Use the existing proven optimizedBulkList instead of our custom implementation
    let optimizedEntries = try optimizedBulkList(dirFd: dirFd)
    
    return optimizedEntries.map { entry in
        BulkScanEntry(
            name: entry.actualName,
            isDir: entry.isDir,
            allocSize: entry.allocSize,
            inode: entry.fileId,
            deviceId: entry.deviceId
        )
    }
}

func optimizedBulkList(dirFd: Int32) throws -> [OptimizedScanEntry] {
    var entries: [OptimizedScanEntry] = []
    var attrList = createOptimizedAttrList()
    let bufferSize = 64 * 1024 // 64KB buffer
    var buffer = Data(count: bufferSize)
    
    while true {
        let count = buffer.withUnsafeMutableBytes { bufferPtr in
            getattrlistbulk(dirFd, &attrList, bufferPtr.baseAddress, bufferSize, 0)
        }
        
        if count <= 0 {
            break
        }
        
        var offset = 0
        for _ in 0..<count {
            buffer.withUnsafeBytes { bufferPtr in
                let attrBuf = bufferPtr.bindMemory(to: BulkAttrBuf.self)[offset / MemoryLayout<BulkAttrBuf>.stride]
                
                let namePtr = bufferPtr.baseAddress!.advanced(by: offset + Int(attrBuf.nameRef.attr_dataoffset))
                let nameLength = Int(attrBuf.nameRef.attr_length) - 1 // Exclude null terminator
                let name = String(bytes: UnsafeBufferPointer(start: namePtr.assumingMemoryBound(to: UInt8.self), count: nameLength), encoding: .utf8) ?? "unknown"
                
                let isDir = attrBuf.objType == 2 // VDIR constant value (2)
                
                entries.append(OptimizedScanEntry(
                    actualName: name,
                    isDir: isDir,
                    allocSize: attrBuf.allocSize,
                    fileId: attrBuf.fileId,
                    deviceId: attrBuf.deviceId
                ))
                
                offset += Int(attrBuf.length)
            }
        }
    }
    
    return entries
}

// Breadth-First Traverser was experimental and is currently unused.
// Removed to avoid Swift 6 strict concurrency issues and duplicate logic.
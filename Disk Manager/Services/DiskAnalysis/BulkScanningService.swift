import Foundation
import Darwin

// MARK: - macOS getattrlistbulk Syscall Implementation

struct BulkAttrBuf {
    var length: UInt32
    var objType: UInt32
    var deviceId: UInt32
    var fileId: UInt64
    var allocSize: Int64
    var nameRef: attrreference_t
}

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

func bulkScanDirectoryOptimized(dirFd: Int32) throws -> [BulkEntry] {
    // Use the existing proven optimizedBulkList instead of our custom implementation
    let optimizedEntries = try optimizedBulkList(dirFd: dirFd)
    
    return optimizedEntries.map { entry in
        BulkEntry(
            name: entry.actualName,
            isDir: entry.isDir,
            allocSize: entry.allocSize,
            inode: entry.fileId,
            deviceId: entry.deviceId
        )
    }
}

func optimizedBulkList(dirFd: Int32) throws -> [OptimizedBulkEntry] {
    var entries: [OptimizedBulkEntry] = []
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
                
                let isDir = attrBuf.objType == 4 // VDIR constant value
                
                entries.append(OptimizedBulkEntry(
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

// MARK: - Breadth-First Traverser

class BreadthFirstTraverser {
    private let globalSeenInodes = ShardedInodeSet()
    private let threadPool = HighPerformanceThreadPool()
    
    func traverse(rootPath: String, maxDepth: Int = 10) async throws -> [FolderItem] {
        var results: [FolderItem] = []
        var queue: [(String, Int)] = [(rootPath, 0)]
        
        while !queue.isEmpty {
            let currentBatch = Array(queue.prefix(8)) // Process in batches
            queue.removeFirst(min(8, queue.count))
            
            let batchResults = await withTaskGroup(of: (items: [FolderItem], depth: Int).self) { group in
                var allItems: [FolderItem] = []
                
                for (path, depth) in currentBatch {
                    if depth >= maxDepth { continue }
                    
                    group.addTask {
                        let items = await self.scanSingleDirectory(path)
                        return (items: items, depth: depth)
                    }
                }
                
                for await result in group {
                    allItems.append(contentsOf: result.items)
                    
                    // Add subdirectories to queue for next level
                    for item in result.items where item.isDirectory {
                        if result.depth < maxDepth - 1 {
                            queue.append((item.path, result.depth + 1))
                        }
                    }
                }
                
                return allItems
            }
            
            results.append(contentsOf: batchResults)
        }
        
        return results
    }
    
    private func scanSingleDirectory(_ path: String) async -> [FolderItem] {
        do {
            return try await threadPool.execute {
                return try self.scanDirectoryContents(path)
            }
        } catch {
            print("Error scanning \(path): \(error)")
            return []
        }
    }
    
    private func scanDirectoryContents(_ path: String) throws -> [FolderItem] {
        var items: [FolderItem] = []
        
        let fileManager = FileManager.default
        let contents = try fileManager.contentsOfDirectory(atPath: path)
        
        for item in contents {
            let itemPath = path.hasSuffix("/") ? "\(path)\(item)" : "\(path)/\(item)"
            
            do {
                let attributes = try fileManager.attributesOfItem(atPath: itemPath)
                
                let size = (attributes[.size] as? Int64) ?? 0
                let isDirectory = (attributes[.type] as? FileAttributeType) == .typeDirectory
                let modificationDate = (attributes[.modificationDate] as? Date) ?? Date()
                
                // Skip if already seen (handle hard links)
                if let deviceId = attributes[.systemNumber] as? UInt32,
                   let inode = attributes[.systemFileNumber] as? UInt64 {
                    let devIno = DevIno(dev: deviceId, ino: inode)
                    if !globalSeenInodes.insert(devIno) {
                        continue // Skip duplicate
                    }
                }
                
                let folderItem = FolderItem(
                    name: item,
                    path: itemPath,
                    size: size,
                    isDirectory: isDirectory,
                    itemCount: isDirectory ? 1 : 0,
                    lastModified: modificationDate
                )
                
                items.append(folderItem)
                
            } catch {
                // Skip files we can't access
                continue
            }
        }
        
        return items.sorted()
    }
}
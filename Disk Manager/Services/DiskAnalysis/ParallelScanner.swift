import Foundation
import Darwin

// MARK: - Non-actor parallel scanner for maximum performance
// This does the heavy lifting outside actor isolation

final class ParallelScanner {

    // Thread-safe inode tracking using NSLock
    private let visitedInodesLock = NSLock()
    private var visitedInodes = Set<FileSystemID>()

    private let excludedPaths = Set([
        "/dev", "/net", "/home", "/private/var/vm", "/Volumes"
    ])

    private let firmlinkNames = Set([
        "Users", "Applications", "Library", "System", "private", "usr", "bin", "sbin", "opt", "Volumes", "cores"
    ])

    // Check if inode was visited (thread-safe)
    func checkAndMarkInode(_ fileID: FileSystemID) -> Bool {
        visitedInodesLock.lock()
        defer { visitedInodesLock.unlock() }

        if visitedInodes.contains(fileID) {
            return false // Already visited
        }
        visitedInodes.insert(fileID)
        return true // New inode
    }

    // Reset for new scan
    func reset() {
        visitedInodesLock.lock()
        defer { visitedInodesLock.unlock() }
        visitedInodes.removeAll()
    }

    // Parallel directory scan - runs OUTSIDE actor isolation
    func parallelScanDirectory(
        path: String,
        name: String,
        progressCallback: @escaping (Int64, String) async -> Void
    ) async -> HyperScanItem {

        // Fast path: Check permissions
        let fd = open(path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else {
            return HyperScanItem(name: name, path: path, size: 0, isDirectory: true, children: [])
        }

        var fileStat = stat()
        guard fstat(fd, &fileStat) == 0 else {
            close(fd)
            return HyperScanItem(name: name, path: path, size: 0, isDirectory: true, children: [])
        }
        close(fd)

        // Check if already visited
        let fileID = FileSystemID(device: fileStat.st_dev, inode: fileStat.st_ino)
        guard checkAndMarkInode(fileID) else {
            return HyperScanItem(name: name, path: path, size: 0, isDirectory: true, children: [])
        }

        // Check exclusions
        for excluded in excludedPaths {
            if path.hasPrefix(excluded) {
                return HyperScanItem(name: name, path: path, size: 0, isDirectory: true, children: [])
            }
        }

        // Scan directory contents
        return await scanDirectoryContents(path: path, name: name, progressCallback: progressCallback)
    }

    private func scanDirectoryContents(
        path: String,
        name: String,
        progressCallback: @escaping (Int64, String) async -> Void
    ) async -> HyperScanItem {

        var localItems = [HyperScanItem]()
        var localSize: Int64 = 0
        var subdirectories: [(path: String, name: String)] = []
        var directFilesSize: Int64 = 0

        // Read directory contents
        let fd = open(path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else {
            return HyperScanItem(name: name, path: path, size: 0, isDirectory: true, children: [])
        }
        defer { close(fd) }

        var dirStat = stat()
        _ = fstat(fd, &dirStat)
        let dirDevice = dirStat.st_dev

        // Use getattrlistbulk for fast enumeration
        var attrList = attrlist()
        attrList.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrList.commonattr = attrgroup_t(
            UInt32(ATTR_CMN_RETURNED_ATTRS) |
            UInt32(ATTR_CMN_NAME) |
            UInt32(ATTR_CMN_OBJTYPE) |
            UInt32(ATTR_CMN_FILEID)
        )
        attrList.fileattr = attrgroup_t(UInt32(ATTR_FILE_ALLOCSIZE))

        let bufferSize = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { buffer.deallocate() }

        while true {
            let count = getattrlistbulk(fd, &attrList, buffer, bufferSize, 0)
            if count <= 0 { break }

            var ptr = buffer
            for _ in 0..<count {
                let entry = parseAttributeBuffer(ptr: ptr, device: dirDevice)
                ptr = ptr.advanced(by: Int(entry.length))

                if entry.name == "." || entry.name == ".." { continue }

                let fullPath = path == "/" ? "/\(entry.name)" : "\(path)/\(entry.name)"

                // Skip firmlinks in /System/Volumes/Data
                if path == "/System/Volumes/Data" && firmlinkNames.contains(entry.name) { continue }
                if entry.name == "Volumes" && path == "/" { continue }

                if entry.isDirectory {
                    subdirectories.append((path: fullPath, name: entry.name))
                } else if let fileID = entry.fileID {
                    // Check hard links
                    if checkAndMarkInode(fileID) {
                        localItems.append(HyperScanItem(
                            name: entry.name,
                            path: fullPath,
                            size: entry.size,
                            isDirectory: false,
                            children: nil
                        ))
                        directFilesSize += entry.size
                    }
                }
            }
        }

        // Report progress
        await progressCallback(directFilesSize, path)

        // Scan subdirectories in parallel - NOT through actor!
        if !subdirectories.isEmpty {
            await withTaskGroup(of: HyperScanItem.self) { group in
                // Spawn ALL subdirectory scans immediately
                for (subPath, subName) in subdirectories {
                    group.addTask {
                        // Recursive parallel scan - NOT actor isolated!
                        await self.parallelScanDirectory(
                            path: subPath,
                            name: subName,
                            progressCallback: progressCallback
                        )
                    }
                }

                // Collect results
                for await result in group {
                    localItems.append(result)
                    localSize += result.size
                }
            }
        }

        localSize += directFilesSize
        return HyperScanItem(
            name: name,
            path: path,
            size: localSize,
            isDirectory: true,
            children: localItems.sorted { $0.size > $1.size }
        )
    }

    private func parseAttributeBuffer(ptr: UnsafeMutableRawPointer, device: dev_t) -> (
        length: UInt32,
        name: String,
        isDirectory: Bool,
        size: Int64,
        fileID: FileSystemID?
    ) {
        let length = ptr.load(as: UInt32.self)
        var currentOffset = 4

        let returnedCommon = ptr.load(fromByteOffset: currentOffset, as: UInt32.self)
        let returnedFile = ptr.load(fromByteOffset: currentOffset + 12, as: UInt32.self)
        currentOffset += 20

        var name = "unknown"
        if (returnedCommon & UInt32(ATTR_CMN_NAME)) != 0 {
            let nameRefPtr = ptr.advanced(by: currentOffset)
            let nameRef = nameRefPtr.load(as: attrreference_t.self)
            currentOffset += 8

            let nameDataPtr = nameRefPtr.advanced(by: Int(nameRef.attr_dataoffset))
            let nameLen = Int(nameRef.attr_length) - 1

            if nameLen > 0 {
                let nameData = Data(bytes: nameDataPtr, count: nameLen)
                name = String(data: nameData, encoding: .utf8) ?? "unknown"
            }
        }

        var isDirectory = false
        if (returnedCommon & UInt32(ATTR_CMN_OBJTYPE)) != 0 {
            let objType = ptr.load(fromByteOffset: currentOffset, as: UInt32.self)
            currentOffset += 4
            isDirectory = (objType == 2)
        }

        var fileID: FileSystemID? = nil
        if (returnedCommon & UInt32(ATTR_CMN_FILEID)) != 0 {
            var inode: UInt64 = 0
            withUnsafeMutableBytes(of: &inode) { inodeBuf in
                let srcPtr = ptr.advanced(by: currentOffset)
                inodeBuf.baseAddress?.copyMemory(from: srcPtr, byteCount: 8)
            }
            currentOffset += 8
            fileID = FileSystemID(device: device, inode: inode)
        }

        var size: Int64 = 0
        if !isDirectory && (returnedFile & UInt32(ATTR_FILE_ALLOCSIZE)) != 0 {
            if currentOffset + 8 <= Int(length) {
                var rawSize: Int64 = 0
                withUnsafeMutableBytes(of: &rawSize) { sizeBuf in
                    let srcPtr = ptr.advanced(by: currentOffset)
                    sizeBuf.baseAddress?.copyMemory(from: srcPtr, byteCount: 8)
                }
                if rawSize > 0 && rawSize < 1_000_000_000_000_000 {
                    size = rawSize
                }
            }
        }

        return (length, name, isDirectory, size, fileID)
    }
}
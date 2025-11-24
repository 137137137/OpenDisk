import Foundation
import Darwin
import os.lock

// MARK: - Thread-Safe Context with OSAllocatedUnfairLock (Ultra-fast)
final class HPScanContext: @unchecked Sendable {
    // OSAllocatedUnfairLock is extremely low overhead compared to Actors
    private let lock: OSAllocatedUnfairLock<State>

    struct State {
        var visitedInodes: Set<FileSystemID> = []
        var scannedBytes: Int64 = 0
        var itemsScanned: Int = 0
        var totalUsedBytes: Int64 = 0
    }

    init() {
        self.lock = OSAllocatedUnfairLock(initialState: State())
    }

    // Batching updates to reduce lock contention
    @inline(__always)
    func addProgress(bytes: Int64, items: Int) {
        lock.withLock { state in
            state.scannedBytes += bytes
            state.itemsScanned += items
        }
    }

    // Thread-safe check and insert for hardlinks
    // Returns true if inserted (first visit), false if already existed
    @inline(__always)
    func visit(inode: FileSystemID) -> Bool {
        lock.withLock { state in
            let (inserted, _) = state.visitedInodes.insert(inode)
            return inserted
        }
    }

    // Set total bytes
    func setTotalBytes(_ bytes: Int64) {
        lock.withLock { state in
            state.totalUsedBytes = bytes
        }
    }

    // Snapshot for the UI update
    func getProgress(currentPath: String) -> HyperScanProgress {
        lock.withLock { state in
            HyperScanProgress(
                scannedBytes: state.scannedBytes,
                totalUsedBytes: state.totalUsedBytes,
                currentPath: currentPath,
                itemsScanned: state.itemsScanned
            )
        }
    }

    // Reset for new scan
    func reset() {
        lock.withLock { state in
            state.visitedInodes.removeAll()
            state.scannedBytes = 0
            state.itemsScanned = 0
        }
    }
}

// MARK: - High-Performance Scan Engine (Non-Actor!)
final class HighPerformanceScanEngine {
    private let context: HPScanContext
    private let onProgress: ((HyperScanProgress) -> Void)?

    // Configuration
    private let bufferSize = 64 * 1024 // 64KB is optimal for getattrlistbulk
    private let excludedPaths = Set([
        "/dev", "/net", "/home", "/private/var/vm", "/Volumes"
    ])
    private let firmlinkNames = Set([
        "Users", "Applications", "Library", "System", "private", "usr", "bin", "sbin", "opt", "Volumes", "cores"
    ])

    init(context: HPScanContext, onProgress: ((HyperScanProgress) -> Void)? = nil) {
        self.context = context
        self.onProgress = onProgress
    }

    func scan(path: String, name: String, parentDevice: dev_t? = nil) async -> HyperScanItem {
        // Check exclusions
        for excluded in excludedPaths {
            if path == excluded || path.hasPrefix(excluded + "/") {
                return HyperScanItem(name: name, path: path, size: 0, isDirectory: true, children: [])
            }
        }

        // 1. Open File Descriptor
        let fd = open(path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else {
            // Fallback to FileManager for permission issues
            if errno == EACCES || errno == EPERM {
                return await scanWithFileManager(path: path, name: name)
            }
            return HyperScanItem(name: name, path: path, size: 0, isDirectory: true, children: [])
        }

        // 2. Prepare Attributes
        var attrList = attrlist()
        attrList.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrList.commonattr = attrgroup_t(
            UInt32(ATTR_CMN_RETURNED_ATTRS) |
            UInt32(ATTR_CMN_NAME) |
            UInt32(ATTR_CMN_OBJTYPE) |
            UInt32(ATTR_CMN_FILEID)
        )
        attrList.fileattr = attrgroup_t(UInt32(ATTR_FILE_ALLOCSIZE)) // Sparse file support

        // 3. Manual Memory Management (Fastest)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer {
            buffer.deallocate()
            close(fd) // Close immediately after reading
        }

        var localItems = [HyperScanItem]()
        var localSize: Int64 = 0
        var directFilesSize: Int64 = 0
        var subDirsToScan: [(path: String, name: String)] = []

        // V23: Use parent device if provided, else get it once
        let device: dev_t
        if let parentDev = parentDevice {
            device = parentDev
        } else {
            var dirStat = stat()
            fstat(fd, &dirStat)
            device = dirStat.st_dev
        }

        let isDataVolumeRoot = (path == "/System/Volumes/Data")

        // 4. Bulk Iteration Loop
        while true {
            let count = getattrlistbulk(fd, &attrList, buffer, bufferSize, 0)
            if count <= 0 { break }

            var ptr = buffer
            for _ in 0..<count {
                let entry = parseBuffer(ptr: ptr, device: device)
                ptr = ptr.advanced(by: Int(entry.length))

                if entry.name == "." || entry.name == ".." { continue }

                // Firmlink & Volume Handling
                if isDataVolumeRoot && firmlinkNames.contains(entry.name) { continue }
                if entry.name == "Volumes" && path == "/" { continue }

                let fullPath = path == "/" ? "/\(entry.name)" : "\(path)/\(entry.name)"

                if entry.isDirectory {
                    subDirsToScan.append((fullPath, entry.name))
                } else {
                    // Hardlink Deduplication Logic
                    var itemSize = entry.size
                    if let fileID = entry.fileID {
                        // ATOMIC CHECK - No Actor Hop!
                        if !context.visit(inode: fileID) {
                            itemSize = 0 // Seen before, count as 0 bytes
                        }
                    }

                    localItems.append(HyperScanItem(
                        name: entry.name,
                        path: fullPath,
                        size: itemSize,
                        isDirectory: false,
                        children: nil
                    ))
                    if itemSize > 0 {
                        localSize += itemSize
                        directFilesSize += itemSize
                    }
                }
            }
        }

        // 5. Batched Progress Update (Reduces overhead)
        if directFilesSize > 0 || localItems.count > 0 {
            context.addProgress(bytes: directFilesSize, items: localItems.count)
        }

        // 6. Recursive Parallelism - ALL tasks run in parallel!
        if !subDirsToScan.isEmpty {
            await withTaskGroup(of: HyperScanItem.self) { group in
                for (subPath, subName) in subDirsToScan {
                    group.addTask(priority: .high) {
                        // V23: Pass device down to avoid repeated fstat calls
                        return await self.scan(path: subPath, name: subName, parentDevice: device)
                    }
                }

                for await item in group {
                    localItems.append(item)
                    localSize += item.size
                }
            }
        }

        return HyperScanItem(
            name: name,
            path: path,
            size: localSize,
            isDirectory: true,
            children: localItems        )
    }

    // Special root scan
    func scanRoot() async -> HyperScanItem {
        var rootChildren: [HyperScanItem] = []
        var totalSize: Int64 = 0

        // Get root directory listing
        guard let allRootContents = try? FileManager.default.contentsOfDirectory(atPath: "/") else {
            return HyperScanItem(name: "/", path: "/", size: 0, isDirectory: true, children: [])
        }

        let skipPaths = Set(["Volumes", ".VolumeIcon.icns", ".file"])
        var directoriesToScan: [(name: String, path: String)] = []

        // V23: Get root device once
        var rootStat = stat()
        stat("/", &rootStat)
        let rootDevice = rootStat.st_dev

        for itemName in allRootContents {
            if skipPaths.contains(itemName) { continue }

            let fullPath = "/\(itemName)"
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue {
                directoriesToScan.append((name: itemName, path: fullPath))
            }
        }

        // Scan ALL root directories in parallel
        await withTaskGroup(of: HyperScanItem.self) { group in
            for (name, path) in directoriesToScan {
                group.addTask(priority: .userInitiated) {
                    // Special handling for /System
                    if name == "System" {
                        return await self.scanSystemWithoutData()
                    } else {
                        // V23: Pass root device down
                        return await self.scan(path: path, name: name, parentDevice: rootDevice)
                    }
                }
            }

            for await item in group {
                if item.size > 0 {
                    rootChildren.append(item)
                    totalSize += item.size
                }
            }
        }

        return HyperScanItem(
            name: "/",
            path: "/",
            size: totalSize,
            isDirectory: true,
            children: rootChildren        )
    }

    // Special handler for /System to avoid /System/Volumes/Data
    private func scanSystemWithoutData() async -> HyperScanItem {
        var systemChildren: [HyperScanItem] = []
        var totalSize: Int64 = 0

        guard let systemContents = try? FileManager.default.contentsOfDirectory(atPath: "/System") else {
            return HyperScanItem(name: "System", path: "/System", size: 0, isDirectory: true, children: [])
        }

        // V23: Get device once for /System
        var rootStat = stat()
        stat("/System", &rootStat)
        let rootDevice = rootStat.st_dev

        await withTaskGroup(of: HyperScanItem.self) { group in
            for itemName in systemContents {
                let fullPath = "/System/\(itemName)"

                if itemName == "Volumes" {
                    // Special handling for /System/Volumes - skip Data
                    group.addTask(priority: .high) {
                        var volumesChildren: [HyperScanItem] = []
                        var volumesSize: Int64 = 0

                        if let volumeContents = try? FileManager.default.contentsOfDirectory(atPath: fullPath) {
                            await withTaskGroup(of: HyperScanItem?.self) { volumeGroup in
                                for volumeName in volumeContents {
                                    if volumeName == "Data" { continue } // Skip Data

                                    let volumePath = "\(fullPath)/\(volumeName)"
                                    volumeGroup.addTask(priority: .high) {
                                        // V23: Pass device down
                                        return await self.scan(path: volumePath, name: volumeName, parentDevice: rootDevice)
                                    }
                                }

                                for await result in volumeGroup {
                                    if let item = result {
                                        volumesChildren.append(item)
                                        volumesSize += item.size
                                    }
                                }
                            }
                        }

                        return HyperScanItem(
                            name: "Volumes",
                            path: fullPath,
                            size: volumesSize,
                            isDirectory: true,
                            children: volumesChildren                        )
                    }
                } else {
                    group.addTask(priority: .high) {
                        // V23: Pass device down
                        return await self.scan(path: fullPath, name: itemName, parentDevice: rootDevice)
                    }
                }
            }

            for await item in group {
                systemChildren.append(item)
                totalSize += item.size
            }
        }

        return HyperScanItem(
            name: "System",
            path: "/System",
            size: totalSize,
            isDirectory: true,
            children: systemChildren        )
    }

    // Optimized buffer parser - Inline capable
    @inline(__always)
    private func parseBuffer(ptr: UnsafeMutableRawPointer, device: dev_t) -> (
        length: UInt32,
        name: String,
        isDirectory: Bool,
        size: Int64,
        fileID: FileSystemID?
    ) {
        // IMPORTANT: Use memcpy for safe unaligned access from getattrlistbulk
        var length: UInt32 = 0
        memcpy(&length, ptr, MemoryLayout<UInt32>.size)

        var currentOffset = 4

        var returnedCommon: UInt32 = 0
        var returnedFile: UInt32 = 0
        memcpy(&returnedCommon, ptr.advanced(by: currentOffset), MemoryLayout<UInt32>.size)
        memcpy(&returnedFile, ptr.advanced(by: currentOffset + 12), MemoryLayout<UInt32>.size)
        currentOffset += 20

        // Name
        var name = "unknown"
        if (returnedCommon & UInt32(ATTR_CMN_NAME)) != 0 {
            var nameRef = attrreference_t()
            memcpy(&nameRef, ptr.advanced(by: currentOffset), MemoryLayout<attrreference_t>.size)
            currentOffset += 8

            let nameDataPtr = ptr.advanced(by: currentOffset - 8).advanced(by: Int(nameRef.attr_dataoffset))
            let nameLen = Int(nameRef.attr_length) - 1

            if nameLen > 0 && nameLen < 1024 { // Sanity check
                // Direct decoding from buffer without Data allocation
                name = String(decoding: UnsafeRawBufferPointer(start: nameDataPtr, count: nameLen), as: UTF8.self)
            }
        }

        // Type
        var isDirectory = false
        if (returnedCommon & UInt32(ATTR_CMN_OBJTYPE)) != 0 {
            var objType: UInt32 = 0
            memcpy(&objType, ptr.advanced(by: currentOffset), MemoryLayout<UInt32>.size)
            currentOffset += 4
            isDirectory = (objType == 2) // VDIR
        }

        // FileID (Inode)
        var fileID: FileSystemID?
        if (returnedCommon & UInt32(ATTR_CMN_FILEID)) != 0 {
            var inode: UInt64 = 0
            memcpy(&inode, ptr.advanced(by: currentOffset), MemoryLayout<UInt64>.size)
            currentOffset += 8
            fileID = FileSystemID(device: device, inode: inode)
        }

        // Size (only for files)
        var size: Int64 = 0
        if !isDirectory && (returnedFile & UInt32(ATTR_FILE_ALLOCSIZE)) != 0 {
            if currentOffset + 8 <= Int(length) {
                memcpy(&size, ptr.advanced(by: currentOffset), MemoryLayout<Int64>.size)
                // Sanity check
                if size < 0 || size > 1_000_000_000_000_000 {
                    size = 0
                }
            }
        }

        return (length, name, isDirectory, size, fileID)
    }

    // FileManager fallback for permission-denied directories
    private func scanWithFileManager(path: String, name: String) async -> HyperScanItem {
        var localItems: [HyperScanItem] = []
        var localSize: Int64 = 0

        do {
            let contents = try FileManager.default.contentsOfDirectory(atPath: path)
            var subDirs: [(String, String)] = []

            for itemName in contents {
                if itemName.hasPrefix(".") { continue }

                let fullPath = path == "/" ? "/\(itemName)" : "\(path)/\(itemName)"

                // Skip firmlinks
                if path == "/System/Volumes/Data" && firmlinkNames.contains(itemName) { continue }
                if itemName == "Volumes" && path == "/" { continue }

                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir) {
                    if isDir.boolValue {
                        subDirs.append((fullPath, itemName))
                    } else {
                        // Get file size
                        if let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath) {
                            let allocSize: Int64
                            if let allocSizeNum = attrs[FileAttributeKey(rawValue: "NSFileAllocatedSize")] as? NSNumber {
                                allocSize = allocSizeNum.int64Value
                            } else if let size = attrs[.size] as? Int64 {
                                allocSize = size
                            } else {
                                allocSize = 0
                            }

                            if allocSize > 0 {
                                // Check for hard links
                                var fileStat = stat()
                                if stat(fullPath, &fileStat) == 0 {
                                    let fileID = FileSystemID(device: fileStat.st_dev, inode: fileStat.st_ino)
                                    if context.visit(inode: fileID) {
                                        localItems.append(HyperScanItem(
                                            name: itemName,
                                            path: fullPath,
                                            size: allocSize,
                                            isDirectory: false,
                                            children: nil
                                        ))
                                        localSize += allocSize
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // Report progress
            if localSize > 0 {
                context.addProgress(bytes: localSize, items: localItems.count)
            }

            // Recurse into subdirectories
            if !subDirs.isEmpty {
                await withTaskGroup(of: HyperScanItem.self) { group in
                    for (subPath, subName) in subDirs {
                        group.addTask(priority: .high) {
                            // V23: Pass nil for device since FileManager fallback doesn't have it
                            return await self.scan(path: subPath, name: subName, parentDevice: nil)
                        }
                    }

                    for await child in group {
                        localItems.append(child)
                        localSize += child.size
                    }
                }
            }
        } catch {
            // Directory not accessible
        }

        return HyperScanItem(
            name: name,
            path: path,
            size: localSize,
            isDirectory: true,
            children: localItems        )
    }
}
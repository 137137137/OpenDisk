import Foundation
import Darwin
import os.lock

// MARK: - V26: Sharded Inode Tracker (Zero-Contention)
/// Replaces the single lock with a striped locking strategy to allow
/// dozens of threads to check hardlinks simultaneously without blocking each other.
final class ShardedInodeTracker: @unchecked Sendable {
    private let shardCount = 64 // Power of 2 for bitwise masking
    private let mask: Int
    private let locks: UnsafeMutableBufferPointer<os_unfair_lock>
    private var sets: [Set<UInt64>]

    init() {
        self.mask = shardCount - 1

        // Allocate raw locks for maximum speed
        let buffer = UnsafeMutableBufferPointer<os_unfair_lock>.allocate(capacity: shardCount)
        buffer.initialize(repeating: os_unfair_lock())
        self.locks = buffer

        // Initialize sets with capacity
        self.sets = (0..<shardCount).map { _ in Set<UInt64>(minimumCapacity: 1024) }
    }

    deinit {
        locks.deallocate()
    }

    /// Returns true if this is a NEW inode (first visit), false if already seen
    @inline(__always)
    func visit(inode: UInt64) -> Bool {
        // Fast bitwise hash for shard selection
        let shardIndex = Int(inode) & mask

        os_unfair_lock_lock(locks.baseAddress! + shardIndex)
        let (inserted, _) = sets[shardIndex].insert(inode)
        os_unfair_lock_unlock(locks.baseAddress! + shardIndex)

        return inserted
    }

    /// Check AND insert with device+inode combo (for cross-device hardlink safety)
    @inline(__always)
    func visit(device: dev_t, inode: ino_t) -> Bool {
        // Combine device and inode into single UInt64 for sharding
        // Use XOR to mix bits for better distribution
        let combined = UInt64(device) ^ UInt64(inode)
        let shardIndex = Int(combined) & mask

        // Store the full inode (device is implicit in the shard distribution)
        let key = (UInt64(device) << 32) | UInt64(inode)

        os_unfair_lock_lock(locks.baseAddress! + shardIndex)
        let (inserted, _) = sets[shardIndex].insert(key)
        os_unfair_lock_unlock(locks.baseAddress! + shardIndex)

        return inserted
    }

    func reset() {
        for i in 0..<shardCount {
            os_unfair_lock_lock(locks.baseAddress! + i)
            sets[i].removeAll(keepingCapacity: true)
            os_unfair_lock_unlock(locks.baseAddress! + i)
        }
    }
}

// MARK: - V26: Atomic Stats Accumulator
/// Lock-free statistics using atomic primitives with batched updates
final class AtomicScanStats: @unchecked Sendable {
    private let _scannedBytes = OSAllocatedUnfairLock(initialState: Int64(0))
    private let _itemsScanned = OSAllocatedUnfairLock(initialState: Int(0))
    private let _totalUsedBytes = OSAllocatedUnfairLock(initialState: Int64(0))

    @inline(__always)
    func add(bytes: Int64, items: Int) {
        // Batched updates reduce lock frequency
        if bytes > 0 { _scannedBytes.withLock { $0 += bytes } }
        if items > 0 { _itemsScanned.withLock { $0 += items } }
    }

    func setTotalBytes(_ bytes: Int64) {
        _totalUsedBytes.withLock { $0 = bytes }
    }

    func snapshot(path: String) -> HyperScanProgress {
        HyperScanProgress(
            scannedBytes: _scannedBytes.withLock { $0 },
            totalUsedBytes: _totalUsedBytes.withLock { $0 },
            currentPath: path,
            itemsScanned: _itemsScanned.withLock { $0 }
        )
    }

    func reset() {
        _scannedBytes.withLock { $0 = 0 }
        _itemsScanned.withLock { $0 = 0 }
    }
}

// MARK: - V26: Hyper Optimized Context
final class HPScanContext: @unchecked Sendable {
    let stats = AtomicScanStats()
    let inodeTracker = ShardedInodeTracker()

    // Convenience methods to match existing API
    @inline(__always)
    func addProgress(bytes: Int64, items: Int) {
        stats.add(bytes: bytes, items: items)
    }

    func setTotalBytes(_ bytes: Int64) {
        stats.setTotalBytes(bytes)
    }

    func getProgress(currentPath: String) -> HyperScanProgress {
        stats.snapshot(path: currentPath)
    }

    func reset() {
        stats.reset()
        inodeTracker.reset()
    }

    /// Check if inode is new (first visit). Returns true if new, false if seen before.
    @inline(__always)
    func visit(inode: FileSystemID) -> Bool {
        return inodeTracker.visit(device: inode.device, inode: inode.inode)
    }
}

// MARK: - V26: High-Performance Engine with Adaptive Parallelism
final class HighPerformanceScanEngine {
    private let context: HPScanContext
    private let onProgress: ((HyperScanProgress) -> Void)?

    // V26: Bump to 512KB for massive directory throughput
    private let bufferSize = 512 * 1024

    // V26: Adaptive parallelism thresholds
    private let maxParallelDepth = 6  // Stop spawning tasks after this depth
    private let minSubdirsForParallel = 4  // Minimum subdirs to justify parallel overhead

    // V26: Raw C-Strings for fast pointer comparison (No String Allocation)
    private let excludedPrefixes: [([UInt8], Int)]

    // Firmlink names for Data volume deduplication
    private let firmlinkNames = Set([
        "Users", "Applications", "Library", "System", "private", "usr", "bin", "sbin", "opt", "Volumes", "cores"
    ])

    // V26: Pre-computed byte sequences for fast dot-file checks
    private let dotByte: UInt8 = 46  // '.'

    init(context: HPScanContext, onProgress: ((HyperScanProgress) -> Void)? = nil) {
        self.context = context
        self.onProgress = onProgress

        // Pre-convert exclusions to UTF8 bytes for raw pointer comparison
        let exclusions = ["/dev", "/net", "/home", "/private/var/vm", "/Volumes", "/proc"]
        self.excludedPrefixes = exclusions.map {
            let data = Array($0.utf8)
            return (data, data.count)
        }
    }

    // MARK: - Entry Point
    func scan(path: String, name: String, parentDevice: dev_t? = nil) async -> HyperScanItem {
        // Get device if not provided
        let device: dev_t
        if let parentDev = parentDevice {
            device = parentDev
        } else {
            var dirStat = stat()
            stat(path, &dirStat)
            device = dirStat.st_dev
        }

        return await scanRecursive(path: path, name: name, device: device, depth: 0)
    }

    // MARK: - The Core Loop (Adaptive Hybrid Recursion)
    private func scanRecursive(path: String, name: String, device: dev_t, depth: Int) async -> HyperScanItem {

        // 1. RAW POINTER EXCLUSION CHECK (Zero Alloc at top levels)
        if depth < 3 {
            let pathBytes = Array(path.utf8)
            for (prefix, count) in excludedPrefixes {
                if pathBytes.count >= count && pathBytes.prefix(count).elementsEqual(prefix) {
                    return HyperScanItem(name: name, path: path, size: 0, isDirectory: true, children: [])
                }
            }
        }

        // 2. OPEN & FAST FAIL
        let fd = open(path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else {
            // Permission denied fallback (slow path)
            if errno == EACCES || errno == EPERM {
                return await scanWithFileManager(path: path, name: name, device: device, depth: depth)
            }
            return HyperScanItem(name: name, path: path, size: 0, isDirectory: true, children: [])
        }

        // 3. BUFFER SETUP - Use UnsafeMutableRawPointer directly
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer {
            buffer.deallocate()
            close(fd)
        }

        var attrList = attrlist()
        attrList.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrList.commonattr = attrgroup_t(
            UInt32(ATTR_CMN_RETURNED_ATTRS) |
            UInt32(ATTR_CMN_NAME) |
            UInt32(ATTR_CMN_OBJTYPE) |
            UInt32(ATTR_CMN_FILEID)
        )
        attrList.fileattr = attrgroup_t(UInt32(ATTR_FILE_ALLOCSIZE))

        var localItems = [HyperScanItem]()
        localItems.reserveCapacity(256)

        var localSize: Int64 = 0
        var batchSizeAdded: Int64 = 0
        var batchItemsAdded: Int = 0

        // Directories to recurse into
        var subDirs: [(name: String, path: String)] = []
        subDirs.reserveCapacity(64)

        let isDataVolumeRoot = (path == "/System/Volumes/Data")
        let isRoot = (path == "/")

        // 4. THE HOT LOOP
        while true {
            let count = getattrlistbulk(fd, &attrList, buffer, bufferSize, 0)
            if count <= 0 { break }

            var ptr = buffer
            for _ in 0..<count {
                // Inline parsing logic to avoid function call overhead
                var length: UInt32 = 0
                memcpy(&length, ptr, 4)

                var currentOffset = 4
                var returnedCommon: UInt32 = 0
                var returnedFile: UInt32 = 0
                memcpy(&returnedCommon, ptr.advanced(by: currentOffset), 4)
                memcpy(&returnedFile, ptr.advanced(by: currentOffset + 12), 4)
                currentOffset += 20

                // --- Name Parsing ---
                var nameRef = attrreference_t()
                memcpy(&nameRef, ptr.advanced(by: currentOffset), 8)
                currentOffset += 8

                let nameLen = Int(nameRef.attr_length) - 1
                let namePtr = ptr.advanced(by: currentOffset - 8 + Int(nameRef.attr_dataoffset))

                // FAST SKIP: "." and ".." using raw byte check
                if nameLen > 0 {
                    let firstByte = namePtr.load(as: UInt8.self)
                    if firstByte == dotByte {
                        if nameLen == 1 {
                            ptr = ptr.advanced(by: Int(length))
                            continue
                        }
                        if nameLen == 2 && namePtr.advanced(by: 1).load(as: UInt8.self) == dotByte {
                            ptr = ptr.advanced(by: Int(length))
                            continue
                        }
                    }
                }

                // Now decode the name (we need it for the path)
                let itemName: String
                if nameLen > 0 && nameLen < 1024 {
                    itemName = String(decoding: UnsafeRawBufferPointer(start: namePtr, count: nameLen), as: UTF8.self)
                } else {
                    ptr = ptr.advanced(by: Int(length))
                    continue
                }

                // --- Type Parsing ---
                var isDirectory = false
                if (returnedCommon & UInt32(ATTR_CMN_OBJTYPE)) != 0 {
                    var objType: UInt32 = 0
                    memcpy(&objType, ptr.advanced(by: currentOffset), 4)
                    currentOffset += 4
                    isDirectory = (objType == 2) // VDIR
                }

                // --- Inode Parsing ---
                var inode: UInt64 = 0
                if (returnedCommon & UInt32(ATTR_CMN_FILEID)) != 0 {
                    memcpy(&inode, ptr.advanced(by: currentOffset), 8)
                    currentOffset += 8
                }

                // --- Size Parsing ---
                var size: Int64 = 0
                if !isDirectory && (returnedFile & UInt32(ATTR_FILE_ALLOCSIZE)) != 0 {
                    if currentOffset + 8 <= Int(length) {
                        memcpy(&size, ptr.advanced(by: currentOffset), 8)
                        // Sanity check
                        if size < 0 || size > 1_000_000_000_000_000 {
                            size = 0
                        }
                    }
                }

                // --- Processing ---
                let itemPath = isRoot ? "/\(itemName)" : "\(path)/\(itemName)"

                // Firmlink & Volume Handling
                if isDataVolumeRoot && firmlinkNames.contains(itemName) {
                    ptr = ptr.advanced(by: Int(length))
                    continue
                }
                if isRoot && itemName == "Volumes" {
                    ptr = ptr.advanced(by: Int(length))
                    continue
                }

                if isDirectory {
                    // Skip /System/Volumes/Data if we are scanning /System/Volumes
                    if !(path == "/System/Volumes" && itemName == "Data") {
                        subDirs.append((itemName, itemPath))
                    }
                } else {
                    // Hardlink Dedup: Check Sharded Tracker
                    if inode > 0 {
                        if !context.inodeTracker.visit(device: device, inode: inode) {
                            size = 0 // Seen this inode before, size is 0
                        }
                    }

                    localSize += size
                    batchSizeAdded += size
                    batchItemsAdded += 1

                    localItems.append(HyperScanItem(
                        name: itemName,
                        path: itemPath,
                        size: size,
                        isDirectory: false,
                        children: nil
                    ))
                }

                // Advance buffer
                ptr = ptr.advanced(by: Int(length))
            }
        }

        // Update stats in batches (Lock reduction)
        if batchSizeAdded > 0 || batchItemsAdded > 0 {
            context.stats.add(bytes: batchSizeAdded, items: batchItemsAdded)
        }

        // 5. ADAPTIVE PARALLELISM (The Speed Secret)
        // If we have very few subdirectories, OR we are very deep in the tree,
        // do NOT spawn a new Task. Run synchronously on the current thread.
        if !subDirs.isEmpty {
            let nextDepth = depth + 1

            // Heuristic: If < 4 subdirs, or depth > 6, run serial/inline.
            if subDirs.count < minSubdirsForParallel || depth > maxParallelDepth {
                // SERIAL EXECUTION (Fast Path for Leaves)
                for (subName, subPath) in subDirs {
                    let item = await scanRecursive(path: subPath, name: subName, device: device, depth: nextDepth)
                    localItems.append(item)
                    localSize += item.size
                }
            } else {
                // PARALLEL EXECUTION (Wide Path for Trunk)
                await withTaskGroup(of: HyperScanItem.self) { group in
                    for (subName, subPath) in subDirs {
                        group.addTask {
                            return await self.scanRecursive(path: subPath, name: subName, device: device, depth: nextDepth)
                        }
                    }

                    for await item in group {
                        localItems.append(item)
                        localSize += item.size
                    }
                }
            }
        }

        return HyperScanItem(name: name, path: path, size: localSize, isDirectory: true, children: localItems)
    }

    // MARK: - Special Root Scan
    func scanRoot() async -> HyperScanItem {
        var rootChildren: [HyperScanItem] = []
        var totalSize: Int64 = 0

        guard let allRootContents = try? FileManager.default.contentsOfDirectory(atPath: "/") else {
            return HyperScanItem(name: "/", path: "/", size: 0, isDirectory: true, children: [])
        }

        let skipPaths = Set(["Volumes", ".VolumeIcon.icns", ".file"])
        var directoriesToScan: [(name: String, path: String)] = []

        // Get root device once
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

        // Scan ALL root directories in parallel (root level always parallel)
        await withTaskGroup(of: HyperScanItem.self) { group in
            for (name, path) in directoriesToScan {
                group.addTask(priority: .userInitiated) {
                    if name == "System" {
                        return await self.scanSystemWithoutData(device: rootDevice)
                    } else {
                        return await self.scanRecursive(path: path, name: name, device: rootDevice, depth: 0)
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

        return HyperScanItem(name: "/", path: "/", size: totalSize, isDirectory: true, children: rootChildren)
    }

    // MARK: - Special /System Handler
    private func scanSystemWithoutData(device: dev_t) async -> HyperScanItem {
        var systemChildren: [HyperScanItem] = []
        var totalSize: Int64 = 0

        guard let systemContents = try? FileManager.default.contentsOfDirectory(atPath: "/System") else {
            return HyperScanItem(name: "System", path: "/System", size: 0, isDirectory: true, children: [])
        }

        await withTaskGroup(of: HyperScanItem.self) { group in
            for itemName in systemContents {
                let fullPath = "/System/\(itemName)"

                if itemName == "Volumes" {
                    // Special handling for /System/Volumes - skip Data
                    group.addTask(priority: .high) {
                        var volumesChildren: [HyperScanItem] = []
                        var volumesSize: Int64 = 0

                        if let volumeContents = try? FileManager.default.contentsOfDirectory(atPath: fullPath) {
                            // Process volumes serially (usually only a few)
                            for volumeName in volumeContents {
                                if volumeName == "Data" { continue }

                                let volumePath = "\(fullPath)/\(volumeName)"
                                let item = await self.scanRecursive(path: volumePath, name: volumeName, device: device, depth: 1)
                                volumesChildren.append(item)
                                volumesSize += item.size
                            }
                        }

                        return HyperScanItem(
                            name: "Volumes",
                            path: fullPath,
                            size: volumesSize,
                            isDirectory: true,
                            children: volumesChildren
                        )
                    }
                } else {
                    group.addTask(priority: .high) {
                        return await self.scanRecursive(path: fullPath, name: itemName, device: device, depth: 1)
                    }
                }
            }

            for await item in group {
                systemChildren.append(item)
                totalSize += item.size
            }
        }

        return HyperScanItem(name: "System", path: "/System", size: totalSize, isDirectory: true, children: systemChildren)
    }

    // MARK: - FileManager Fallback
    private func scanWithFileManager(path: String, name: String, device: dev_t, depth: Int) async -> HyperScanItem {
        var localItems: [HyperScanItem] = []
        var localSize: Int64 = 0

        do {
            let contents = try FileManager.default.contentsOfDirectory(atPath: path)
            var subDirs: [(String, String)] = []

            let isDataVolumeRoot = (path == "/System/Volumes/Data")
            let isRoot = (path == "/")

            for itemName in contents {
                if itemName.hasPrefix(".") { continue }

                let fullPath = isRoot ? "/\(itemName)" : "\(path)/\(itemName)"

                // Skip firmlinks
                if isDataVolumeRoot && firmlinkNames.contains(itemName) { continue }
                if isRoot && itemName == "Volumes" { continue }

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
                                // Check for hard links using sharded tracker
                                var fileStat = stat()
                                if stat(fullPath, &fileStat) == 0 {
                                    if context.inodeTracker.visit(device: fileStat.st_dev, inode: fileStat.st_ino) {
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
                context.stats.add(bytes: localSize, items: localItems.count)
            }

            // Recurse into subdirectories using adaptive parallelism
            if !subDirs.isEmpty {
                let nextDepth = depth + 1

                if subDirs.count < minSubdirsForParallel || depth > maxParallelDepth {
                    // Serial for small/deep
                    for (subPath, subName) in subDirs {
                        let item = await scanRecursive(path: subPath, name: subName, device: device, depth: nextDepth)
                        localItems.append(item)
                        localSize += item.size
                    }
                } else {
                    // Parallel for wide
                    await withTaskGroup(of: HyperScanItem.self) { group in
                        for (subPath, subName) in subDirs {
                            group.addTask {
                                return await self.scanRecursive(path: subPath, name: subName, device: device, depth: nextDepth)
                            }
                        }

                        for await child in group {
                            localItems.append(child)
                            localSize += child.size
                        }
                    }
                }
            }
        } catch {
            // Directory not accessible
        }

        return HyperScanItem(name: name, path: path, size: localSize, isDirectory: true, children: localItems)
    }
}

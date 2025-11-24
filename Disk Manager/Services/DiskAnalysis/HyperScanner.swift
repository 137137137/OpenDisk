import Foundation
import Darwin
import Dispatch

// MARK: - Models

struct HyperScanItem: Identifiable, Sendable {
    // V23: Use path hash as ID to avoid expensive UUID generation
    var id: Int { path.hashValue }
    let name: String
    let path: String
    let size: Int64
    let isDirectory: Bool
    var children: [HyperScanItem]?

    // V24: Fast synchronous conversion for immediate display
    func toFolderItem() -> FolderItem {
        let sharedDate = Date()
        return toFolderItemFast(sharedDate: sharedDate)
    }

    private func toFolderItemFast(sharedDate: Date) -> FolderItem {
        var item = FolderItem(
            name: name,
            path: path,
            size: size,
            isDirectory: isDirectory,
            itemCount: children?.count ?? 1,
            lastModified: sharedDate
        )

        // Only sort and show top-level items (what's immediately visible)
        // Deep conversion happens when user navigates
        if let children = children, !children.isEmpty {
            // Take only top 100 items for immediate display
            let topItems = children.prefix(100)

            // Quick sort of just the visible items
            let sortedTop = topItems.sorted { $0.size > $1.size }

            // Convert only these top items
            item.children = sortedTop.map { child in
                FolderItem(
                    name: child.name,
                    path: child.path,
                    size: child.size,
                    isDirectory: child.isDirectory,
                    itemCount: child.children?.count ?? 1,
                    lastModified: sharedDate,
                    children: [] // Empty for now - will be loaded on demand
                )
            }
        }

        return item
    }

    // V24: Parallel async conversion for background processing
    static func toFolderItemAsync(_ item: HyperScanItem) async -> FolderItem {
        let sharedDate = Date()

        // Process in parallel using TaskGroup
        return await withTaskGroup(of: FolderItem.self) { group in
            var result = FolderItem(
                name: item.name,
                path: item.path,
                size: item.size,
                isDirectory: item.isDirectory,
                itemCount: item.children?.count ?? 1,
                lastModified: sharedDate
            )

            if let children = item.children {
                // Sort once
                let sortedChildren = children.sorted { $0.size > $1.size }

                // Process top-level children in parallel
                for child in sortedChildren.prefix(50) {  // Process first 50 in parallel
                    group.addTask {
                        child.toFolderItemFast(sharedDate: sharedDate)
                    }
                }

                // Collect results
                var convertedChildren: [FolderItem] = []
                for await folderItem in group {
                    convertedChildren.append(folderItem)
                }

                // Add remaining items as placeholders
                if sortedChildren.count > 50 {
                    for child in sortedChildren.dropFirst(50) {
                        convertedChildren.append(FolderItem(
                            name: child.name,
                            path: child.path,
                            size: child.size,
                            isDirectory: child.isDirectory,
                            itemCount: child.children?.count ?? 1,
                            lastModified: sharedDate,
                            children: []
                        ))
                    }
                }

                result.children = convertedChildren
            }

            return result
        }
    }
}

struct HyperScanProgress: Sendable {
    let scannedBytes: Int64
    let totalUsedBytes: Int64
    let currentPath: String
    let itemsScanned: Int

    var fractionCompleted: Double {
        guard totalUsedBytes > 0 else { return 0 }
        return min(Double(scannedBytes) / Double(totalUsedBytes), 1.0)
    }
}

// MARK: - Core Engine

struct FileSystemID: Hashable {
    let device: dev_t
    let inode: ino_t
}

actor HyperScanner {
    private var scannedBytes: Int64 = 0
    private var totalUsedBytes: Int64 = 0
    private var itemsScanned: Int = 0
    private var onProgress: ((HyperScanProgress) -> Void)?

    // Timing & State
    private var startTime = Date()
    private var lastProgressUpdate = Date()
    private var lastConsolePrint = Date()
    private var startPath: String = ""

    // V20: Use non-actor ParallelScanner for true parallelization
    private let parallelScanner = ParallelScanner()

    // Cycle Detection (kept for compatibility, but real work done in ParallelScanner)
    private var visitedInodes: Set<FileSystemID> = []

    // Config
    private let bufferSize = 256 * 1024
    private let progressUpdateInterval: TimeInterval = 0.1
    private let consolePrintInterval: TimeInterval = 0.5

    // V20: Aggressive Multi-Core Parallelization (like DaisyDisk)
    private var maxConcurrencyLimit = 128 // Start high, we'll optimize based on cores
    private let cpuCoreCount = ProcessInfo.processInfo.activeProcessorCount
    private let optimalConcurrency: Int // Calculated based on cores
    
    // Global exclusions
    private let excludedPathPrefixes: [String] = [
        "/dev", 
        "/net", 
        "/home", 
        "/private/var/vm",
        "/Volumes"
    ]
    
    // Firmlink Deduplication
    private let firmlinkNames: Set<String> = [
        "Users", "Applications", "Library", "System", "private", "usr", "bin", "sbin", "opt", "Volumes", "cores"
    ]

    init() {
        // Match DaisyDisk's aggressive parallelization
        // Use ALL CPU cores for maximum performance
        // FileIDTreeGetVRefNumForDevice errors are warnings, not failures
        self.optimalConcurrency = cpuCoreCount * 8  // 8 threads per core for I/O bound work
        self.maxConcurrencyLimit = max(128, optimalConcurrency)  // At least 128 threads

        // Set environment variable for Swift runtime to use more threads
        setenv("LIBDISPATCH_WORKQUEUE_MAX_THREAD_COUNT", "0", 1)  // Unlimited threads
    }

    func scan(url: URL, onProgress: @escaping (HyperScanProgress) -> Void) async -> HyperScanItem {
        // V22: Ultimate performance with OSAllocatedUnfairLock
        optimizeSystemLimits()

        // Setup context
        let context = HPScanContext()
        context.setTotalBytes(getVolumeUsedSize(for: url))
        context.reset()

        // Create the ENGINE (Non-actor class for maximum parallelization)
        let engine = HighPerformanceScanEngine(context: context)

        // Start a UI update timer loop separately
        let progressTask = Task { [weak self] in
            let lastPath = ""
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
                let progress = context.getProgress(currentPath: lastPath)
                onProgress(progress)

                // Update internal state for compatibility
                await self?.updateInternalState(bytes: progress.scannedBytes, items: progress.itemsScanned)
            }
        }

        // Run the scan - this runs OFF the actor!
        let result: HyperScanItem
        if url.path == "/" {
            result = await engine.scanRoot()
        } else {
            // V23: Get initial device to pass down
            var statBuf = stat()
            stat(url.path, &statBuf)
            result = await engine.scan(path: url.path, name: url.lastPathComponent, parentDevice: statBuf.st_dev)
        }

        // Stop progress updates
        progressTask.cancel()

        // Final progress update
        let finalProgress = context.getProgress(currentPath: url.path)
        onProgress(finalProgress)

        return result
    }
    
    // V19: Maximize file descriptors and calculate CPU-optimized concurrency
    private func optimizeSystemLimits() {
        var rlimitData = rlimit()

        // Get current limits
        if getrlimit(RLIMIT_NOFILE, &rlimitData) == 0 {
            let currentSoft = rlimitData.rlim_cur
            let maxHard = rlimitData.rlim_max

            // Try to raise the limit to the maximum allowed
            if currentSoft < maxHard {
                rlimitData.rlim_cur = maxHard
                setrlimit(RLIMIT_NOFILE, &rlimitData)
            }

            // Match DaisyDisk - use aggressive concurrency
            // FileIDTreeGetVRefNumForDevice errors are non-fatal warnings
            // The filesystem continues working despite these errors

            // Use all available file descriptors
            let fdLimit = Int(rlimitData.rlim_cur)

            // For 16 cores, we want 64+ concurrent operations like DaisyDisk
            self.maxConcurrencyLimit = max(optimalConcurrency, fdLimit / 8)
        }
    }

    private func scanDirectoryOptimized(path: String, name: String) async -> HyperScanItem {
        // Open Phase: Check Inode and Permissions
        let fd = open(path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else {
            if errno == EACCES || errno == EPERM {
                return await scanWithFileManager(path: path, name: name)
            }
            // V18: Safety net for exhaustion
            if errno == EMFILE {
                // Fallback logic could go here, but we prevent this via semaphores now.
            }
            return HyperScanItem(name: name, path: path, size: 0, isDirectory: true, children: [])
        }
        
        var fileStat = stat()
        guard fstat(fd, &fileStat) == 0 else {
            close(fd)
            return HyperScanItem(name: name, path: path, size: 0, isDirectory: true, children: [])
        }
        
        let fileID = FileSystemID(device: fileStat.st_dev, inode: fileStat.st_ino)
        
        if visitedInodes.contains(fileID) {
            close(fd)
            return HyperScanItem(name: name, path: path, size: 0, isDirectory: true, children: [])
        }
        visitedInodes.insert(fileID)
        
        if path != startPath {
            for excluded in excludedPathPrefixes {
                if path.hasPrefix(excluded) {
                    close(fd)
                    return HyperScanItem(name: name, path: path, size: 0, isDirectory: true, children: [])
                }
            }
        }

        close(fd) 
        
        return await scanDirectoryFull(path: path, name: name)
    }

    private func scanDirectoryFull(path: String, name: String) async -> HyperScanItem {
        var localItems = [HyperScanItem]()
        var localSize: Int64 = 0
        var directFilesSize: Int64 = 0
        var subdirectories: [(path: String, name: String)] = []

        // V18: Scope the File Access strictly to this block.
        // This ensures FD is closed BEFORE we start recursion (waiting on children).
        var dirDevice: dev_t = 0
        do {
            let fd = open(path, O_RDONLY | O_DIRECTORY)
            guard fd >= 0 else { return HyperScanItem(name: name, path: path, size: 0, isDirectory: true, children: []) }
            defer { close(fd) } // Ensures close happens immediately when this `do` block ends

            // Get device number for this directory
            var dirStat = stat()
            if fstat(fd, &dirStat) == 0 {
                dirDevice = dirStat.st_dev
            }

            var attrList = attrlist()
            attrList.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
            attrList.commonattr = attrgroup_t(UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(ATTR_CMN_NAME) | UInt32(ATTR_CMN_OBJTYPE) | UInt32(ATTR_CMN_FILEID))
            attrList.fileattr = attrgroup_t(UInt32(ATTR_FILE_ALLOCSIZE))  // Use allocated size for sparse file support
            attrList.dirattr = 0

            let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
            defer { buffer.deallocate() }

            let isDataVolumeRoot = (path == "/System/Volumes/Data")

            while true {
                let count = getattrlistbulk(fd, &attrList, buffer, bufferSize, 0)
                if count == 0 { break }
                if count < 0 { break }

                var ptr = buffer
                for _ in 0..<count {
                    let entry = parseAttributeBuffer(ptr: ptr)
                    ptr = ptr.advanced(by: Int(entry.length))

                    if entry.name == "." || entry.name == ".." || entry.name == "unknown" { continue }

                    let fullPath = path == "/" ? "/\(entry.name)" : "\(path)/\(entry.name)"

                    if isDataVolumeRoot && firmlinkNames.contains(entry.name) { continue }
                    if entry.name == "Volumes" && path == "/" { continue }

                    if entry.isDirectory {
                        subdirectories.append((path: fullPath, name: entry.name))
                    } else {
                        // Check for hard links - only count files we haven't seen before
                        var shouldCount = true
                        var actualSize = entry.size

                        if let fileID = entry.fileID {
                            let actualFileID = FileSystemID(device: dirDevice, inode: fileID.inode)
                            if visitedInodes.contains(actualFileID) {
                                shouldCount = false
                                actualSize = 0  // Don't count size for hard links we've seen
                            } else {
                                visitedInodes.insert(actualFileID)
                            }
                        }

                        // Only add to items if we should count it
                        if shouldCount {
                            localItems.append(HyperScanItem(name: entry.name, path: fullPath, size: actualSize, isDirectory: false, children: nil))
                            if actualSize > 0 {
                                localSize += actualSize
                                directFilesSize += actualSize
                            }
                            itemsScanned += 1
                        }
                    }
                }
            }
        } // <-- FD IS CLOSED HERE. Recursion happens below with 0 open files.

        // V20: Aggressive parallel scanning for ALL subdirectories
        // Match DaisyDisk - spawn tasks for everything
        if !subdirectories.isEmpty {
            if subdirectories.count == 1 {
                // Only one subdirectory, scan directly
                let (subPath, subName) = subdirectories[0]
                let res = await scanDirectoryOptimized(path: subPath, name: subName)
                localItems.append(res)
                localSize += res.size
            } else {
                // Multiple subdirectories - scan ALL in parallel
                await withTaskGroup(of: HyperScanItem.self) { group in
                    // Launch ALL subdirectory scans simultaneously
                    // Let Swift's runtime manage the thread pool
                    for (subPath, subName) in subdirectories {
                        group.addTask {
                            await self.scanDirectoryOptimized(path: subPath, name: subName)
                        }
                    }

                    // Collect all results
                    for await result in group {
                        localItems.append(result)
                        localSize += result.size
                    }
                }
            }
        }

        await updateProgress(bytesAdded: directFilesSize, path: path)
        return HyperScanItem(name: name, path: path, size: localSize, isDirectory: true, children: localItems.sorted { $0.size > $1.size })
    }

    private func parseAttributeBuffer(ptr: UnsafeMutableRawPointer) -> (length: UInt32, name: String, isDirectory: Bool, size: Int64, fileID: FileSystemID?) {
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
        var isRegularFile = false
        if (returnedCommon & UInt32(ATTR_CMN_OBJTYPE)) != 0 {
            let objType = ptr.load(fromByteOffset: currentOffset, as: UInt32.self)
            currentOffset += 4
            isDirectory = (objType == 2)
            isRegularFile = (objType == 1)
        }

        var fileID: FileSystemID? = nil
        if (returnedCommon & UInt32(ATTR_CMN_FILEID)) != 0 {
            var inode: UInt64 = 0
            withUnsafeMutableBytes(of: &inode) { inodeBuf in
                let srcPtr = ptr.advanced(by: currentOffset)
                inodeBuf.baseAddress?.copyMemory(from: srcPtr, byteCount: 8)
            }
            currentOffset += 8
            // For device, we'll get it from stat on the directory itself
            // For now, we'll create a placeholder and update it later
            fileID = FileSystemID(device: 0, inode: inode)
        }

        var size: Int64 = 0
        if isRegularFile && (returnedFile & UInt32(ATTR_FILE_ALLOCSIZE)) != 0 {
            if currentOffset + 8 <= Int(length) {
                var rawSize: Int64 = 0
                withUnsafeMutableBytes(of: &rawSize) { sizeBuf in
                    let srcPtr = ptr.advanced(by: currentOffset)
                    sizeBuf.baseAddress?.copyMemory(from: srcPtr, byteCount: 8)
                }
                currentOffset += 8

                if rawSize > 0 && rawSize < 1_000_000_000_000_000 {
                    size = rawSize
                }
            }
        }

        return (length, name, isDirectory, size, fileID)
    }

    private func updateProgress(bytesAdded: Int64, path: String) async {
        scannedBytes += bytesAdded
        let now = Date()

        if now.timeIntervalSince(lastProgressUpdate) >= progressUpdateInterval {
            lastProgressUpdate = now
            onProgress?(HyperScanProgress(scannedBytes: scannedBytes, totalUsedBytes: totalUsedBytes, currentPath: path, itemsScanned: itemsScanned))
        }
    }

    // Batch progress update - called from ScanContext
    private func updateProgressBatch(bytes: Int64, count: Int) async {
        scannedBytes += bytes
        itemsScanned += count

        let now = Date()
        if now.timeIntervalSince(lastProgressUpdate) >= progressUpdateInterval {
            lastProgressUpdate = now
            onProgress?(HyperScanProgress(
                scannedBytes: scannedBytes,
                totalUsedBytes: totalUsedBytes,
                currentPath: "",  // Don't have specific path in batch
                itemsScanned: itemsScanned
            ))
        }
    }

    // Update internal state from progress timer
    private func updateInternalState(bytes: Int64, items: Int) async {
        self.scannedBytes = bytes
        self.itemsScanned = items
    }

    private func scanWithFileManager(path: String, name: String) async -> HyperScanItem {
        var children: [HyperScanItem] = []
        var totalSize: Int64 = 0
        var directFilesSize: Int64 = 0

        if path != startPath {
            for excluded in excludedPathPrefixes {
                if path.hasPrefix(excluded) { return HyperScanItem(name: name, path: path, size: 0, isDirectory: true, children: []) }
            }
        }

        do {
            let contents = try FileManager.default.contentsOfDirectory(atPath: path)
            for itemName in contents {
                if itemName.hasPrefix(".") { continue }
                let fullPath = path + "/" + itemName

                if path == "/System/Volumes/Data" && firmlinkNames.contains(itemName) { continue }
                if itemName == "Volumes" && path == "/" { continue }

                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir) {
                    if isDir.boolValue {
                         let sub = await scanDirectoryOptimized(path: fullPath, name: itemName)
                         children.append(sub)
                         totalSize += sub.size
                    } else {
                         if let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath) {
                             // Use actual allocated size for sparse files (Docker, VMs, etc)
                             // First try to get the allocated size, fall back to regular size
                             let allocatedSize: Int64
                             let logicalSize = attrs[.size] as? Int64 ?? 0

                             if let allocSize = attrs[FileAttributeKey(rawValue: "NSFileAllocatedSize")] as? NSNumber {
                                 allocatedSize = allocSize.int64Value
                             } else {
                                 allocatedSize = logicalSize
                             }

                             // Check for hard links
                             var shouldCount = true
                             var actualSize = allocatedSize
                             var fileStat = stat()
                             if stat(fullPath, &fileStat) == 0 {
                                 let fileID = FileSystemID(device: fileStat.st_dev, inode: fileStat.st_ino)
                                 if visitedInodes.contains(fileID) {
                                     shouldCount = false
                                     actualSize = 0  // Don't count size for hard links we've seen
                                 } else {
                                     visitedInodes.insert(fileID)
                                 }
                             }

                             // Only add to items if we should count it
                             if shouldCount {
                                 children.append(HyperScanItem(name: itemName, path: fullPath, size: actualSize, isDirectory: false, children: nil))
                                 totalSize += actualSize
                                 directFilesSize += actualSize
                                 itemsScanned += 1
                             }
                         }
                    }
                }
            }
        } catch { }

        await updateProgress(bytesAdded: directFilesSize, path: path)
        return HyperScanItem(name: name, path: path, size: totalSize, isDirectory: true, children: children.sorted { $0.size > $1.size })
    }

    private func scanRootMaxParallel(url: URL) async -> HyperScanItem {
        // Scan root directories with MAXIMUM parallelization
        // All work done OUTSIDE actor for true parallel execution

        var rootChildren: [HyperScanItem] = []
        var totalSize: Int64 = 0

        // Get root directory listing
        guard let allRootContents = try? FileManager.default.contentsOfDirectory(atPath: "/") else {
            return HyperScanItem(name: "/", path: "/", size: 0, isDirectory: true, children: [])
        }

        let skipPaths = Set(["Volumes", ".VolumeIcon.icns", ".file"])
        var directoriesToScan: [(name: String, path: String)] = []

        for itemName in allRootContents {
            if skipPaths.contains(itemName) { continue }

            let fullPath = "/\(itemName)"
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue {
                directoriesToScan.append((name: itemName, path: fullPath))
            }
        }

        // Scan ALL root directories in parallel OUTSIDE the actor
        await withTaskGroup(of: HyperScanItem.self) { group in
            // Launch ALL scans immediately with HIGH priority!
            for (name, path) in directoriesToScan {
                group.addTask(priority: .high) {  // HIGH priority for maximum CPU usage
                    // This runs OUTSIDE actor isolation - true parallel!
                    await self.parallelScanner.parallelScanDirectory(
                        path: path,
                        name: name,
                        progressCallback: { [weak self] bytes, path in
                            await self?.updateProgress(bytesAdded: bytes, path: path)
                        }
                    )
                }
            }

            // Collect results
            for await item in group {
                if item.size > 0 {
                    rootChildren.append(item)
                    totalSize += item.size
                }
            }
        }

        return HyperScanItem(name: "/", path: "/", size: totalSize, isDirectory: true,
                           children: rootChildren.sorted { $0.size > $1.size })
    }

    private func scanRootWithFileManager(url: URL) async -> HyperScanItem {
        var rootChildren: [HyperScanItem] = []
        var totalSize: Int64 = 0

        // Get everything in root directory including hidden files
        let fileManager = FileManager.default
        guard let allRootContents = try? fileManager.contentsOfDirectory(atPath: "/") else {
            return HyperScanItem(name: "/", path: "/", size: 0, isDirectory: true, children: [])
        }

        // Only skip these specific paths
        let skipPaths = Set([
            "Volumes", // External volumes, handled separately
            ".VolumeIcon.icns", // System file
            ".file" // System file
        ])

        // Separate directories and files for parallel processing
        var directoriesToScan: [(name: String, path: String, isSystem: Bool)] = []
        var rootFiles: [HyperScanItem] = []

        for itemName in allRootContents {
            // Skip certain system paths
            if skipPaths.contains(itemName) {
                continue
            }

            let fullPath = "/\(itemName)"
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir) else { continue }

            if isDir.boolValue {
                directoriesToScan.append((name: itemName, path: fullPath, isSystem: itemName == "System"))
            } else {
                // Handle files in root directory
                if let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath) {
                    let fileSize: Int64
                    if let allocSize = attrs[FileAttributeKey(rawValue: "NSFileAllocatedSize")] as? NSNumber {
                        fileSize = allocSize.int64Value
                    } else if let regularSize = attrs[.size] as? Int64 {
                        fileSize = regularSize
                    } else {
                        fileSize = 0
                    }

                    if fileSize > 0 {
                        let item = HyperScanItem(name: itemName, path: fullPath, size: fileSize, isDirectory: false, children: nil)
                        rootFiles.append(item)
                        totalSize += fileSize
                    }
                }
            }
        }

        // Add files first
        rootChildren.append(contentsOf: rootFiles)

        // V20: Scan ALL root directories in PARALLEL for maximum performance
        // Like DaisyDisk - use all CPU cores aggressively
        if !directoriesToScan.isEmpty {
            await withTaskGroup(of: HyperScanItem?.self) { group in
                // Launch ALL root directory scans simultaneously
                for (name, path, isSystem) in directoriesToScan {
                    group.addTask { [weak self] in
                        guard let self = self else { return nil }

                        if isSystem {
                            // Special handling for /System to skip /System/Volumes/Data
                            let item = await self.scanSystemDirectoryWithoutData()
                            return item.size > 0 ? item : nil
                        } else {
                            // Scan ALL other directories normally
                            let item = await self.scanDirectoryOptimized(path: path, name: name)
                            return item.size > 0 ? item : nil
                        }
                    }
                }

                // Collect all results
                for await item in group {
                    if let item = item {
                        rootChildren.append(item)
                        totalSize += item.size
                    }
                }
            }
        }

        return HyperScanItem(name: "/", path: "/", size: totalSize, isDirectory: true, children: rootChildren.sorted { $0.size > $1.size })
    }

    private func scanSystemDirectoryWithoutData() async -> HyperScanItem {
        // Scan /System but EXCLUDE /System/Volumes/Data to avoid double counting
        var systemChildren: [HyperScanItem] = []
        var totalSize: Int64 = 0

        guard let systemContents = try? FileManager.default.contentsOfDirectory(atPath: "/System") else {
            return HyperScanItem(name: "System", path: "/System", size: 0, isDirectory: true, children: [])
        }

        for itemName in systemContents {
            let fullPath = "/System/\(itemName)"

            if itemName == "Volumes" {
                // Special handling for /System/Volumes - skip Data but scan other volumes
                var volumesChildren: [HyperScanItem] = []
                var volumesSize: Int64 = 0

                if let volumeContents = try? FileManager.default.contentsOfDirectory(atPath: fullPath) {
                    for volumeName in volumeContents {
                        if volumeName == "Data" {
                            // Skip /System/Volumes/Data - it's scanned via firmlinks at root
                            continue
                        }

                        // Scan other volumes (VM, Preboot, Update, etc.)
                        let volumePath = "\(fullPath)/\(volumeName)"
                        let item = await scanDirectoryOptimized(path: volumePath, name: volumeName)
                        if item.size > 0 {
                            volumesChildren.append(item)
                            volumesSize += item.size
                        }
                    }
                }

                if !volumesChildren.isEmpty {
                    let volumesItem = HyperScanItem(name: "Volumes", path: fullPath, size: volumesSize,
                                                   isDirectory: true, children: volumesChildren.sorted { $0.size > $1.size })
                    systemChildren.append(volumesItem)
                    totalSize += volumesSize
                }
            } else {
                // Scan other System directories normally
                let item = await scanDirectoryOptimized(path: fullPath, name: itemName)
                systemChildren.append(item)
                totalSize += item.size
            }
        }

        return HyperScanItem(name: "System", path: "/System", size: totalSize, isDirectory: true,
                           children: systemChildren.sorted { $0.size > $1.size })
    }


    private func getVolumeUsedSize(for url: URL) -> Int64 {
        var stat = statfs()
        if url.withUnsafeFileSystemRepresentation({ statfs($0, &stat) }) == 0 {
            return (Int64(stat.f_blocks) - Int64(stat.f_bfree)) * Int64(stat.f_bsize)
        }
        return 500_000_000_000
    }
}

// MARK: - App Integration

extension HyperScanner {
    static func convertToFolderItems(_ items: [HyperScanItem]) -> [FolderItem] {
        return items.map { $0.toFolderItem() }
    }
}

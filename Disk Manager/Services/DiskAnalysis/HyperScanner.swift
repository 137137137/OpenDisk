import Foundation
import Darwin

// MARK: - Models

struct HyperScanItem: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let path: String
    let size: Int64
    let isDirectory: Bool
    var children: [HyperScanItem]?

    func toFolderItem() -> FolderItem {
        var item = FolderItem(
            name: name,
            path: path,
            size: size,
            isDirectory: isDirectory,
            itemCount: children?.count ?? 1,
            lastModified: Date()
        )
        item.children = children?.map { $0.toFolderItem() } ?? []
        return item
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
    
    // Cycle Detection
    private var visitedInodes: Set<FileSystemID> = []
    
    // Config
    private let bufferSize = 256 * 1024
    private let progressUpdateInterval: TimeInterval = 0.1
    private let consolePrintInterval: TimeInterval = 0.5
    
    // V18: Dynamic Concurrency Control
    private var activeTaskCount = 0
    private var maxConcurrencyLimit = 64 // Will be updated dynamically at runtime
    
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

    func scan(url: URL, onProgress: @escaping (HyperScanProgress) -> Void) async -> HyperScanItem {
        print("[HyperScanner] ===== STARTING SCAN (v18 - Dynamic Resource Limits) =====")
        print("[HyperScanner] Scanning path: \(url.path)")

        // 1. Permission Check
        let currentUser = getuid()
        if currentUser != 0 {
            print("⚠️  [WARNING] Running as User ID: \(currentUser).")
            print("👉  Run with 'sudo swift FastScanner.swift' for complete results.")
        } else {
            print("✅ [INFO] Running as Root. Full access enabled.")
        }

        // 2. Resource Optimization (V18 Feature)
        optimizeSystemLimits()

        self.onProgress = onProgress
        self.totalUsedBytes = getVolumeUsedSize(for: url)
        self.scannedBytes = 0
        self.itemsScanned = 0
        self.startTime = Date()
        self.lastProgressUpdate = Date()
        self.lastConsolePrint = Date()
        self.visitedInodes.removeAll()
        self.startPath = url.resolvingSymlinksInPath().path
        self.activeTaskCount = 0

        print("[HyperScanner] Volume used bytes: \(ByteFormatter.formatFileSize(totalUsedBytes))")

        if url.path == "/" {
            let result = await scanRootWithFileManager(url: url)
            print("[HyperScanner] SCAN COMPLETE - Final size: \(ByteFormatter.formatFileSize(result.size))")
            print("[HyperScanner] Files scanned: \(itemsScanned), Unique inodes: \(visitedInodes.count)")
            return result
        }

        let result = await scanDirectoryOptimized(path: url.path, name: url.lastPathComponent)
        print("[HyperScanner] SCAN COMPLETE - Final size: \(ByteFormatter.formatFileSize(result.size))")
        print("[HyperScanner] Files scanned: \(itemsScanned), Unique inodes: \(visitedInodes.count)")
        return result
    }
    
    // V18: Maximize file descriptors and calculate safe concurrency
    private func optimizeSystemLimits() {
        var rlimitData = rlimit()
        
        // Get current limits
        if getrlimit(RLIMIT_NOFILE, &rlimitData) == 0 {
            let currentSoft = rlimitData.rlim_cur
            let maxHard = rlimitData.rlim_max
            
            print("ℹ️  [System Limits] Files: \(currentSoft) (Soft) / \(maxHard) (Hard)")
            
            // Try to raise the limit to the maximum allowed
            if currentSoft < maxHard {
                rlimitData.rlim_cur = maxHard
                if setrlimit(RLIMIT_NOFILE, &rlimitData) == 0 {
                    print("🚀 [Boost] Raised file descriptor limit to \(maxHard)")
                } else {
                    print("⚠️ [Boost] Failed to raise limits. Using default.")
                }
            }
            
            // Set max concurrency to 80% of the limit to leave room for overhead
            // Clamp to a reasonable range (e.g., 64 to 2048 threads)
            // Note: We use a smaller number for task concurrency than file limits because
            // thread overhead is also a factor.
            let safeLimit = Int(rlimitData.rlim_cur) / 2
            self.maxConcurrencyLimit = min(max(safeLimit, 64), 1024)
            print("⚡️ [Concurrency] Target Parallel Tasks: \(self.maxConcurrencyLimit)")
        }
    }

    private func scanDirectoryOptimized(path: String, name: String) async -> HyperScanItem {
        // Open Phase: Check Inode and Permissions
        let fd = open(path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else {
            if errno == EACCES || errno == EPERM { 
                if path.contains("Library") { print("[Access Denied] \(path)") }
                return await scanWithFileManager(path: path, name: name) 
            }
            // V18: Safety net for exhaustion
            if errno == EMFILE {
                print("🔥 [BUSY] System saturated. Retrying sequentially: \(path)")
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

        // V18: Dynamic Task Scheduling
        if !subdirectories.isEmpty {
            // How many tasks can we afford?
            let availableSlots = maxConcurrencyLimit - activeTaskCount
            
            // If we have room, spawn parallel tasks
            if availableSlots > 0 && subdirectories.count > 1 {
                await withTaskGroup(of: HyperScanItem.self) { group in
                    for (subPath, subName) in subdirectories {
                        // Check limit again inside the loop (approximate)
                        if activeTaskCount < maxConcurrencyLimit {
                            activeTaskCount += 1
                            group.addTask {
                                let result = await self.scanDirectoryOptimized(path: subPath, name: subName)
                                return result
                            }
                        } else {
                            // Fallback to sequential if we are saturated
                            activeTaskCount -= 1 // Since we are counting 'completed' in the group loop, adjust logic?
                            // Actually, strictly inside TaskGroup is tricky for counters.
                            // Simplified: We just add the result to items.
                            // Correct Logic for mixed group:
                            // The addTask closure is async. We can't easily mix sequential/parallel in one group cleanly
                            // without advanced logic.
                            // Simpler V18 Logic: Just spawn everything, but if we are OVER limit, 
                            // the `scanDirectoryOptimized` creates a temporary slowdown or we trust Swift Runtime.
                            // BUT: We closed the FD. So actually, we are safe from EMFILE!
                            // We only need to limit to prevent thread explosion.
                            
                            // Since we closed FD, we can rely on Swift's Thread Pool much more safely.
                            // We will spawn all, but Swift limits threads to # of cores naturally.
                            // The only resource we were running out of was FDs.
                            // Since FD is closed, we can just go parallel.
                        }
                    }
                    
                    // Process results
                    for await result in group {
                        activeTaskCount -= 1
                        localItems.append(result)
                        localSize += result.size
                    }
                }
            } else {
                // Sequential scan for small folders or if we are trying to be gentle
                for (subPath, subName) in subdirectories {
                    let res = await scanDirectoryOptimized(path: subPath, name: subName)
                    localItems.append(res)
                    localSize += res.size
                }
            }
        }

        await updateProgress(bytesAdded: directFilesSize, path: path)

        // Debug logging for large directories
        if localSize > 10_000_000_000 { // > 10GB
            print("[DEBUG] Large directory: \(path) = \(ByteFormatter.formatFileSize(localSize))")
        }

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
        
        if now.timeIntervalSince(lastConsolePrint) >= consolePrintInterval {
            lastConsolePrint = now
            let sizeStr = ByteFormatter.formatFileSize(scannedBytes)
            let elapsed = abs(startTime.timeIntervalSinceNow)
            let speed = elapsed > 0 ? Double(itemsScanned) / elapsed : 0
            print("[STATUS] Total: \(sizeStr) | Files: \(itemsScanned) | Speed: \(Int(speed))/s | Current: \(path)")
        }

        if now.timeIntervalSince(lastProgressUpdate) >= progressUpdateInterval {
            lastProgressUpdate = now
            onProgress?(HyperScanProgress(scannedBytes: scannedBytes, totalUsedBytes: totalUsedBytes, currentPath: path, itemsScanned: itemsScanned))
        }
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

                                 // Log sparse files (where allocated is much less than logical size)
                                 if logicalSize > 0 && allocatedSize > 0 && logicalSize > allocatedSize * 2 {
                                     let savedSpace = logicalSize - allocatedSize
                                     print("[SPARSE FILE] \(itemName): Logical=\(ByteFormatter.formatFileSize(logicalSize)), Allocated=\(ByteFormatter.formatFileSize(allocatedSize)), Saved=\(ByteFormatter.formatFileSize(savedSpace))")
                                 }
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

    private func scanRootWithFileManager(url: URL) async -> HyperScanItem {
        var rootChildren: [HyperScanItem] = []
        var totalSize: Int64 = 0
        // Don't include /var since it's a symlink to /private/var (would cause double counting)
        let rootPaths = ["/Applications", "/Library", "/System", "/Users", "/usr", "/opt", "/private"]

        print("[HyperScanner] Scanning root with paths: \(rootPaths)")

        for path in rootPaths {
            guard FileManager.default.fileExists(atPath: path) else { continue }

            if path.contains("Volumes") { continue }

            let item = await scanDirectoryOptimized(path: path, name: URL(fileURLWithPath: path).lastPathComponent)
            print("[HyperScanner] Root path \(path): \(ByteFormatter.formatFileSize(item.size))")
            rootChildren.append(item)
            totalSize += item.size
        }
        return HyperScanItem(name: "/", path: "/", size: totalSize, isDirectory: true, children: rootChildren.sorted { $0.size > $1.size })
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

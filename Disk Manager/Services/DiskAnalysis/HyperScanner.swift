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

/// A unique identifier for a file system object (Device + Inode).
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
    
    // Cycle Detection (The Robust Fix)
    // We track unique (Device, Inode) pairs for every directory we enter.
    private var visitedInodes: Set<FileSystemID> = []
    
    // Config
    private let bufferSize = 256 * 1024
    private let aggregationThreshold = 5000
    private let progressUpdateInterval: TimeInterval = 0.1
    private let consolePrintInterval: TimeInterval = 0.5
    
    // User configuration for strictly excluding Volumes if desired
    private let excludedPathPrefixes: [String] = [
        "/dev", "/net", "/home", "/private/var/vm"
    ]

    func scan(url: URL, onProgress: @escaping (HyperScanProgress) -> Void) async -> HyperScanItem {
        print("[HyperScanner] ===== STARTING SCAN (v11 - Inode Cycle Detection) =====")
        self.onProgress = onProgress
        self.totalUsedBytes = getVolumeUsedSize(for: url)
        self.scannedBytes = 0
        self.itemsScanned = 0
        self.startTime = Date()
        self.lastProgressUpdate = Date()
        self.lastConsolePrint = Date()
        self.visitedInodes.removeAll()

        if url.path == "/" {
            return await scanRootWithFileManager(url: url)
        }

        return await scanDirectoryOptimized(path: url.path, name: url.lastPathComponent)
    }

    private func scanDirectoryOptimized(path: String, name: String) async -> HyperScanItem {
        // 1. Inode-Based Cycle Detection
        // Open the directory primarily to identify it.
        let fd = open(path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else {
            // Permission denied or not a directory. Fallback if it's strictly permission.
            if errno == EACCES || errno == EPERM { return await scanWithFileManager(path: path, name: name) }
            return HyperScanItem(name: name, path: path, size: 0, isDirectory: true, children: [])
        }
        
        // Stat the file descriptor to get the REAL identity of this directory
        var fileStat = stat()
        guard fstat(fd, &fileStat) == 0 else {
            close(fd)
            return HyperScanItem(name: name, path: path, size: 0, isDirectory: true, children: [])
        }
        
        let fileID = FileSystemID(device: fileStat.st_dev, inode: fileStat.st_ino)
        
        // CRITICAL CHECK: Have we visited this physical directory before?
        if visitedInodes.contains(fileID) {
            // We have already scanned this exact directory (referenced via a symlink, loop, or mount point).
            // Skip it to prevent infinite recursion and stack overflow.
            close(fd)
            return HyperScanItem(name: name, path: path, size: 0, isDirectory: true, children: [])
        }
        
        // Mark as visited
        visitedInodes.insert(fileID)
        
        // Check for manual exclusions (user preferences)
        for excluded in excludedPathPrefixes {
            if path.hasPrefix(excluded) {
                close(fd)
                return HyperScanItem(name: name, path: path, size: 0, isDirectory: true, children: [])
            }
        }

        // 2. Scan Logic (Pass the FD to avoid re-opening)
        // We close FD inside scanDirectoryFull or if we don't proceed.
        // For the purpose of this clean separation, we will close it here and let scanDirectoryFull re-open 
        // OR refactor to pass FD. Re-opening is safer for avoiding logic errors in this specific snippet context, 
        // but `fstat` cost is negligible.
        close(fd) 

        let quickCheck = await quickDirectoryCheck(path: path)
        
        // Optimization: Aggregate massive generated folders (node_modules, etc.)
        if quickCheck.itemCount > aggregationThreshold && isLikelyGenerated(name: name, itemCount: quickCheck.itemCount) {
             return await createAggregatedItem(path: path, name: name, quickCheck: quickCheck)
        }

        return await scanDirectoryFull(path: path, name: name)
    }

    private func scanDirectoryFull(path: String, name: String) async -> HyperScanItem {
        // Re-open is cheap and safe here to ensure clean FD lifecycle management in the loop
        let fd = open(path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { return HyperScanItem(name: name, path: path, size: 0, isDirectory: true, children: []) }
        defer { close(fd) }

        var attrList = attrlist()
        attrList.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        // Request: RETURNED | NAME | OBJTYPE (Common) + TOTALSIZE (File)
        attrList.commonattr = attrgroup_t(UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(ATTR_CMN_NAME) | UInt32(ATTR_CMN_OBJTYPE))
        attrList.fileattr = attrgroup_t(UInt32(ATTR_FILE_TOTALSIZE)) 
        attrList.dirattr = 0

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { buffer.deallocate() }

        var localItems = [HyperScanItem]()
        var localSize: Int64 = 0
        var subdirectories: [(path: String, name: String)] = []

        while true {
            let count = getattrlistbulk(fd, &attrList, buffer, bufferSize, 0)
            if count == 0 { break } // End of directory
            if count < 0 { break }  // Error

            var ptr = buffer
            for _ in 0..<count {
                let entry = parseAttributeBuffer(ptr: ptr)
                ptr = ptr.advanced(by: Int(entry.length))

                if entry.name == "." || entry.name == ".." || entry.name == "unknown" { continue }
                
                let fullPath = path == "/" ? "/\(entry.name)" : "\(path)/\(entry.name)"
                
                // Volume Boundary Guard
                // Even with Inode protection, we often don't *want* to traverse into /Volumes
                // because it scans backup drives which is slow, even if not an infinite loop.
                if entry.name == "Volumes" && (path == "/" || path == "/System/Volumes/Data") {
                    continue
                }
                
                if entry.isDirectory {
                    subdirectories.append((path: fullPath, name: entry.name))
                } else {
                    localItems.append(HyperScanItem(name: entry.name, path: fullPath, size: entry.size, isDirectory: false, children: nil))
                    if entry.size > 0 { localSize += entry.size }
                    itemsScanned += 1
                }
            }
        }

        // Process subdirectories - Recursive calls will hit the Inode Check first
        if subdirectories.count > 1 {
             await withTaskGroup(of: HyperScanItem.self) { group in
                for (subPath, subName) in subdirectories {
                    group.addTask { await self.scanDirectoryOptimized(path: subPath, name: subName) }
                }
                for await result in group {
                    localItems.append(result)
                    localSize += result.size
                }
            }
        } else {
            for (subPath, subName) in subdirectories {
                let res = await scanDirectoryOptimized(path: subPath, name: subName)
                localItems.append(res)
                localSize += res.size
            }
        }

        await updateProgress(bytesAdded: localSize, path: path)
        return HyperScanItem(name: name, path: path, size: localSize, isDirectory: true, children: localItems.sorted { $0.size > $1.size })
    }

    private func parseAttributeBuffer(ptr: UnsafeMutableRawPointer) -> (length: UInt32, name: String, isDirectory: Bool, size: Int64) {
        let length = ptr.load(as: UInt32.self)
        var currentOffset = 4

        // 1. Returned Attributes (20 bytes)
        let returnedCommon = ptr.load(fromByteOffset: currentOffset, as: UInt32.self)
        let returnedFile = ptr.load(fromByteOffset: currentOffset + 12, as: UInt32.self)
        currentOffset += 20

        // 2. Name
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

        // 3. ObjType
        var isDirectory = false
        var isRegularFile = false
        if (returnedCommon & UInt32(ATTR_CMN_OBJTYPE)) != 0 {
            let objType = ptr.load(fromByteOffset: currentOffset, as: UInt32.self)
            currentOffset += 4
            isDirectory = (objType == 2)
            isRegularFile = (objType == 1)
        }

        // 4. Total Size (Logical)
        var size: Int64 = 0
        if isRegularFile && (returnedFile & UInt32(ATTR_FILE_TOTALSIZE)) != 0 {
            if currentOffset + 8 <= Int(length) {
                // Safe memcpy for unaligned Int64 access
                var rawSize: Int64 = 0
                withUnsafeMutableBytes(of: &rawSize) { sizeBuf in
                    let srcPtr = ptr.advanced(by: currentOffset)
                    sizeBuf.baseAddress?.copyMemory(from: srcPtr, byteCount: 8)
                }
                currentOffset += 8
                
                // Sanity check for corruption
                if rawSize > 0 && rawSize < 1_000_000_000_000_000 {
                    size = rawSize
                }
            }
        }

        return (length, name, isDirectory, size)
    }

    private func quickDirectoryCheck(path: String) async -> (itemCount: Int, estimatedSize: Int64) {
        let fd = open(path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { return (0, 0) }
        defer { close(fd) }
        
        var attrList = attrlist()
        attrList.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrList.commonattr = attrgroup_t(UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(ATTR_CMN_NAME) | UInt32(ATTR_CMN_OBJTYPE))
        
        let smallBuffer = UnsafeMutableRawPointer.allocate(byteCount: 8192, alignment: 8)
        defer { smallBuffer.deallocate() }
        
        var itemCount = 0
        while itemCount < 1000 {
            let count = getattrlistbulk(fd, &attrList, smallBuffer, 8192, 0)
            if count <= 0 { break }
            itemCount += Int(count)
        }
        return (itemCount, 0)
    }

    private func createAggregatedItem(path: String, name: String, quickCheck: (itemCount: Int, estimatedSize: Int64)) async -> HyperScanItem {
        let actualSize = await getDirectorySizeFast(path: path)
        let displayName = getAggregatedDisplayName(name: name, itemCount: quickCheck.itemCount)
        await updateProgress(bytesAdded: actualSize, path: path)
        return HyperScanItem(name: displayName, path: path, size: actualSize, isDirectory: true, children: [])
    }

    private func getDirectorySizeFast(path: String) async -> Int64 {
        var totalSize: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.fileSizeKey], options: [.skipsPackageDescendants])
        while let url = enumerator?.nextObject() as? URL {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize { totalSize += Int64(size) }
        }
        return totalSize
    }

    private func updateProgress(bytesAdded: Int64, path: String) async {
        scannedBytes += bytesAdded
        let now = Date()
        
        if now.timeIntervalSince(lastConsolePrint) >= consolePrintInterval {
            lastConsolePrint = now
            let sizeStr = ByteCountFormatter.string(fromByteCount: scannedBytes, countStyle: .file)
            let elapsed = abs(startTime.timeIntervalSinceNow)
            let speed = elapsed > 0 ? Double(itemsScanned) / elapsed : 0
            print("[STATUS] Total: \(sizeStr) | Files: \(itemsScanned) | Speed: \(Int(speed))/s | Current: \(path)")
        }

        if now.timeIntervalSince(lastProgressUpdate) >= progressUpdateInterval {
            lastProgressUpdate = now
            onProgress?(HyperScanProgress(scannedBytes: scannedBytes, totalUsedBytes: totalUsedBytes, currentPath: path, itemsScanned: itemsScanned))
        }
    }
    
    private func isLikelyGenerated(name: String, itemCount: Int) -> Bool {
        let patterns = ["node_modules", ".git", "venv", ".venv", "target", "build", "dist", "DerivedData"]
        return patterns.contains(name) || (name.hasPrefix(".") && itemCount > 500)
    }

    private func getAggregatedDisplayName(name: String, itemCount: Int) -> String {
        return "📦 \(name) (\(itemCount.formatted()) items)"
    }

    private func scanWithFileManager(path: String, name: String) async -> HyperScanItem {
        var children: [HyperScanItem] = []
        var totalSize: Int64 = 0
        
        // Manual exclude check for FM path
        for excluded in excludedPathPrefixes {
            if path.hasPrefix(excluded) { return HyperScanItem(name: name, path: path, size: 0, isDirectory: true, children: []) }
        }

        do {
            let contents = try FileManager.default.contentsOfDirectory(atPath: path)
            for itemName in contents {
                if itemName.hasPrefix(".") { continue }
                let fullPath = path + "/" + itemName
                
                if itemName == "Volumes" && (path == "/" || path == "/System/Volumes/Data") { continue }

                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir) {
                    if isDir.boolValue {
                         // Recursion here also needs Inode check, so we route back to Optimized
                         let sub = await scanDirectoryOptimized(path: fullPath, name: itemName)
                         children.append(sub)
                         totalSize += sub.size
                    } else {
                         if let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath), let s = attrs[.size] as? Int64 {
                             children.append(HyperScanItem(name: itemName, path: fullPath, size: s, isDirectory: false, children: nil))
                             totalSize += s
                             itemsScanned += 1
                         }
                    }
                }
            }
        } catch { }
        
        await updateProgress(bytesAdded: totalSize, path: path)
        return HyperScanItem(name: name, path: path, size: totalSize, isDirectory: true, children: children.sorted { $0.size > $1.size })
    }

    private func scanRootWithFileManager(url: URL) async -> HyperScanItem {
        var rootChildren: [HyperScanItem] = []
        var totalSize: Int64 = 0
        let rootPaths = ["/Applications", "/Library", "/System", "/Users", "/usr", "/opt", "/private", "/var"]

        for path in rootPaths {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            
            // Explicitly prevent Volumes scan from root logic
            if path.contains("Volumes") { continue }
            
            let item = await scanDirectoryOptimized(path: path, name: URL(fileURLWithPath: path).lastPathComponent)
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
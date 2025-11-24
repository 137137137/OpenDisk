import Foundation
import Darwin
import os

// MARK: - Thread-Safe Context with os_unfair_lock
final class ScanContext: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var visitedInodes: Set<FileSystemID> = []

    // Accumulate progress locally to reduce actor traffic
    private var pendingBytes: Int64 = 0
    private var pendingCount: Int = 0
    private let progressCallback: (Int64, Int) -> Void

    init(progressCallback: @escaping (Int64, Int) -> Void) {
        self.progressCallback = progressCallback
    }

    func markVisited(_ id: FileSystemID) -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let (inserted, _) = visitedInodes.insert(id)
        return inserted // Returns true if it was NEW, false if already visited
    }

    func addProgress(bytes: Int64, count: Int = 1) {
        os_unfair_lock_lock(&lock)
        pendingBytes += bytes
        pendingCount += count

        // Report progress immediately for debugging
        let b = pendingBytes
        let c = pendingCount
        pendingBytes = 0
        pendingCount = 0
        os_unfair_lock_unlock(&lock)

        if b > 0 || c > 0 {
            progressCallback(b, c)
        }
    }

    // Force flush remaining progress
    func flush() {
        os_unfair_lock_lock(&lock)
        if pendingBytes > 0 || pendingCount > 0 {
            let b = pendingBytes
            let c = pendingCount
            pendingBytes = 0
            pendingCount = 0
            os_unfair_lock_unlock(&lock)
            progressCallback(b, c)
        } else {
            os_unfair_lock_unlock(&lock)
        }
    }
}

// MARK: - Ultra-Fast Static Scanner (No Actor!)
struct FastScanner {
    // Optimization: Reuse a buffer size that aligns with memory pages
    static let bufferSize = 64 * 1024 // 64KB is usually the sweet spot for getattrlistbulk

    // Exclusions
    private static let excludedPaths = Set([
        "/dev", "/net", "/home", "/private/var/vm", "/Volumes"
    ])

    private static let firmlinkNames = Set([
        "Users", "Applications", "Library", "System", "private", "usr", "bin", "sbin", "opt", "Volumes", "cores"
    ])

    // MARK: - Main Recursive Function (STATIC - No Actor!)
    static func scan(
        path: String,
        name: String,
        context: ScanContext,
        isRoot: Bool = false
    ) async -> HyperScanItem {

        // Check exclusions
        for excluded in excludedPaths {
            if path == excluded || path.hasPrefix(excluded + "/") {
                return HyperScanItem(name: name, path: path, size: 0, isDirectory: true, children: [])
            }
        }

        // 1. Fast Open (Raw Syscalls)
        let fd = open(path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else {
            // Try with FileManager as fallback for permission issues
            if errno == EACCES || errno == EPERM {
                return await scanWithFileManager(path: path, name: name, context: context)
            }
            return HyperScanItem(name: name, path: path, size: 0, isDirectory: true, children: [])
        }
        defer { close(fd) }

        // Get device number for this directory
        var dirStat = stat()
        guard fstat(fd, &dirStat) == 0 else {
            return HyperScanItem(name: name, path: path, size: 0, isDirectory: true, children: [])
        }
        let dirDevice = dirStat.st_dev

        // Don't check visited for directories - only for files!
        // Directories can be traversed multiple times (via different paths)

        var localItems: [HyperScanItem] = []
        var localSize: Int64 = 0
        var subDirs: [(String, String)] = []

        // 2. Attribute List Setup (Setup once per call)
        var attrList = attrlist()
        attrList.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrList.commonattr = attrgroup_t(
            UInt32(ATTR_CMN_RETURNED_ATTRS) |
            UInt32(ATTR_CMN_NAME) |
            UInt32(ATTR_CMN_OBJTYPE) |
            UInt32(ATTR_CMN_FILEID)
        )
        attrList.fileattr = attrgroup_t(UInt32(ATTR_FILE_ALLOCSIZE)) // Physical size on disk
        attrList.dirattr = 0

        // 3. Stack-based buffer allocation (Much faster than malloc)
        let scanResult = withUnsafeTemporaryAllocation(of: UInt8.self, capacity: bufferSize) { bufferPtr -> (Int64, [HyperScanItem], [(String, String)]) in
            guard let baseAddress = bufferPtr.baseAddress else { return (0, [], []) }

            var dirSize: Int64 = 0
            var items: [HyperScanItem] = []
            var dirs: [(String, String)] = []

            let isDataVolumeRoot = (path == "/System/Volumes/Data")

            // Loop until all entries in this directory are read
            while true {
                let count = getattrlistbulk(fd, &attrList, baseAddress, bufferSize, 0)
                if count <= 0 { break }

                var ptr = UnsafeRawPointer(baseAddress)
                for _ in 0..<count {
                    // Parse entry
                    let length = ptr.load(as: UInt32.self)
                    let entry = parseEntry(ptr: ptr, device: dirDevice)
                    ptr = ptr.advanced(by: Int(length))

                    // Filter junk
                    if entry.name == "." || entry.name == ".." { continue }

                    // Skip firmlinks in /System/Volumes/Data
                    if isDataVolumeRoot && firmlinkNames.contains(entry.name) { continue }
                    if entry.name == "Volumes" && path == "/" { continue }

                    let fullPath = (path == "/") ? "/\(entry.name)" : "\(path)/\(entry.name)"

                    if entry.isDirectory {
                        // Defer recursion: Don't await here! Just collect paths.
                        dirs.append((fullPath, entry.name))
                    } else if let fileID = entry.fileID {
                        // Deduplication check for hard links
                        if context.markVisited(fileID) {
                            items.append(HyperScanItem(
                                name: entry.name,
                                path: fullPath,
                                size: entry.size,
                                isDirectory: false,
                                children: nil
                            ))
                            dirSize += entry.size
                        }
                    }
                }
            }
            return (dirSize, items, dirs)
        }

        localSize = scanResult.0
        localItems = scanResult.1
        subDirs = scanResult.2

        // Report file bytes found in this folder immediately
        if localSize > 0 {
            context.addProgress(bytes: localSize, count: localItems.count)
        }

        // 4. Parallel Recursion (The Magic)
        // We spawn tasks, but they call this STATIC function, not the actor.
        // This bypasses the actor lock entirely.
        if !subDirs.isEmpty {
            await withTaskGroup(of: HyperScanItem.self) { group in
                // Spawn ALL subdirectory scans with high priority
                for (subPath, subName) in subDirs {
                    group.addTask(priority: .high) {
                        // Recursive call to STATIC function - no actor involved!
                        return await scan(
                            path: subPath,
                            name: subName,
                            context: context,
                            isRoot: false
                        )
                    }
                }

                // Collect results as they complete
                for await child in group {
                    localItems.append(child)
                    localSize += child.size
                }
            }
        }

        // Sort children by size
        localItems.sort { $0.size > $1.size }

        return HyperScanItem(
            name: name,
            path: path,
            size: localSize,
            isDirectory: true,
            children: localItems
        )
    }

    // MARK: - Special handler for root scan
    static func scanRoot(context: ScanContext) async -> HyperScanItem {
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

        // Scan ALL root directories in parallel with STATIC functions
        await withTaskGroup(of: HyperScanItem.self) { group in
            for (name, path) in directoriesToScan {
                group.addTask(priority: .high) {
                    // Special handling for /System to avoid double-counting
                    if name == "System" {
                        return await scanSystemWithoutData(context: context)
                    } else {
                        return await scan(
                            path: path,
                            name: name,
                            context: context,
                            isRoot: false
                        )
                    }
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

        // Sort and return
        rootChildren.sort { $0.size > $1.size }

        return HyperScanItem(
            name: "/",
            path: "/",
            size: totalSize,
            isDirectory: true,
            children: rootChildren
        )
    }

    // Special handler for /System to avoid /System/Volumes/Data
    private static func scanSystemWithoutData(context: ScanContext) async -> HyperScanItem {
        var systemChildren: [HyperScanItem] = []
        var totalSize: Int64 = 0

        guard let systemContents = try? FileManager.default.contentsOfDirectory(atPath: "/System") else {
            return HyperScanItem(name: "System", path: "/System", size: 0, isDirectory: true, children: [])
        }

        await withTaskGroup(of: HyperScanItem?.self) { group in
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
                                        await scan(
                                            path: volumePath,
                                            name: volumeName,
                                            context: context,
                                            isRoot: false
                                        )
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

                        if !volumesChildren.isEmpty {
                            return HyperScanItem(
                                name: "Volumes",
                                path: fullPath,
                                size: volumesSize,
                                isDirectory: true,
                                children: volumesChildren.sorted { $0.size > $1.size }
                            )
                        }
                        return nil
                    }
                } else {
                    // Scan other System directories normally
                    group.addTask(priority: .high) {
                        await scan(
                            path: fullPath,
                            name: itemName,
                            context: context,
                            isRoot: false
                        )
                    }
                }
            }

            for await result in group {
                if let item = result {
                    systemChildren.append(item)
                    totalSize += item.size
                }
            }
        }

        return HyperScanItem(
            name: "System",
            path: "/System",
            size: totalSize,
            isDirectory: true,
            children: systemChildren.sorted { $0.size > $1.size }
        )
    }

    // MARK: - Inline helper for raw pointer parsing (ultra-fast)
    @inline(__always)
    static func parseEntry(ptr: UnsafeRawPointer, device: dev_t) -> (name: String, isDirectory: Bool, size: Int64, fileID: FileSystemID?) {
        var offset = 4 // Skip length

        // 1. Attribute Bitmaps
        let returnedCommon = ptr.load(fromByteOffset: offset, as: UInt32.self)
        let returnedFile = ptr.load(fromByteOffset: offset + 12, as: UInt32.self)
        offset += 20 // Skip attribute header

        // 2. Name (if present)
        var name = "unknown"
        if (returnedCommon & UInt32(ATTR_CMN_NAME)) != 0 {
            let nameRef = ptr.load(fromByteOffset: offset, as: attrreference_t.self)
            offset += 8

            let namePtr = ptr.advanced(by: Int(nameRef.attr_dataoffset))
            let nameLen = Int(nameRef.attr_length) - 1

            if nameLen > 0 {
                // Fast string creation
                let nameData = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: namePtr),
                                   count: nameLen,
                                   deallocator: .none)
                name = String(data: nameData, encoding: .utf8) ?? "unknown"
            }
        }

        // 3. Object Type
        var isDirectory = false
        if (returnedCommon & UInt32(ATTR_CMN_OBJTYPE)) != 0 {
            let objType = ptr.load(fromByteOffset: offset, as: UInt32.self)
            offset += 4
            isDirectory = (objType == 2) // VDIR
        }

        // 4. File ID (Inode)
        var fileID: FileSystemID? = nil
        if (returnedCommon & UInt32(ATTR_CMN_FILEID)) != 0 {
            var inode: UInt64 = 0
            withUnsafeMutableBytes(of: &inode) { buf in
                buf.baseAddress!.copyMemory(from: ptr.advanced(by: offset), byteCount: 8)
            }
            offset += 8
            fileID = FileSystemID(device: device, inode: inode)
        }

        // 5. Size (if file)
        var size: Int64 = 0
        if !isDirectory && (returnedFile & UInt32(ATTR_FILE_ALLOCSIZE)) != 0 {
            withUnsafeMutableBytes(of: &size) { buf in
                buf.baseAddress!.copyMemory(from: ptr.advanced(by: offset), byteCount: 8)
            }
            // Sanity check
            if size < 0 || size > 1_000_000_000_000_000 {
                size = 0
            }
        }

        return (name, isDirectory, size, fileID)
    }

    // MARK: - FileManager fallback for permission-denied directories
    static func scanWithFileManager(
        path: String,
        name: String,
        context: ScanContext
    ) async -> HyperScanItem {
        var localItems: [HyperScanItem] = []
        var localSize: Int64 = 0

        // Check exclusions
        for excluded in excludedPaths {
            if path == excluded || path.hasPrefix(excluded + "/") {
                return HyperScanItem(name: name, path: path, size: 0, isDirectory: true, children: [])
            }
        }

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
                                    if context.markVisited(fileID) {
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
                context.addProgress(bytes: localSize, count: localItems.count)
            }

            // Recurse into subdirectories
            if !subDirs.isEmpty {
                await withTaskGroup(of: HyperScanItem.self) { group in
                    for (subPath, subName) in subDirs {
                        group.addTask(priority: .high) {
                            return await scan(
                                path: subPath,
                                name: subName,
                                context: context,
                                isRoot: false
                            )
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
            children: localItems.sorted { $0.size > $1.size }
        )
    }
}
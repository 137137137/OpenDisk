import Foundation
import Darwin

final class DiskScanner: @unchecked Sendable {
    private let context: ScanContext
    private let bufferSize = 1 * 1024 * 1024
    private let maxParallelDepth = 8
    private let minSubdirsForParallel = 2
    private let bufferPool: BufferPool
    private let firmlinkNamesSet: Set<String>

    init(context: ScanContext, onProgress: ((HyperScanProgress) -> Void)? = nil) {
        self.context = context
        self.bufferPool = BufferPool(bufferSize: bufferSize, poolSize: 64)
        self.firmlinkNamesSet = Set(["Users", "Applications", "Library", "System", "private", "usr", "bin", "sbin", "opt", "Volumes", "cores"])
    }

    @inline(__always)
    private func isFirmlinkName(_ namePtr: UnsafeRawPointer, _ nameLen: Int) -> Bool {
        for bytes in ScanFilterData.firmlinkNameBytes {
            if bytes.count == nameLen {
                if memcmp(namePtr, bytes, nameLen) == 0 {
                    return true
                }
            }
        }
        return false
    }

    @inline(__always)
    private func isVolumesName(_ namePtr: UnsafeRawPointer, _ nameLen: Int) -> Bool {
        if nameLen != 7 { return false }
        let expected: [UInt8] = [86, 111, 108, 117, 109, 101, 115]
        return memcmp(namePtr, expected, 7) == 0
    }

    @inline(__always)
    private func isDataName(_ namePtr: UnsafeRawPointer, _ nameLen: Int) -> Bool {
        if nameLen != 4 { return false }
        let expected: [UInt8] = [68, 97, 116, 97]
        return memcmp(namePtr, expected, 4) == 0
    }

    @inline(__always)
    private func isExcludedPath(_ path: String) -> Bool {
        return path.withCString { pathPtr -> Bool in
            let pathLen = strlen(pathPtr)
            for (prefix, prefixLen) in ScanFilterData.excludedPrefixData {
                if pathLen >= prefixLen && memcmp(pathPtr, prefix, prefixLen) == 0 {
                    return true
                }
            }
            return false
        }
    }

    func scan(path: String, name: String, parentDevice: dev_t? = nil) async -> HyperScanItem {
        if Task.isCancelled {
            return HyperScanItem(name: name, path: path, size: 0, isDirectory: true, children: [])
        }

        let device: dev_t
        if let parentDev = parentDevice {
            device = parentDev
        } else {
            var dirStat = stat()
            stat(path, &dirStat)
            device = dirStat.st_dev
        }

        return await scanRecursiveAsync(path: path, name: name, device: device, depth: 0)
    }

    // MARK: - Directory reading (shared by sync and async recursion)

    private enum DirectoryRead {
        case contents(files: [HyperScanItem], filesSize: Int64, subDirs: [(name: String, path: String)])
        case accessDenied
        case unreadable
    }

    /// Builds "prefix + name" without intermediate allocations. `prefix` is the
    /// parent path's UTF-8 bytes including a trailing slash.
    @inline(__always)
    private func makeChildPath(prefix: [UInt8], namePtr: UnsafeRawPointer, nameLen: Int) -> String {
        let total = prefix.count + nameLen
        return String(unsafeUninitializedCapacity: total) { dest in
            let base = UnsafeMutableRawPointer(dest.baseAddress!)
            prefix.withUnsafeBytes { src in
                base.copyMemory(from: src.baseAddress!, byteCount: src.count)
            }
            base.advanced(by: prefix.count).copyMemory(from: namePtr, byteCount: nameLen)
            return total
        }
    }

    /// Reads one directory with getattrlistbulk. The fd and read buffer are
    /// released before this returns, so nothing is held while children recurse.
    private func readDirectory(path: String, device: dev_t) -> DirectoryRead {
        let fd = open(path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else {
            return (errno == EACCES || errno == EPERM) ? .accessDenied : .unreadable
        }

        let buffer = bufferPool.acquire()
        defer {
            bufferPool.release(buffer)
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
        attrList.fileattr = attrgroup_t(UInt32(ATTR_FILE_LINKCOUNT) | UInt32(ATTR_FILE_ALLOCSIZE))

        var files = [HyperScanItem]()
        files.reserveCapacity(256)

        var filesSize: Int64 = 0
        var batchSizeAdded: Int64 = 0
        var batchItemsAdded: Int = 0

        var subDirs: [(name: String, path: String)] = []
        subDirs.reserveCapacity(64)

        let isDataVolumeRoot = (path == "/System/Volumes/Data")
        let isRoot = (path == "/")
        let isSystemVolumes = (path == "/System/Volumes")

        var pathPrefix = [UInt8]()
        pathPrefix.reserveCapacity(path.utf8.count + 1)
        pathPrefix.append(contentsOf: path.utf8)
        if pathPrefix.last != 0x2F {
            pathPrefix.append(0x2F)
        }

        while true {
            let count = getattrlistbulk(fd, &attrList, buffer, bufferSize, 0)
            if count <= 0 { break }

            var ptr = buffer
            for _ in 0..<count {
                let length = Int(ptr.loadUnaligned(as: UInt32.self))
                defer { ptr = ptr.advanced(by: length) }

                let returnedCommon = ptr.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
                let returnedFile = ptr.loadUnaligned(fromByteOffset: 16, as: UInt32.self)

                let nameDataOffset = Int(ptr.loadUnaligned(fromByteOffset: 24, as: Int32.self))
                let nameLen = Int(ptr.loadUnaligned(fromByteOffset: 28, as: UInt32.self)) - 1
                let namePtr = ptr.advanced(by: 24 + nameDataOffset)

                if nameLen > 0 && nameLen <= 2 {
                    let firstTwo = namePtr.loadUnaligned(as: UInt16.self)
                    if nameLen == 1 && (firstTwo & 0xFF) == 0x2E { continue }
                    if nameLen == 2 && firstTwo == 0x2E2E { continue }
                }

                if nameLen <= 0 || nameLen >= 1024 { continue }

                var currentOffset = 32
                var isDirectory = false
                if (returnedCommon & UInt32(ATTR_CMN_OBJTYPE)) != 0 {
                    let objType = ptr.loadUnaligned(fromByteOffset: currentOffset, as: UInt32.self)
                    currentOffset += 4
                    isDirectory = (objType == 2)
                }

                var inode: UInt64 = 0
                if (returnedCommon & UInt32(ATTR_CMN_FILEID)) != 0 {
                    inode = ptr.loadUnaligned(fromByteOffset: currentOffset, as: UInt64.self)
                    currentOffset += 8
                }

                var linkCount: UInt32 = 1
                if (returnedFile & UInt32(ATTR_FILE_LINKCOUNT)) != 0 {
                    linkCount = ptr.loadUnaligned(fromByteOffset: currentOffset, as: UInt32.self)
                    currentOffset += 4
                }

                var size: Int64 = 0
                if !isDirectory && (returnedFile & UInt32(ATTR_FILE_ALLOCSIZE)) != 0 {
                    if currentOffset + 8 <= length {
                        size = ptr.loadUnaligned(fromByteOffset: currentOffset, as: Int64.self)
                        if size < 0 || size > 1_000_000_000_000_000 {
                            size = 0
                        }
                    }
                }

                if isDataVolumeRoot && isFirmlinkName(namePtr, nameLen) { continue }
                if isRoot && isVolumesName(namePtr, nameLen) { continue }
                if isDirectory && isSystemVolumes && isDataName(namePtr, nameLen) { continue }

                let itemName = PathAccumulator.nameString(from: namePtr, length: nameLen)
                let itemPath = makeChildPath(prefix: pathPrefix, namePtr: namePtr, nameLen: nameLen)

                if isDirectory {
                    subDirs.append((itemName, itemPath))
                } else {
                    // Only hard-linked files (nlink > 1) can be double-counted,
                    // so only those pay for deduplication tracking.
                    if linkCount > 1 && inode > 0 {
                        if !context.inodeTracker.visit(device: device, inode: inode) {
                            size = 0
                        }
                    }

                    filesSize += size
                    batchSizeAdded += size
                    batchItemsAdded += 1

                    files.append(HyperScanItem(
                        name: itemName,
                        path: itemPath,
                        size: size,
                        isDirectory: false,
                        children: nil
                    ))
                }
            }

            if batchSizeAdded > 0 || batchItemsAdded > 0 {
                context.stats.add(bytes: batchSizeAdded, items: batchItemsAdded)
                batchSizeAdded = 0
                batchItemsAdded = 0
            }
        }

        return .contents(files: files, filesSize: filesSize, subDirs: subDirs)
    }

    // MARK: - Recursion

    private func scanRecursiveSync(path: String, name: String, device: dev_t, depth: Int) -> HyperScanItem {
        if depth < 3 && isExcludedPath(path) {
            return HyperScanItem(name: name, path: path, size: 0, isDirectory: true, children: [])
        }

        guard case .contents(var localItems, var localSize, let subDirs) = readDirectory(path: path, device: device) else {
            return HyperScanItem(name: name, path: path, size: 0, isDirectory: true, children: [])
        }

        let nextDepth = depth + 1
        for (subName, subPath) in subDirs {
            let item = scanRecursiveSync(path: subPath, name: subName, device: device, depth: nextDepth)
            localItems.append(item)
            localSize += item.size
        }

        return HyperScanItem(name: name, path: path, size: localSize, isDirectory: true, children: localItems)
    }

    private func scanRecursiveAsync(path: String, name: String, device: dev_t, depth: Int) async -> HyperScanItem {
        if Task.isCancelled {
            return HyperScanItem(name: name, path: path, size: 0, isDirectory: true, children: [])
        }

        if depth < 3 && isExcludedPath(path) {
            return HyperScanItem(name: name, path: path, size: 0, isDirectory: true, children: [])
        }

        let localItems: [HyperScanItem]
        let localSize: Int64
        let subDirs: [(name: String, path: String)]

        switch readDirectory(path: path, device: device) {
        case .contents(let files, let filesSize, let dirs):
            localItems = files
            localSize = filesSize
            subDirs = dirs
        case .accessDenied:
            return await scanWithFileManager(path: path, name: name, device: device, depth: depth)
        case .unreadable:
            return HyperScanItem(name: name, path: path, size: 0, isDirectory: true, children: [])
        }

        var allItems = localItems
        var totalSize = localSize

        if !subDirs.isEmpty {
            let nextDepth = depth + 1

            if subDirs.count < minSubdirsForParallel || depth > maxParallelDepth {
                for (subName, subPath) in subDirs {
                    let item = scanRecursiveSync(path: subPath, name: subName, device: device, depth: nextDepth)
                    allItems.append(item)
                    totalSize += item.size
                }
            } else {
                await withTaskGroup(of: HyperScanItem.self) { group in
                    for (subName, subPath) in subDirs {
                        group.addTask {
                            return await self.scanRecursiveAsync(path: subPath, name: subName, device: device, depth: nextDepth)
                        }
                    }

                    for await item in group {
                        allItems.append(item)
                        totalSize += item.size
                    }
                }
            }
        }

        return HyperScanItem(name: name, path: path, size: totalSize, isDirectory: true, children: allItems)
    }

    func scanRoot() async -> HyperScanItem {
        var rootChildren: [HyperScanItem] = []
        var totalSize: Int64 = 0

        guard let allRootContents = try? FileManager.default.contentsOfDirectory(atPath: "/") else {
            return HyperScanItem(name: "/", path: "/", size: 0, isDirectory: true, children: [])
        }

        let skipPaths = Set(["Volumes", ".VolumeIcon.icns", ".file"])
        var directoriesToScan: [(name: String, path: String)] = []

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

        await withTaskGroup(of: HyperScanItem.self) { group in
            for (name, path) in directoriesToScan {
                group.addTask(priority: .userInitiated) {
                    if name == "System" {
                        return await self.scanSystemWithoutData(device: rootDevice)
                    } else {
                        return await self.scanRecursiveAsync(path: path, name: name, device: rootDevice, depth: 0)
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
                    group.addTask(priority: .high) {
                        var volumesChildren: [HyperScanItem] = []
                        var volumesSize: Int64 = 0

                        if let volumeContents = try? FileManager.default.contentsOfDirectory(atPath: fullPath) {
                            for volumeName in volumeContents {
                                if volumeName == "Data" { continue }

                                let volumePath = "\(fullPath)/\(volumeName)"
                                let item = await self.scanRecursiveAsync(path: volumePath, name: volumeName, device: device, depth: 1)
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
                        return await self.scanRecursiveAsync(path: fullPath, name: itemName, device: device, depth: 1)
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

                if isDataVolumeRoot && firmlinkNamesSet.contains(itemName) { continue }
                if isRoot && itemName == "Volumes" { continue }

                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir) {
                    if isDir.boolValue {
                        subDirs.append((fullPath, itemName))
                    } else {
                        var fileStat = stat()
                        if stat(fullPath, &fileStat) == 0 {
                            let allocSize = Int64(fileStat.st_blocks) * 512
                            if allocSize > 0 {
                                if fileStat.st_nlink <= 1 || context.inodeTracker.visit(device: fileStat.st_dev, inode: fileStat.st_ino) {
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

            if localSize > 0 {
                context.stats.add(bytes: localSize, items: localItems.count)
            }

            if !subDirs.isEmpty {
                let nextDepth = depth + 1

                if subDirs.count < minSubdirsForParallel || depth > maxParallelDepth {
                    for (subPath, subName) in subDirs {
                        let item = scanRecursiveSync(path: subPath, name: subName, device: device, depth: nextDepth)
                        localItems.append(item)
                        localSize += item.size
                    }
                } else {
                    await withTaskGroup(of: HyperScanItem.self) { group in
                        for (subPath, subName) in subDirs {
                            group.addTask {
                                return await self.scanRecursiveAsync(path: subPath, name: subName, device: device, depth: nextDepth)
                            }
                        }

                        for await child in group {
                            localItems.append(child)
                            localSize += child.size
                        }
                    }
                }
            }
        } catch { }

        return HyperScanItem(name: name, path: path, size: localSize, isDirectory: true, children: localItems)
    }
}

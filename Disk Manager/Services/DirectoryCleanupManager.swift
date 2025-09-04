//
//  DirectoryCleanupManager.swift
//  Disk Manager
//
//  Created by 137137137 on 9/4/25.
//

import Foundation
import SwiftUI

struct CleanupOptions {
    var dsStoreFiles = true
    var fseventsdFolders = false  // Default off for safety
    var spotlightFolders = true
    var trashesFolders = true
    var temporaryItems = true
}

struct ScanResults {
    var dsStoreCount = 0
    var fseventsdCount = 0
    var spotlightCount = 0
    var trashesCount = 0
    var temporaryItemsCount = 0
    
    var totalCount: Int {
        dsStoreCount + fseventsdCount + spotlightCount + trashesCount + temporaryItemsCount
    }
}

@MainActor
class DirectoryCleanupManager: ObservableObject {
    @Published var isScanning = false
    @Published var isCleaning = false
    @Published var progressMessage = ""
    @Published var cleanupOptions = CleanupOptions()
    @Published var scanResults = ScanResults()
    @Published var hasScanned = false
    
    // Progress tracking like DiskAnalyzer
    @Published var scannedBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var progressPercentage: Double = 0.0
    
    private var scanTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    
    // Files and folders to look for
    private let targetFiles: [String: [String]] = [
        "dsStore": [".DS_Store"],
        "fseventsd": [".fseventsd"],
        "spotlight": [".Spotlight-V100"],
        "trashes": [".Trashes"],
        "temporary": [".TemporaryItems", ".DocumentRevisions-V100"]
    ]
    
    var totalFoundItems: Int {
        scanResults.totalCount
    }
    
    var totalSelectedItems: Int {
        var count = 0
        if cleanupOptions.dsStoreFiles { count += scanResults.dsStoreCount }
        if cleanupOptions.fseventsdFolders { count += scanResults.fseventsdCount }
        if cleanupOptions.spotlightFolders { count += scanResults.spotlightCount }
        if cleanupOptions.trashesFolders { count += scanResults.trashesCount }
        if cleanupOptions.temporaryItems { count += scanResults.temporaryItemsCount }
        return count
    }
    
    var formattedScannedBytes: String {
        return ByteCountFormatter.string(fromByteCount: scannedBytes, countStyle: .file)
    }
    
    var formattedTotalBytes: String {
        return ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }
    
    func resetScan() {
        hasScanned = false
        scanResults = ScanResults()
        scanTask?.cancel()
        cleanupTask?.cancel()
    }
    
    func scanDirectory(_ path: String, totalUsedSpace: Int64) async {
        scanTask?.cancel()
        
        isScanning = true
        progressMessage = "Scanning directory..."
        scanResults = ScanResults()
        hasScanned = false
        scannedBytes = 0
        totalBytes = totalUsedSpace // Use the total used space from sidebar like analysis tab
        progressPercentage = 0.0
        
        scanTask = Task { [weak self] in
            guard let self = self else { return }
            
            await self.performDirectoryScan(path: path)
            
            await MainActor.run {
                self.isScanning = false
                self.hasScanned = true
                self.progressMessage = ""
                self.progressPercentage = 100.0
            }
        }
        
        await scanTask?.value
    }
    
    private func performDirectoryScan(path: String) async {
        // Use DiskAnalyzer approach - single pass with enumerator
        let results = await scanWithEnumerator(path: path)
        
        await MainActor.run {
            self.scanResults = results
        }
    }
    
    
    private func scanWithEnumerator(path: String) async -> ScanResults {
        return await Task.detached { [weak self] in
            guard let self = self else { return ScanResults() }
            
            let keys: Set<URLResourceKey> = [
                .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
                .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
                .nameKey, .pathKey
            ]
            
            guard let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: path),
                includingPropertiesForKeys: Array(keys),
                options: [.skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else {
                return ScanResults()
            }
            
            var results = ScanResults()
            var processedSize: Int64 = 0
            var itemsProcessed = 0
            var lastProgressUpdate = 0
            
            while let item = enumerator.nextObject() {
                guard let url = item as? URL else { continue }
                
                do {
                    let rv = try url.resourceValues(forKeys: keys)
                    if rv.isSymbolicLink == true { continue }
                    
                    let fileName = rv.name ?? url.lastPathComponent
                    let sz = Int64(rv.totalFileAllocatedSize ?? rv.fileAllocatedSize ?? 0)
                    processedSize += sz
                    itemsProcessed += 1
                    
                    // Check if it's one of our target files/folders
                    if self.targetFiles["dsStore"]?.contains(fileName) == true {
                        results.dsStoreCount += 1
                    } else if self.targetFiles["fseventsd"]?.contains(fileName) == true && rv.isDirectory == true {
                        if await !self.isSystemVolume(url.deletingLastPathComponent().path) {
                            results.fseventsdCount += 1
                        }
                    } else if self.targetFiles["spotlight"]?.contains(fileName) == true && rv.isDirectory == true {
                        results.spotlightCount += 1
                    } else if self.targetFiles["trashes"]?.contains(fileName) == true && rv.isDirectory == true {
                        results.trashesCount += 1
                    } else if self.targetFiles["temporary"]?.contains(fileName) == true {
                        results.temporaryItemsCount += 1
                    }
                    
                    // Update progress like DiskAnalyzer - every 500 items or every 10MB
                    if itemsProcessed - lastProgressUpdate >= 500 || (sz > 0 && processedSize % (10 * 1024 * 1024) < sz) {
                        lastProgressUpdate = itemsProcessed
                        
                        // Capture values to avoid concurrency issues
                        let capturedSize = processedSize
                        let capturedTotal = await MainActor.run { self.totalBytes }
                        let capturedPercent = capturedTotal > 0 ? min(100.0, Double(capturedSize) / Double(capturedTotal) * 100.0) : 0
                        let capturedCount = results.totalCount
                        
                        await MainActor.run {
                            self.scannedBytes = capturedSize
                            self.progressPercentage = capturedPercent
                            self.progressMessage = "Scanning... found \(capturedCount) items"
                        }
                    }
                    
                } catch {
                    continue
                }
                
                if Task.isCancelled { break }
            }
            
            // Final update
            let finalSize = processedSize
            let finalCount = results.totalCount
            await MainActor.run {
                self.scannedBytes = finalSize
                self.progressPercentage = 100.0
                self.progressMessage = "Scan complete - found \(finalCount) items"
            }
            
            return results
        }.value
    }
    
    /* OLD RECURSIVE METHOD - REPLACED WITH ENUMERATOR APPROACH
    private func scanDirectoryRecursive(_ path: String, visited: inout Set<String>, currentScannedBytes: inout Int64) async -> ScanResults {
        // Prevent infinite loops from symlinks
        let canonicalPath = (path as NSString).resolvingSymlinksInPath
        if visited.contains(canonicalPath) {
            return ScanResults()
        }
        visited.insert(canonicalPath)
        
        var results = ScanResults()
        
        do {
            let contents = try FileManager.default.contentsOfDirectory(atPath: path)
            
            // Check current directory for target files/folders and track file sizes
            for item in contents {
                let fullPath = path.hasSuffix("/") ? path + item : path + "/" + item
                
                // Get file size for progress tracking
                do {
                    let url = URL(fileURLWithPath: fullPath)
                    let resourceValues = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
                    let size = Int64(resourceValues.totalFileAllocatedSize ?? resourceValues.fileAllocatedSize ?? 0)
                    currentScannedBytes += size
                    
                    // Update progress more frequently - every 10MB or every 100 items
                    if (currentScannedBytes % (10 * 1024 * 1024) < size) || (results.totalCount % 100 == 0) {
                        await MainActor.run {
                            self.scannedBytes = currentScannedBytes
                            if self.totalBytes > 0 {
                                self.progressPercentage = min(100.0, Double(currentScannedBytes) / Double(self.totalBytes) * 100.0)
                            }
                            self.progressMessage = "Scanning... found \(results.totalCount) items"
                        }
                    }
                } catch {
                    // Continue even if we can't get file size
                }
                
                // Check if it's one of our target files/folders
                if targetFiles["dsStore"]?.contains(item) == true {
                    results.dsStoreCount += 1
                } else if targetFiles["fseventsd"]?.contains(item) == true {
                    var isDirectory: ObjCBool = false
                    if FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDirectory) && isDirectory.boolValue {
                        // Only count .fseventsd if it's not on system volume for safety
                        if !isSystemVolume(path) {
                            results.fseventsdCount += 1
                        }
                    }
                } else if targetFiles["spotlight"]?.contains(item) == true {
                    var isDirectory: ObjCBool = false
                    if FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDirectory) && isDirectory.boolValue {
                        results.spotlightCount += 1
                    }
                } else if targetFiles["trashes"]?.contains(item) == true {
                    var isDirectory: ObjCBool = false
                    if FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDirectory) && isDirectory.boolValue {
                        results.trashesCount += 1
                    }
                } else if targetFiles["temporary"]?.contains(item) == true {
                    results.temporaryItemsCount += 1
                }
            }
            
            // Recursively scan subdirectories (but skip the ones we just found)
            for item in contents {
                let fullPath = path.hasSuffix("/") ? path + item : path + "/" + item
                var isDirectory: ObjCBool = false
                
                if FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDirectory) && 
                   isDirectory.boolValue &&
                   !item.hasPrefix(".") && // Skip hidden directories for performance
                   !shouldSkipDirectory(item) {
                    
                    let subResults = await scanDirectoryRecursive(fullPath, visited: &visited, currentScannedBytes: &currentScannedBytes)
                    results.dsStoreCount += subResults.dsStoreCount
                    results.fseventsdCount += subResults.fseventsdCount
                    results.spotlightCount += subResults.spotlightCount
                    results.trashesCount += subResults.trashesCount
                    results.temporaryItemsCount += subResults.temporaryItemsCount
                }
                
                if Task.isCancelled {
                    break
                }
            }
            
        } catch {
            // Skip directories we can't access
            return results
        }
        
        return results
    }
    
    private func scanDirectoryRecursive(_ path: String) async -> ScanResults {
        var visited = Set<String>()
        var currentScannedBytes: Int64 = 0
        return await scanDirectoryRecursive(path, visited: &visited, currentScannedBytes: &currentScannedBytes)
    }
    */
    
    private func shouldSkipDirectory(_ name: String) -> Bool {
        // Skip system directories and large directories that are unlikely to have our target files
        let skipList = [
            "System", "Library", "usr", "bin", "sbin", "private", "cores", "dev", "etc", "var", "tmp",
            "Applications", ".app", "node_modules", ".git", ".svn", ".hg"
        ]
        
        return skipList.contains { skip in
            name == skip || name.hasSuffix(skip)
        }
    }
    
    private func isSystemVolume(_ path: String) -> Bool {
        // Check if this is a system volume where we shouldn't remove .fseventsd
        return path.hasPrefix("/System") || 
               path.hasPrefix("/") && !path.hasPrefix("/Volumes/") && 
               !path.contains("/Users/")
    }
    
    func performCleanup(_ path: String) async {
        cleanupTask?.cancel()
        
        isCleaning = true
        progressMessage = "Preparing cleanup..."
        
        cleanupTask = Task { [weak self] in
            guard let self = self else { return }
            
            var deletedCount = 0
            let totalToDelete = await MainActor.run { self.totalSelectedItems }
            
            await self.cleanupDirectoryRecursive(path, deletedCount: &deletedCount, totalToDelete: totalToDelete)
            
            await MainActor.run {
                self.isCleaning = false
                self.progressMessage = ""
                // Rescan to update counts
                Task {
                    await self.scanDirectory(path)
                }
            }
        }
        
        await cleanupTask?.value
    }
    
    private func cleanupDirectoryRecursive(_ path: String, deletedCount: inout Int, totalToDelete: Int, visited: inout Set<String>) async {
        // Prevent infinite loops from symlinks
        let canonicalPath = (path as NSString).resolvingSymlinksInPath
        if visited.contains(canonicalPath) {
            return
        }
        visited.insert(canonicalPath)
        
        do {
            let contents = try FileManager.default.contentsOfDirectory(atPath: path)
            
            // Clean up target files/folders in current directory
            for item in contents {
                let fullPath = path.hasSuffix("/") ? path + item : path + "/" + item
                var shouldDelete = false
                
                if cleanupOptions.dsStoreFiles && targetFiles["dsStore"]?.contains(item) == true {
                    shouldDelete = true
                } else if cleanupOptions.fseventsdFolders && targetFiles["fseventsd"]?.contains(item) == true {
                    var isDirectory: ObjCBool = false
                    if FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDirectory) && 
                       isDirectory.boolValue && !isSystemVolume(path) {
                        shouldDelete = true
                    }
                } else if cleanupOptions.spotlightFolders && targetFiles["spotlight"]?.contains(item) == true {
                    var isDirectory: ObjCBool = false
                    if FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDirectory) && isDirectory.boolValue {
                        shouldDelete = true
                    }
                } else if cleanupOptions.trashesFolders && targetFiles["trashes"]?.contains(item) == true {
                    var isDirectory: ObjCBool = false
                    if FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDirectory) && isDirectory.boolValue {
                        shouldDelete = true
                    }
                } else if cleanupOptions.temporaryItems && targetFiles["temporary"]?.contains(item) == true {
                    shouldDelete = true
                }
                
                if shouldDelete {
                    do {
                        try FileManager.default.removeItem(atPath: fullPath)
                        deletedCount += 1
                        
                        await MainActor.run {
                            let progress = totalToDelete > 0 ? Double(deletedCount) / Double(totalToDelete) * 100.0 : 0
                            self.progressMessage = "Cleaning... \(deletedCount)/\(totalToDelete) (\(Int(progress))%)"
                        }
                    } catch {
                        print("Error deleting \(fullPath): \(error)")
                    }
                }
                
                if Task.isCancelled {
                    return
                }
            }
            
            // Recursively clean subdirectories
            for item in contents {
                let fullPath = path.hasSuffix("/") ? path + item : path + "/" + item
                var isDirectory: ObjCBool = false
                
                if FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDirectory) && 
                   isDirectory.boolValue &&
                   !shouldSkipDirectory(item) {
                    
                    await cleanupDirectoryRecursive(fullPath, deletedCount: &deletedCount, totalToDelete: totalToDelete, visited: &visited)
                }
                
                if Task.isCancelled {
                    return
                }
            }
            
        } catch {
            // Skip directories we can't access
            return
        }
    }
    
    private func cleanupDirectoryRecursive(_ path: String, deletedCount: inout Int, totalToDelete: Int) async {
        var visited = Set<String>()
        await cleanupDirectoryRecursive(path, deletedCount: &deletedCount, totalToDelete: totalToDelete, visited: &visited)
    }
}

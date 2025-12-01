//
//  DirectoryCleanupManager.swift
//  Disk Manager
//
//  Created by 137137137 on 9/4/25.
//

import Foundation
import Combine

struct CleanupOptions {
    var dsStoreFiles = true  // Only option we need
}

struct ScanResults {
    var dsStoreCount = 0
    
    var totalCount: Int {
        dsStoreCount
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
    
    // Only look for .DS_Store files
    private let dsStoreFileName = ".DS_Store"
    
    var totalFoundItems: Int {
        scanResults.totalCount
    }
    
    var totalSelectedItems: Int {
        cleanupOptions.dsStoreFiles ? scanResults.dsStoreCount : 0
    }
    
    var formattedScannedBytes: String {
        return ByteFormatter.formatFileSize(scannedBytes)
    }

    var formattedTotalBytes: String {
        return ByteFormatter.formatFileSize(totalBytes)
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
                    
                    // Check if it's a .DS_Store file
                    if fileName == self.dsStoreFileName {
                        results.dsStoreCount += 1
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
    
    private func shouldSkipDirectory(_ name: String) -> Bool {
        return PathFilter.shouldSkipDirectoryForCleanup(name)
    }
    
    func performCleanup(_ path: String, totalUsedSpace: Int64) async {
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
                    await self.scanDirectory(path, totalUsedSpace: totalUsedSpace)
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
                
                if cleanupOptions.dsStoreFiles && item == dsStoreFileName {
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

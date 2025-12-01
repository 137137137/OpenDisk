import Foundation

// MARK: - Scan Item Model

/// Represents a scanned file or directory with its metadata.
///
/// Uses path hash as ID to avoid expensive UUID generation during scanning.
/// Supports lazy conversion to `FolderItem` for UI display.
struct HyperScanItem: Identifiable, Sendable {
    var id: Int { path.hashValue }
    let name: String
    let path: String
    let size: Int64
    let isDirectory: Bool
    var children: [HyperScanItem]?

    /// Converts to FolderItem for immediate display.
    ///
    /// Only processes top 100 items for fast initial rendering.
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

    /// Parallel async conversion for background processing.
    ///
    /// Processes top 50 items in parallel using TaskGroup.
    static func toFolderItemAsync(_ item: HyperScanItem) async -> FolderItem {
        let sharedDate = Date()

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
                for child in sortedChildren.prefix(50) {
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

// MARK: - Scan Progress Model

/// Represents the current progress of a disk scan operation.
struct HyperScanProgress: Sendable {
    let scannedBytes: Int64
    let totalUsedBytes: Int64
    let currentPath: String
    let itemsScanned: Int

    /// Progress as a fraction from 0.0 to 1.0.
    var fractionCompleted: Double {
        guard totalUsedBytes > 0 else { return 0 }
        return min(Double(scannedBytes) / Double(totalUsedBytes), 1.0)
    }
}

// MARK: - HyperScanner Extension

extension HyperScanner {
    /// Converts an array of scan items to folder items.
    static func convertToFolderItems(_ items: [HyperScanItem]) -> [FolderItem] {
        return items.map { $0.toFolderItem() }
    }
}

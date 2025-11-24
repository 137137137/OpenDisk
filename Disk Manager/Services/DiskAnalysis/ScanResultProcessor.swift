import Foundation

/// Processes and converts scan results from HyperScanner to FolderItems
struct ScanResultProcessor {

    /// Converts HyperScanItem tree to FolderItem tree
    static func convertToFolderItems(_ hyperItem: HyperScanItem) -> [FolderItem] {
        // If the hyperItem has children, convert them; otherwise return the item itself as an array
        if let children = hyperItem.children {
            return children.map { convertItem($0) }
        } else {
            return [convertItem(hyperItem)]
        }
    }

    /// Calculate and update percentages for root items
    static func calculatePercentages(for items: inout [FolderItem]) {
        let totalSize = items.reduce(0) { $0 + $1.size }
        guard totalSize > 0 else { return }

        for i in 0..<items.count {
            items[i].percentage = Double(items[i].size) / Double(totalSize) * 100.0
        }
    }

    /// Filter and sort items for display
    static func filterAndSort(_ items: [FolderItem], minSize: Int64 = 1024) -> [FolderItem] {
        return items
            .filter { $0.size > minSize }
            .sorted()
    }

    private static func convertItem(_ hyperItem: HyperScanItem) -> FolderItem {
        // Use the built-in conversion method from HyperScanItem
        return hyperItem.toFolderItem()
    }
}
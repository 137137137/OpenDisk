import SwiftUI

/// Scan results list. Shown from the first moments of a scan: rows appear
/// and re-sort live as sizes stream in. The status footer is provided by
/// the containing view (shared with the chart modes).
struct ScanResultsView: View {
    let items: [FolderItem]
    /// Bumped by the analyzer whenever `items` is replaced — a cheap
    /// animation trigger that avoids diffing the whole row array.
    let displayVersion: Int
    /// Paths of the multi-selected rows, and the same selection as
    /// collector payloads for group drags.
    var selectedPaths: Set<String> = []
    var selectionFiles: [CollectedFile] = []
    let onFolderTap: (FolderItem) -> Void

    var body: some View {
        // A ScrollView + LazyVStack rather than a List: SwiftUI's List
        // intercepts row drag gestures on macOS, which prevents dragging a
        // row into the Collector. This keeps rows fully draggable.
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(items) { item in
                    FolderRowView(
                        item: item,
                        isSelected: selectedPaths.contains(item.path),
                        selectionFiles: selectionFiles
                    ) {
                        onFolderTap(item)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        // Snappy, not the heavy 0.35s ease — folder navigation should feel
        // immediate, like Finder, while still animating live-scan re-sorts.
        .animation(.snappy(duration: 0.18), value: displayVersion)
    }
}

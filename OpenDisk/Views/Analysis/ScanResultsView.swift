import SwiftUI

struct ScanResultsView: View {
    let items: [FolderItem]
    let displayVersion: Int
    var selectedPaths: Set<String> = []
    var selectionFiles: [CollectedFile] = []
    var onQuickLook: ((FolderItem) -> Void)? = nil
    let onFolderTap: (FolderItem) -> Void

    var body: some View {
        let maxSize = items.map(\.size).max() ?? 0
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(items) { item in
                    FolderRowView(
                        item: item,
                        isSelected: selectedPaths.contains(item.path),
                        selectionFiles: selectionFiles,
                        sizeFraction: maxSize > 0 ? Double(item.size) / Double(maxSize) : nil,
                        onQuickLook: onQuickLook
                    ) {
                        onFolderTap(item)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .animation(.snappy(duration: 0.18), value: displayVersion)
        .task(id: displayVersion) {
            await FileIcon.prewarm(items.map(\.path))
        }
    }
}

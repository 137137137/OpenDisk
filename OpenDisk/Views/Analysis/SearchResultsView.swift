import SwiftUI

struct SearchResultsView: View {
    let items: [FolderItem]
    let resultsVersion: Int
    let totalMatches: Int
    let isRunning: Bool
    let resultsArePartial: Bool
    let query: String
    var selectedPaths: Set<String> = []
    var focusedPath: String? = nil
    var showsDetailColumns: Bool = true
    var kindWidth: CGFloat? = nil
    var selectionFiles: [CollectedFile] = []
    var onQuickLook: ((FolderItem) -> Void)? = nil
    let onSelect: (FolderItem) -> Void
    let onOpen: (FolderItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if !items.isEmpty {
                header
                Divider()
            }

            if items.isEmpty && isRunning {
                Spacer()
                ProgressView("Searching…")
                Spacer()
            } else if items.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                FolderRowView(
                                    item: item,
                                    index: index,
                                    locationDetail: location(of: item),
                                    isSelected: selectedPaths.contains(item.path),
                                    showsDetailColumns: showsDetailColumns,
                                    kindWidth: kindWidth,
                                    selectionFiles: selectionFiles,
                                    onQuickLook: onQuickLook,
                                    onSelect: { onSelect(item) },
                                    onOpen: { onOpen(item) }
                                )
                                .id(item.path)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: focusedPath) { _, path in
                        guard let path, items.contains(where: { $0.path == path }) else { return }
                        proxy.scrollTo(path)
                    }
                }
                .task(id: resultsVersion) {
                    await FileIcon.prewarm(items.map(\.path))
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            if resultsArePartial {
                Text("· scan in progress, results may be incomplete")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if isRunning {
                ProgressView()
                    .controlSize(.mini)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private var summary: String {
        let matches = String(localized: "\(totalMatches) matches")
        if totalMatches > items.count {
            return "\(matches) · " + String(localized: "showing the largest \(items.count)")
        }
        return "\(matches) · " + String(localized: "largest first")
    }

    private func location(of item: FolderItem) -> String {
        ((item.path as NSString).deletingLastPathComponent as NSString)
            .abbreviatingWithTildeInPath
    }
}

import SwiftUI

/// Search results list, shown in place of the directory list while a
/// query is active. Rows are the same draggable/collectible rows as the
/// directory listing, with the containing folder as a second line so hits
/// from anywhere in the tree stay identifiable.
struct SearchResultsView: View {
    let items: [FolderItem]
    /// Total matches before the display cap (`SearchIndex.resultLimit`).
    let totalMatches: Int
    let isRunning: Bool
    /// The scan was still in flight when these results were computed.
    let resultsArePartial: Bool
    let query: String
    /// Paths of the multi-selected rows, and the same selection as
    /// collector payloads for group drags.
    var selectedPaths: Set<String> = []
    var selectionFiles: [CollectedFile] = []
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
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            FolderRowView(
                                item: item,
                                locationDetail: location(of: item),
                                isSelected: selectedPaths.contains(item.path),
                                selectionFiles: selectionFiles
                            ) {
                                onOpen(item)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                // Icons resolve in display order before their rows scroll
                // into view; scrolling then blits cached bitmaps instead
                // of racing per-row loads.
                .task(id: items.map(\.path)) {
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
        if totalMatches > items.count {
            return "Largest \(items.count) of \(totalMatches.formatted()) matches"
        }
        return totalMatches == 1
            ? "1 match · largest first"
            : "\(totalMatches.formatted()) matches · largest first"
    }

    /// Containing folder, home-abbreviated ("~/Library/Caches").
    private func location(of item: FolderItem) -> String {
        ((item.path as NSString).deletingLastPathComponent as NSString)
            .abbreviatingWithTildeInPath
    }
}

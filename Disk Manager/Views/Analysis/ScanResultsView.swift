import SwiftUI

/// Scan results list. Shown from the first moments of a scan: rows appear
/// and re-sort live as sizes stream in. The status footer is provided by
/// the containing view (shared with the chart modes).
struct ScanResultsView: View {
    let items: [FolderItem]
    /// Bumped by the analyzer whenever `items` is replaced — a cheap
    /// animation trigger that avoids diffing the whole row array.
    let displayVersion: Int
    /// Present only at a volume's scan root, after the scan completes.
    var hiddenSpace: HiddenSpaceInfo?
    let onFolderTap: (FolderItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            List(items) { item in
                FolderRowView(item: item) {
                    onFolderTap(item)
                }
            }
            .listStyle(.plain)
            .animation(.default, value: displayVersion)

            if let hiddenSpace {
                Divider()
                HiddenSpaceRow(info: hiddenSpace)
            }
        }
    }
}

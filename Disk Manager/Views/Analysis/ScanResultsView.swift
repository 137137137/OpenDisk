import SwiftUI

/// Scan results list. Shown from the first moments of a scan: rows appear
/// and re-sort live as sizes stream in. The status footer is provided by
/// the containing view (shared with the chart modes).
struct ScanResultsView: View {
    let items: [FolderItem]
    let onFolderTap: (FolderItem) -> Void

    var body: some View {
        List(items) { item in
            FolderRowView(item: item) {
                onFolderTap(item)
            }
        }
        .listStyle(.plain)
        .animation(.default, value: items)
    }
}

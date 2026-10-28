import SwiftUI

struct ScanResultsView<Header: View>: View {
    let items: [FolderItem]
    let displayVersion: Int
    var selectedPaths: Set<String> = []
    var focusedPath: String? = nil
    var showsDetailColumns: Bool = true
    var selectionFiles: [CollectedFile] = []
    var onQuickLook: ((FolderItem) -> Void)? = nil
    let onSelect: (FolderItem) -> Void
    let onOpen: (FolderItem) -> Void
    @ViewBuilder let header: Header

    var body: some View {
        ScrollViewReader { proxy in
            scrollContent
                .onAppear {
                    guard let focusedPath, items.contains(where: { $0.path == focusedPath }) else { return }
                    proxy.scrollTo(focusedPath)
                }
                .onChange(of: focusedPath) { _, path in
                    guard let path, items.contains(where: { $0.path == path }) else { return }
                    proxy.scrollTo(path)
                }
        }
        .animation(.snappy(duration: 0.18), value: displayVersion)
        .task(id: displayVersion) {
            await FileIcon.prewarm(items.map(\.path))
        }
    }

    @ViewBuilder
    private var scrollContent: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    rows
                }
                .padding(.bottom, 4)
            }
            .safeAreaBar(edge: .top) {
                header
            }
            .scrollEdgeEffectStyle(.hard, for: .top)
        } else {
            pinnedHeaderScrollContent
        }
        #else
        pinnedHeaderScrollContent
        #endif
    }

    private var pinnedHeaderScrollContent: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    rows
                } header: {
                    header
                        .background(.background)
                        .overlay(alignment: .bottom) { Divider() }
                }
            }
            .padding(.bottom, 4)
        }
    }

    private var rows: some View {
        let maxSize = items.map(\.size).max() ?? 0
        return ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            FolderRowView(
                item: item,
                index: index,
                isSelected: selectedPaths.contains(item.path)
                    || (item.path.hasPrefix("::") && focusedPath == item.path),
                showsDetailColumns: showsDetailColumns,
                selectionFiles: selectionFiles,
                sizeFraction: maxSize > 0 ? Double(item.size) / Double(maxSize) : nil,
                onQuickLook: onQuickLook,
                onSelect: { onSelect(item) },
                onOpen: { onOpen(item) }
            )
            .id(item.path)
        }
    }
}

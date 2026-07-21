import AppKit
import SwiftUI

/// Analysis screen for one disk (pushed from the disk picker): scans it,
/// streams results live, and hosts breadcrumb navigation through them —
/// a split view with the folder list on the left and the rings chart on
/// the right, both updating as the scan runs.
///
/// Navigation chrome is standard: the stack's back button returns to the
/// disk picker, refresh lives in the toolbar, and the breadcrumb path bar
/// sits in the content layer with no custom background.
struct DiskAnalysisView: View {
    let rootPath: String
    let rootName: String

    @Environment(ScanAccess.self) private var scanAccess
    @State private var analyzer = DiskAnalyzer()
    @State private var collector = Collector()
    @State private var isCollectorTargeted = false
    @State private var currentPath: String
    @State private var breadcrumbs: [String] = []
    @State private var hasInitiallyScanned = false
    @State private var searchText = ""
    @State private var searchPresented = false
    /// Multi-selection (shift-click ranges, ⌘-click toggles) across the
    /// visible list, keyed by path like everything else. A drag from any
    /// selected row carries the whole selection to the Collector.
    @State private var selectedPaths = Set<String>()
    /// The last plainly clicked row — the fixed end of a shift-click range.
    @State private var selectionAnchor: String?
    /// Column sort for the directory list (search keeps its own relevance
    /// order). Defaults to largest-first, matching the scan's own ordering.
    @State private var sort: SortField = .size
    @State private var sortAscending = false
    private let totalUsedDiskSpace: Int64

    init(
        rootPath: String,
        rootName: String = "Computer",
        totalUsedSpace: Int64 = 0
    ) {
        self.rootPath = rootPath
        self.rootName = rootName
        self.totalUsedDiskSpace = totalUsedSpace
        self._currentPath = State(initialValue: rootPath)
    }

    var body: some View {
        VStack(spacing: 0) {
            BreadcrumbBar(
                currentPath: currentPath,
                rootPath: rootPath,
                rootName: rootName,
                onNavigate: navigateToPath
            )

            if !analyzer.rootItems.isEmpty {
                // The split starts at 60% list / 40% chart (ideal widths
                // seed HSplitView's initial divider position); the divider
                // stays user-draggable.
                GeometryReader { geometry in
                    HSplitView {
                        listPane
                            .frame(
                                minWidth: 320,
                                idealWidth: geometry.size.width * 0.6,
                                maxWidth: .infinity, maxHeight: .infinity
                            )

                        chartPane
                            .frame(
                                minWidth: 280,
                                idealWidth: geometry.size.width * 0.4,
                                maxWidth: .infinity, maxHeight: .infinity
                            )
                    }
                }
                ScanStatusBar(
                    isScanning: analyzer.isScanning,
                    progressFraction: progressFraction,
                    scannedBytes: analyzer.totalDiskScannedBytes,
                    itemsScanned: analyzer.itemsScanned,
                    scanStartDate: analyzer.scanStartDate,
                    scanDuration: analyzer.scanDuration,
                    totalBytes: analyzer.displayedTotalBytes,
                    itemCount: analyzer.rootItems.count
                )
            } else if analyzer.isScanning {
                // Only visible for the moments before the skeleton lands.
                Spacer()
                ProgressView("Preparing scan…")
                Spacer()
            } else {
                Spacer()
                emptyStateView
                Spacer()
            }
        }
        // With window resizability tracking content size, these bounds
        // expand the window when this screen is pushed and let the user
        // resize it freely.
        .frame(
            minWidth: 900, idealWidth: 1100, maxWidth: .infinity,
            minHeight: 600, idealHeight: 720, maxHeight: .infinity
        )
        // Native window title + subtitle: the folder currently shown and its
        // size, updating as you navigate (like Finder). The path bar below is
        // the interactive trail; the toolbar's system back button returns to
        // the disk list.
        .navigationTitle(windowTitle)
        .navigationSubtitle(windowSubtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    // Refreshing inside the synthetic purgeable view
                    // rescans the disk it belongs to.
                    Task {
                        await analyzer.scanDirectory(
                            currentPath.hasPrefix("::") ? rootPath : currentPath
                        )
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
                .help("Rescan the current folder")
            }
        }
        .onAppear {
            guard !hasInitiallyScanned else { return }
            hasInitiallyScanned = true
            // Sandboxed (App Store) build: hold security-scoped access to the
            // granted root for as long as this screen — and its scans — is up.
            // A no-op in the non-sandboxed website build.
            scanAccess.beginAccess(toPath: rootPath)
            Task { await analyzer.scanDirectory(rootPath) }
        }
        .onDisappear {
            analyzer.cancelCurrentScan()
            scanAccess.endAccess(toPath: rootPath)
        }
        // HIG (macOS): search lives at the trailing side of the toolbar.
        // Search starts immediately on typing — the index answers in
        // milliseconds, so there is no debounce.
        .searchable(
            text: $searchText,
            isPresented: $searchPresented,
            placement: .toolbar,
            prompt: "Search scanned files and folders"
        )
        .onChange(of: searchText) {
            analyzer.updateSearch(query: searchText, scope: .all)
            // The visible list is about to change wholesale; a selection
            // spanning the old rows would silently ride into group drags.
            selectedPaths.removeAll()
            selectionAnchor = nil
        }
        .onChange(of: currentPath) {
            selectedPaths.removeAll()
            selectionAnchor = nil
        }
        // Make the Collector reachable from the row context menus in the list.
        .environment(collector)
        // ⌘Z pulls the last collected item back out of the Collector. Gated
        // off while the search field is up so it doesn't shadow text undo.
        .background {
            Button("Undo Collect") { collector.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!collector.canUndo || searchPresented)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    // MARK: - List pane

    /// True once the typed query is non-blank; the results list then
    /// replaces the directory list (the chart keeps showing the current
    /// folder for orientation).
    private var isSearchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The rows currently on screen (browsing or search results), with
    /// collected items dropped — the one array selection ranges, group
    /// drags and the lists all agree on. The synthetic "Purgeable Space"
    /// row has no real path of its own — it's collected via its cache
    /// folders — so it hides once those are all in.
    private var visibleItems: [FolderItem] {
        if isSearchActive {
            return analyzer.searchResults.filter { !collector.contains(path: $0.path) }
        }
        let filtered = analyzer.rootItems.filter { item in
            if item.path == HiddenSpaceInfo.sentinelPath {
                return !analyzer.collectablePurgeableFiles()
                    .allSatisfy { collector.contains(path: $0.path) }
            }
            return !collector.contains(path: item.path)
        }
        return sortedForDisplay(filtered)
    }

    private enum SortField { case name, size }

    /// Applies the current column sort. "Purgeable Space" sorts by size like
    /// any other row (no longer pinned to the top).
    private func sortedForDisplay(_ items: [FolderItem]) -> [FolderItem] {
        switch sort {
        case .name:
            return items.sorted {
                let result = $0.name.localizedCaseInsensitiveCompare($1.name)
                return sortAscending ? result == .orderedAscending : result == .orderedDescending
            }
        case .size:
            return items.sorted { sortAscending ? $0.size < $1.size : $0.size > $1.size }
        }
    }

    /// The selection as collector payloads, in display order. Stale paths
    /// (rows no longer visible) drop out naturally.
    private var selectionFiles: [CollectedFile] {
        visibleItems.filter { selectedPaths.contains($0.path) }.map(CollectedFile.init)
    }

    @ViewBuilder
    private var listPane: some View {
        if isSearchActive {
            SearchResultsView(
                items: visibleItems,
                totalMatches: analyzer.searchTotalMatches,
                isRunning: analyzer.isSearchRunning,
                resultsArePartial: analyzer.searchResultsArePartial,
                query: searchText,
                selectedPaths: selectedPaths,
                selectionFiles: selectionFiles,
                onOpen: handleRowTap
            )
        } else {
            VStack(spacing: 0) {
                columnHeader
                ScanResultsView(
                    items: visibleItems,
                    displayVersion: analyzer.displayVersion,
                    selectedPaths: selectedPaths,
                    selectionFiles: selectionFiles,
                    onFolderTap: handleRowTap
                )
            }
        }
    }

    // MARK: - Sortable column header

    @ViewBuilder
    private var columnHeader: some View {
        HStack(spacing: 0) {
            sortHeaderButton(.name, "Name")
            Spacer(minLength: 8)
            sortHeaderButton(.size, "Size")
        }
        .font(.caption)
        .fontWeight(.semibold)
        .foregroundStyle(.secondary)
        // Align the labels with the row columns: past the icon on the left,
        // before the disclosure chevron on the right.
        .padding(.leading, 40)
        .padding(.trailing, 20)
        .padding(.vertical, 5)
        .background(.bar)
        Divider()
    }

    private func sortHeaderButton(_ field: SortField, _ label: String) -> some View {
        Button {
            if sort == field {
                sortAscending.toggle()
            } else {
                sort = field
                sortAscending = (field == .name)   // A→Z for name, largest-first for size
            }
        } label: {
            HStack(spacing: 3) {
                Text(label)
                Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(sort == field ? 1 : 0)   // reserve space so labels don't shift
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Selection

    /// Routes a row click by its keyboard modifiers: shift extends a range
    /// from the anchor, ⌘ toggles membership, and a plain click clears the
    /// selection and behaves as before (navigate / open). The synthetic
    /// "Purgeable Space" row never joins a multi-selection — it has no
    /// real path, and drops already expand it separately.
    private func handleRowTap(_ item: FolderItem) {
        let modifiers = NSApp.currentEvent?.modifierFlags ?? []
        let selectable = !item.path.hasPrefix("::")

        if selectable && modifiers.contains(.shift) {
            let items = visibleItems
            if let anchor = selectionAnchor,
               let anchorIndex = items.firstIndex(where: { $0.path == anchor }),
               let clickedIndex = items.firstIndex(where: { $0.path == item.path }) {
                let range = min(anchorIndex, clickedIndex)...max(anchorIndex, clickedIndex)
                selectedPaths = Set(
                    items[range].map(\.path).filter { !$0.hasPrefix("::") }
                )
            } else {
                selectedPaths = [item.path]
                selectionAnchor = item.path
            }
            return
        }
        if selectable && modifiers.contains(.command) {
            if selectedPaths.contains(item.path) {
                selectedPaths.remove(item.path)
            } else {
                selectedPaths.insert(item.path)
            }
            selectionAnchor = item.path
            return
        }

        selectedPaths.removeAll()
        selectionAnchor = item.path
        if isSearchActive {
            openSearchResult(item)
        } else {
            navigateToFolder(item)
        }
    }

    /// Opening a result jumps to it in the normal browsing UI: a folder
    /// opens itself, a file reveals its containing folder. Search
    /// dismisses so the destination is immediately browsable.
    private func openSearchResult(_ item: FolderItem) {
        let destination = item.isDirectory
            ? item.path
            : (item.path as NSString).deletingLastPathComponent
        searchPresented = false
        searchText = ""
        navigateToPath(destination)
    }

    // MARK: - Chart pane

    @ViewBuilder
    private var chartPane: some View {
        VStack(spacing: 0) {
            Group {
                if let chartRoot = analyzer.chartRoot {
                    RingsChartView(
                        root: chartRoot,
                        onSelectDirectory: navigateToPath,
                        onSelectCenter: goBack
                    )
                } else {
                    // The chart needs hierarchy; during the skeleton phase
                    // (before the first scan snapshot) there is none yet.
                    ProgressView("Building chart…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(8)

            // Collapsed collector sits distinctly under the graph (in layout);
            // its expanded file list floats up over the graph (see CollectorBar).
            CollectorBar(collector: collector, isTargeted: isCollectorTargeted) { _ in
                // Files were removed — rescan the root and return to the top
                // so the freed space is reflected immediately.
                breadcrumbs = []
                currentPath = rootPath
                Task { await analyzer.scanDirectory(rootPath) }
            }
        }
        // Dropping anywhere on the chart side collects the file; the collector
        // bar lights up while a drag hovers. Dragging the "Purgeable Space"
        // row expands to its real, deletable cache folders (its size is the
        // sum of those, so the collected total matches).
        .dropDestination(for: CollectedFileGroup.self) { groups, _ in
            let expanded = groups.flatMap(\.files).flatMap { file in
                file.path == HiddenSpaceInfo.sentinelPath
                    ? analyzer.collectablePurgeableFiles()
                    : [file]
            }
            // The drag ended here — clear the "can't delete" flag right away.
            collector.flagDraggedProtected(nil)
            // Refuse macOS-protected items outright: the drop bounces back
            // (the Collector already showed why while it was hovering).
            let allowed = expanded.filter { ProtectedPaths.reason(for: $0.path) == nil }
            guard !allowed.isEmpty else { return false }
            collector.add(allowed)
            // Collected rows leave the list; don't leave ghost selections.
            selectedPaths.subtract(allowed.map(\.path))
            return true
        } isTargeted: { isCollectorTargeted = $0 }
    }

    /// Fraction of the device's used space scanned so far, or nil (an
    /// indeterminate bar) when the device's usage is unknown.
    private var progressFraction: Double? {
        guard totalUsedDiskSpace > 0 else { return nil }
        return min(1.0, Double(analyzer.totalDiskScannedBytes) / Double(totalUsedDiskSpace))
    }

    // MARK: - Window title

    /// The folder currently shown — the device name at the scan root, the
    /// last path component when browsing deeper, or the synthetic name for
    /// "::" locations. Updates as you navigate, like Finder's window title.
    private var windowTitle: String {
        if currentPath == rootPath { return rootName }
        if currentPath.hasPrefix("::") { return String(currentPath.dropFirst(2)) }
        return (currentPath as NSString).lastPathComponent
    }

    /// The size of what's on screen, shown beside the title once known.
    private var windowSubtitle: String {
        analyzer.displayedTotalBytes > 0
            ? ByteFormatter.formatFileSize(analyzer.displayedTotalBytes)
            : ""
    }

    // MARK: - Empty state

    @ViewBuilder
    private var emptyStateView: some View {
        if analyzer.needsFullDiskAccess {
            ContentUnavailableView {
                Label("Full Disk Access Required", systemImage: "exclamationmark.shield")
            } description: {
                Text("OpenDisk needs Full Disk Access to analyze your entire system.")
            } actions: {
                Button("Open System Settings") {
                    FullDiskAccess.openSystemSettings()
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            ContentUnavailableView(
                "Ready to analyze",
                systemImage: "folder",
                description: Text("Select a disk to begin scanning")
            )
        }
    }

    // MARK: - Navigation

    private func navigateToFolder(_ item: FolderItem) {
        guard item.isDirectory else { return }
        guard showContents(of: item.path) else { return }
        breadcrumbs.append(currentPath)
        currentPath = item.path
    }

    private func goBack() {
        guard let previousPath = breadcrumbs.last else { return }
        guard showContents(of: previousPath) else { return }
        breadcrumbs.removeLast()
        currentPath = previousPath
    }

    private func navigateToPath(_ path: String) {
        guard path != currentPath else { return }
        guard showContents(of: path) else { return }
        // Jumping via a breadcrumb can only go to an ancestor: rewind the
        // back stack to it instead of appending, so Back stays coherent.
        if let index = breadcrumbs.firstIndex(of: path) {
            breadcrumbs.removeSubrange(index...)
        } else {
            breadcrumbs.append(currentPath)
        }
        currentPath = path
    }

    /// Serves the path from the scanned tree when possible. A path missing
    /// from the tree gets a fresh scan — unless a scan is already running,
    /// in which case that path simply has not been discovered yet and the
    /// navigation is refused (returns false) rather than restarting the
    /// scan.
    private func showContents(of path: String) -> Bool {
        if analyzer.navigateToPath(path) { return true }
        // Synthetic paths ("::"-prefixed) resolve in the analyzer or not
        // at all — they must never fall through to a filesystem scan.
        guard !analyzer.isScanning, !path.hasPrefix("::") else { return false }
        Task { await analyzer.scanDirectory(path) }
        return true
    }
}

#Preview {
    NavigationStack {
        DiskAnalysisView(rootPath: "/", totalUsedSpace: 500_000_000_000)
    }
}

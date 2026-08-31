import AppKit
import QuickLook
import QuickLookUI
import SwiftUI

/// Analysis screen for one disk (pushed from the disk picker): scans it,
/// streams results live, and hosts breadcrumb navigation through them —
/// a split view with the folder list on the left and the rings chart on
/// the right, both updating as the scan runs.
///
/// Navigation chrome makes leaving the scan explicit: an unmount button
/// confirms before returning to the disk picker and clearing the scan data.
/// Refresh lives in the toolbar, and the breadcrumb path bar sits in the
/// content layer with no custom background.
struct DiskAnalysisView: View {
    let rootPath: String
    let rootName: String

    @Environment(\.dismiss) private var dismiss
    @Environment(ScanAccess.self) private var scanAccess
    @State private var analyzer = DiskAnalyzer()
    @State private var collector = Collector()
    @State private var isCollectorTargeted = false
    @State private var currentPath: String
    @State private var breadcrumbs: [String] = []
    @State private var hasInitiallyScanned = false
    @State private var searchText = ""
    @State private var searchPresented = false
    @State private var isShowingUnmountConfirmation = false
    /// Multi-selection (shift-click ranges, ⌘-click toggles) across the
    /// visible list, keyed by path like everything else. A drag from any
    /// selected row carries the whole selection to the Collector.
    @State private var selectedPaths = Set<String>()
    /// The last plainly clicked row — the fixed end of a shift-click range.
    @State private var selectionAnchor: String?
    /// The item shown in the Quick Look panel (spacebar, like Finder);
    /// nil while the panel is closed.
    @State private var quickLookURL: URL?
    /// Local key-down monitor that makes spacebar toggle Quick Look.
    @State private var quickLookKeyMonitor: Any?
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
                    phase: analyzer.scanPhase,
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
        // the interactive trail; unmounting returns to the disk list.
        .navigationTitle(windowTitle)
        .navigationSubtitle(windowSubtitle)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(
                    "Unmount",
                    systemImage: "eject",
                    action: requestUnmount
                )
                .keyboardShortcut("[", modifiers: .command)
                .help("Unmount and clear scan data")
                .confirmationDialog(
                    "Unmount \(rootName)?",
                    isPresented: $isShowingUnmountConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Unmount", role: .destructive, action: unmount)
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This clears the current scan data and returns to disk selection. It does not eject the disk from macOS.")
                }
            }
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
            // Spacebar toggles Quick Look, like Finder. A local monitor
            // rather than .onKeyPress: the list is a plain ScrollView with
            // no focus management, so there is no focused view to receive
            // key presses.
            if quickLookKeyMonitor == nil {
                quickLookKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    handleQuickLookKey(event)
                }
            }
            guard !hasInitiallyScanned else { return }
            hasInitiallyScanned = true
            // Sandboxed (App Store) build: hold security-scoped access to the
            // granted root for as long as this screen — and its scans — is up.
            // A no-op in the non-sandboxed website build.
            scanAccess.beginAccess(toPath: rootPath)
            Task { await analyzer.scanDirectory(rootPath) }
        }
        .onDisappear {
            if let quickLookKeyMonitor {
                NSEvent.removeMonitor(quickLookKeyMonitor)
                self.quickLookKeyMonitor = nil
            }
            quickLookURL = nil
            analyzer.cancelCurrentScan()
            scanAccess.endAccess(toPath: rootPath)
        }
        // Returning from System Settings after enabling Full Disk Access:
        // re-check and retry the scan (works once the app has FDA; if it still
        // fails, a relaunch is needed — the empty state says so).
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if analyzer.needsFullDiskAccess {
                Task { await analyzer.scanDirectory(rootPath) }
            }
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
        // The analyzer owns the viewed path and can reset it to the scan
        // root when a fresh tree no longer contains the viewed folder
        // (deleted, then ⌘R). Keep the breadcrumb trail in step so the
        // title and path bar never show a folder the list has left.
        .onChange(of: analyzer.currentPath) { _, newPath in
            guard !newPath.isEmpty, newPath != currentPath else { return }
            if let index = breadcrumbs.firstIndex(of: newPath) {
                breadcrumbs.removeSubrange(index...)
            } else {
                breadcrumbs = []
            }
            currentPath = newPath
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

    private func requestUnmount() {
        isShowingUnmountConfirmation = true
    }

    private func unmount() {
        dismiss()
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
    ///
    /// O(rows) per call: collected membership goes through one Set built
    /// up front (not a linear scan per row), and the purgeable-files
    /// catalog walk runs at most once, outside the filter closure. Callers
    /// in `body` compute this once per evaluation and pass the array down.
    private var visibleItems: [FolderItem] {
        let collected = collector.pathSet
        if isSearchActive {
            return analyzer.searchResults.filter { !collected.contains($0.path) }
        }
        let filtered = analyzer.rootItems.filter { item in
            if item.path == HiddenSpaceInfo.sentinelPath {
                let purgeable = analyzer.collectablePurgeableFiles()
                return !purgeable.allSatisfy { collected.contains($0.path) }
            }
            return !collected.contains(item.path)
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
    private func selectionFiles(in items: [FolderItem]) -> [CollectedFile] {
        items.filter { selectedPaths.contains($0.path) }.map(CollectedFile.init)
    }

    @ViewBuilder
    private var listPane: some View {
        // One materialization of the row array per evaluation — the lists
        // and the selection payload share it instead of re-filtering and
        // re-sorting per use.
        let items = visibleItems
        Group {
            if isSearchActive {
                SearchResultsView(
                    items: items,
                    resultsVersion: analyzer.searchResultsVersion,
                    totalMatches: analyzer.searchTotalMatches,
                    isRunning: analyzer.isSearchRunning,
                    resultsArePartial: analyzer.searchResultsArePartial,
                    query: searchText,
                    selectedPaths: selectedPaths,
                    selectionFiles: selectionFiles(in: items),
                    onQuickLook: quickLook,
                    onOpen: handleRowTap
                )
            } else {
                VStack(spacing: 0) {
                    columnHeader
                    ScanResultsView(
                        items: items,
                        displayVersion: analyzer.displayVersion,
                        selectedPaths: selectedPaths,
                        selectionFiles: selectionFiles(in: items),
                        onQuickLook: quickLook,
                        onFolderTap: handleRowTap
                    )
                }
            }
        }
        // Quick Look panel (spacebar, see handleQuickLookKey). Passing the
        // visible rows lets the panel's arrow keys walk the list in display
        // order, like Finder. Synthetic rows have no on-disk file to show.
        .quickLookPreview(
            $quickLookURL,
            in: items.compactMap {
                $0.path.hasPrefix("::") ? nil : URL(fileURLWithPath: $0.path)
            }
        )
    }

    // MARK: - Quick Look

    /// Spacebar toggles the Quick Look panel; every other key (and space
    /// while a text field is being edited) passes through untouched.
    private func handleQuickLookKey(_ event: NSEvent) -> NSEvent? {
        guard event.keyCode == 49, !event.isARepeat,
              event.modifierFlags.intersection([.command, .option, .control]).isEmpty
        else { return event }
        // Never steal space from active text editing (the search field —
        // its field editor is an NSTextView first responder).
        if event.window?.firstResponder is NSTextView { return event }
        if quickLookURL != nil {
            quickLookURL = nil
            return nil
        }
        guard let target = quickLookTarget else { return event }
        quickLookURL = target
        centerQuickLookPanel()
        return nil
    }

    /// Context-menu entry point: select the row (so the highlight marks
    /// what's being previewed) and open Quick Look on it.
    private func quickLook(_ item: FolderItem) {
        guard !item.path.hasPrefix("::") else { return }
        selectedPaths = [item.path]
        selectionAnchor = item.path
        quickLookURL = URL(fileURLWithPath: item.path)
        centerQuickLookPanel()
    }

    /// Centers the shared Quick Look panel over the app window instead of
    /// the middle of the screen — the preview belongs to the window it was
    /// invoked from. The SwiftUI modifier creates and shows the panel
    /// asynchronously, so this retries over a few runloop turns until the
    /// panel exists, then nudges it into place (clamped to the screen).
    private func centerQuickLookPanel(attempts: Int = 10) {
        guard quickLookURL != nil else { return }
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared(), panel.isVisible,
              let window = NSApp.mainWindow else {
            if attempts > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                    centerQuickLookPanel(attempts: attempts - 1)
                }
            }
            return
        }
        var frame = panel.frame
        frame.origin = NSPoint(
            x: window.frame.midX - frame.width / 2,
            y: window.frame.midY - frame.height / 2
        )
        if let screen = (window.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = min(
                max(frame.origin.x, screen.minX),
                max(screen.minX, screen.maxX - frame.width)
            )
            frame.origin.y = min(
                max(frame.origin.y, screen.minY),
                max(screen.minY, screen.maxY - frame.height)
            )
        }
        panel.setFrame(frame, display: true)
    }

    /// What spacebar previews: the first selected row in display order,
    /// falling back to the last plainly clicked row. Synthetic rows have
    /// nothing on disk to preview.
    private var quickLookTarget: URL? {
        let items = visibleItems
        if let selected = items.first(where: {
            selectedPaths.contains($0.path) && !$0.path.hasPrefix("::")
        }) {
            return URL(fileURLWithPath: selected.path)
        }
        if let anchor = selectionAnchor, !anchor.hasPrefix("::"),
           items.contains(where: { $0.path == anchor }) {
            return URL(fileURLWithPath: anchor)
        }
        return nil
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
        } else if item.isDirectory {
            navigateToFolder(item)
        } else if selectable {
            // A plain click on a file selects it (Finder's rule) — it has
            // nowhere to navigate to, and the highlight marks what spacebar
            // will Quick Look.
            selectedPaths = [item.path]
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
                Text("OpenDisk needs Full Disk Access to analyze your entire system. Turn it on in System Settings, then **quit and reopen OpenDisk** — macOS only applies the change to a freshly launched app.")
            } actions: {
                Button("Open System Settings") {
                    FullDiskAccess.openSystemSettings()
                }
                .buttonStyle(.borderedProminent)
                Button("Quit & Reopen") {
                    FullDiskAccess.relaunch()
                }
            }
        } else if analyzer.unreadableDirectories > 0 {
            // The scan ran but couldn't open what it was pointed at — a
            // revoked folder grant, permissions, or a volume that went
            // away. Without this, a denied scan looks like an empty disk.
            ContentUnavailableView {
                Label("Couldn't Read This Location", systemImage: "lock.slash")
            } description: {
                Text("macOS denied access to this location. Check its permissions — or remove and re-grant it — then rescan.")
            } actions: {
                Button("Rescan") {
                    Task { await analyzer.scanDirectory(rootPath) }
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            ContentUnavailableView(
                "Nothing to Show",
                systemImage: "folder",
                description: Text("This folder is empty, or nothing in it was large enough to scan.")
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

import AppKit
import QuickLook
import QuickLookUI
import SwiftUI

struct DiskAnalysisView: View {
    let rootPath: String
    let rootName: String
    let onScanFinished: () -> Void

    @Environment(ScanAccess.self) private var scanAccess
    @State private var analyzer = DiskAnalyzer()
    @State private var collector = Collector()
    @State private var isCollectorTargeted = false
    @State private var currentPath: String
    @State private var history = NavigationHistory()
    @State private var pendingFocus: String?
    @State private var hasInitiallyScanned = false
    @State private var searchText = ""
    @State private var searchPresented = false
    @State private var selectedPaths = Set<String>()
    @State private var selectionAnchor: String?
    @State private var quickLookURL: URL?
    @State private var keyMonitor: Any?
    @State private var navigationMonitor: Any?
    @State private var windowNumber: Int?
    @State private var keyBindings = KeyBindingStore.shared
    @State private var sort: SortField = .size
    @State private var sortAscending = false
    private let totalUsedDiskSpace: Int64
    @State private var volumeCapacity: VolumeCapacity?
    @AppStorage(FreeSpaceInfo.defaultsKey) private var showFreeSpace = true
    @AppStorage("inspector_visible") private var showInspector = true
    @AppStorage(ListScale.defaultsKey) private var listScaleLevel = ListScale.defaultLevel
    @State private var isVolumeRoot = false
    @State private var listIsWide = true

    init(
        rootPath: String,
        rootName: String = String(localized: "Computer"),
        totalUsedSpace: Int64 = 0,
        onScanFinished: @escaping () -> Void = {}
    ) {
        self.rootPath = rootPath
        self.rootName = rootName
        self.onScanFinished = onScanFinished
        self.totalUsedDiskSpace = totalUsedSpace
        self._currentPath = State(initialValue: rootPath)
    }

    var body: some View {
        HSplitView {
            mainColumn
                .frame(minWidth: 340, idealWidth: 600, maxWidth: .infinity, maxHeight: .infinity)
            if showInspector {
                inspectorPane
                    .frame(minWidth: 280, idealWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minHeight: 480, maxHeight: .infinity)
        .navigationTitle(windowTitle)
        .navigationSubtitle(windowSubtitle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                ControlGroup {
                    Button("Back", systemImage: "chevron.backward", action: goBack)
                        .keyboardShortcut("[", modifiers: .command)
                        .disabled(parentPath == nil)
                        .help("Go up one level (⌘[ or ⌘↑)")
                    Button("Forward", systemImage: "chevron.forward", action: goForward)
                        .keyboardShortcut("]", modifiers: .command)
                        .disabled(!history.canGoForward)
                        .help("Go back into the folder you just left (⌘])")
                }
                .controlGroupStyle(.navigation)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise", action: rescanFromTop)
                .keyboardShortcut("r", modifiers: .command)
                .help("Rescan from the top level")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Inspector", systemImage: "sidebar.right") {
                    showInspector.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .help(showInspector ? "Hide Inspector (⌥⌘I)" : "Show Inspector (⌥⌘I)")
            }
        }
        .onAppear {
            if keyMonitor == nil {
                keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    handleKey(event)
                }
            }
            if navigationMonitor == nil {
                navigationMonitor = NSEvent.addLocalMonitorForEvents(
                    matching: [.otherMouseUp, .swipe, .scrollWheel]
                ) { event in
                    handleNavigationEvent(event)
                }
            }
            guard !hasInitiallyScanned else { return }
            hasInitiallyScanned = true
            isVolumeRoot = (try? URL(fileURLWithPath: rootPath)
                .resourceValues(forKeys: [.isVolumeKey]))?.isVolume ?? false
            scanAccess.beginAccess(toPath: rootPath)
            Task { await analyzer.scanDirectory(rootPath) }
        }
        .task(id: rootPath) {
            while !Task.isCancelled {
                await refreshVolumeCapacity()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onChange(of: analyzer.isScanning) { _, isScanning in
            guard !isScanning else { return }
            Task { await refreshVolumeCapacity() }
            if !analyzer.rootItems.isEmpty, !analyzer.needsFullDiskAccess {
                onScanFinished()
            }
        }
        .onDisappear {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
                self.keyMonitor = nil
            }
            if let navigationMonitor {
                NSEvent.removeMonitor(navigationMonitor)
                self.navigationMonitor = nil
            }
            quickLookURL = nil
            analyzer.cancelCurrentScan()
            scanAccess.endAccess(toPath: rootPath)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if analyzer.needsFullDiskAccess {
                Task { await analyzer.scanDirectory(rootPath) }
            }
        }
        .onChange(of: searchText) {
            analyzer.updateSearch(query: searchText, scope: .all)
            selectedPaths.removeAll()
            selectionAnchor = nil
        }
        .onChange(of: currentPath) {
            selectedPaths.removeAll()
            selectionAnchor = nil
            if let focus = pendingFocus {
                pendingFocus = nil
                if !focus.hasPrefix("::") { selectedPaths = [focus] }
                selectionAnchor = focus
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: FileDragSource.filesMovedNotification)) { _ in
            refresh()
        }
        .onChange(of: analyzer.currentPath) { _, newPath in
            guard !newPath.isEmpty, newPath != currentPath else { return }
            history.didNavigate(to: newPath)
            currentPath = newPath
        }
        .background(WindowNumberReader { windowNumber = $0 })
        .environment(collector)
        .background {
            Button("Undo Collect") { collector.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!collector.canUndo || searchPresented)
                .opacity(0)
                .accessibilityHidden(true)
            Button("Make Text Bigger") {
                listScaleLevel = ListScale(level: listScaleLevel + 1).level
            }
                .keyboardShortcut("=", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
            Button("Enclosing Folder", action: goBack)
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(parentPath == nil)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var mainColumn: some View {
        let detailMinWidth = listScale.scaled(FileColumns.detailMinWidth)
        VStack(spacing: 0) {
            if !analyzer.rootItems.isEmpty {
                listPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onGeometryChange(for: Bool.self) {
                        $0.size.width >= detailMinWidth
                    } action: { listIsWide = $0 }
                    .searchable(
                        text: $searchText,
                        isPresented: $searchPresented,
                        placement: .toolbar,
                        prompt: "Search"
                    )
                ScanStatusBar(
                    isScanning: analyzer.isScanning,
                    phase: analyzer.scanPhase,
                    stepsCompleted: analyzer.scanStepsCompleted,
                    stepsTotal: analyzer.scanStepsTotal,
                    progressFraction: progressFraction,
                    scannedBytes: analyzer.totalDiskScannedBytes,
                    itemsScanned: analyzer.itemsScanned,
                    scanStartDate: analyzer.scanStartDate,
                    scanDuration: analyzer.scanDuration
                ) {
                    EmptyView()
                }
            } else if analyzer.isScanning {
                ProgressView("Preparing scan…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptyStateView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var isSearchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

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

    private func sortedForDisplay(_ items: [FolderItem]) -> [FolderItem] {
        switch sort {
        case .name:
            return items.sorted {
                let result = $0.name.localizedStandardCompare($1.name)
                return sortAscending ? result == .orderedAscending : result == .orderedDescending
            }
        case .size:
            return items.sorted { sortAscending ? $0.size < $1.size : $0.size > $1.size }
        }
    }

    private func selectionFiles(in items: [FolderItem]) -> [CollectedFile] {
        items.filter { selectedPaths.contains($0.path) }.map(CollectedFile.init)
    }

    @ViewBuilder
    private var listPane: some View {
        let items = visibleItems
        let kindWidth = FileColumns.kindWidth(for: items, scale: listScale)
        Group {
            if isSearchActive {
                VStack(spacing: 0) {
                    pathBar
                    Divider()
                    SearchResultsView(
                        items: items,
                        resultsVersion: analyzer.searchResultsVersion,
                        totalMatches: analyzer.searchTotalMatches,
                        isRunning: analyzer.isSearchRunning,
                        resultsArePartial: analyzer.searchResultsArePartial,
                        query: searchText,
                        selectedPaths: selectedPaths,
                        focusedPath: selectionAnchor,
                        showsDetailColumns: showsDetailColumns,
                        kindWidth: kindWidth,
                        selectionFiles: selectionFiles(in: items),
                        onQuickLook: quickLook,
                        onSelect: selectRow,
                        onOpen: openRow
                    )
                }
            } else {
                ScanResultsView(
                    items: items,
                    displayVersion: analyzer.displayVersion,
                    selectedPaths: selectedPaths,
                    focusedPath: selectionAnchor,
                    showsDetailColumns: showsDetailColumns,
                    kindWidth: kindWidth,
                    selectionFiles: selectionFiles(in: items),
                    onQuickLook: quickLook,
                    onSelect: selectRow,
                    onOpen: openRow
                ) {
                    VStack(spacing: 0) {
                        pathBar
                        columnHeader(kindWidth: kindWidth)
                    }
                }
                .id(currentPath)
            }
        }
        .environment(\.listScale, listScale)
        .quickLookPreview(
            $quickLookURL,
            in: items.compactMap {
                $0.path.hasPrefix("::") ? nil : URL(fileURLWithPath: $0.path)
            }
        )
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard !event.isARepeat || isRepeatable(event) else { return event }
        if event.window?.firstResponder is NSTextView { return event }
        if event.window is QLPreviewPanel, !keyMatchesQuickLook(event) { return event }
        guard let match = keyBindings.match(event) else { return event }
        perform(match)
        return nil
    }

    private func isRepeatable(_ event: NSEvent) -> Bool {
        guard let match = keyBindings.match(event) else { return false }
        return match.action == .moveDown || match.action == .moveUp
    }

    private func keyMatchesQuickLook(_ event: NSEvent) -> Bool {
        keyBindings.match(event)?.action == .quickLook
    }

    private func perform(_ match: KeyBindingStore.Match) {
        switch match.action {
        case .moveDown:
            moveFocus(by: 1, extending: match.extendsSelection)
        case .moveUp:
            moveFocus(by: -1, extending: match.extendsSelection)
        case .openSelected:
            openFocusedItem()
        case .enclosingFolder:
            goBack()
        case .addToCollector:
            collectSelection()
        case .quickLook:
            toggleQuickLook()
        case .showInFinder:
            showSelectionInFinder()
        case .selectAll:
            selectAllItems()
        }
    }

    private var focusedItem: FolderItem? {
        let items = visibleItems
        if let anchor = selectionAnchor, let item = items.first(where: { $0.path == anchor }) {
            return item
        }
        return items.first { selectedPaths.contains($0.path) }
    }

    private func moveFocus(by offset: Int, extending: Bool) {
        let items = visibleItems
        guard !items.isEmpty else { return }
        let currentIndex = focusedItem.flatMap { item in items.firstIndex { $0.path == item.path } }
        let nextIndex: Int
        if let currentIndex {
            nextIndex = min(max(currentIndex + offset, 0), items.count - 1)
        } else {
            nextIndex = offset > 0 ? 0 : items.count - 1
        }
        let next = items[nextIndex]
        let selectable = !next.path.hasPrefix("::")
        if extending, selectable {
            selectedPaths.insert(next.path)
            if let current = focusedItem, !current.path.hasPrefix("::") {
                selectedPaths.insert(current.path)
            }
        } else {
            selectedPaths = selectable ? [next.path] : []
        }
        selectionAnchor = next.path
        if quickLookURL != nil, selectable {
            quickLookURL = URL(fileURLWithPath: next.path)
        }
    }

    private func openFocusedItem() {
        guard let item = focusedItem else { return }
        if isSearchActive {
            openSearchResult(item)
        } else if item.isDirectory {
            navigateToFolder(item)
        } else {
            quickLook(item)
        }
    }

    private func collectSelection() {
        let items = visibleItems
        var files = items.filter { selectedPaths.contains($0.path) }.map(CollectedFile.init)
        if files.isEmpty, let item = focusedItem {
            files = [CollectedFile(item)]
        }
        guard !files.isEmpty else { return }
        let nextAnchor = nextFocus(after: files.map(\.path), in: items)
        guard collect(files) else { return }
        selectionAnchor = nextAnchor
        if let nextAnchor, !nextAnchor.hasPrefix("::") {
            selectedPaths = [nextAnchor]
        }
    }

    private func nextFocus(after removed: [String], in items: [FolderItem]) -> String? {
        let removedSet = Set(removed)
        guard let lastIndex = items.lastIndex(where: { removedSet.contains($0.path) }) else {
            return nil
        }
        if let after = items[lastIndex...].first(where: { !removedSet.contains($0.path) }) {
            return after.path
        }
        return items[..<lastIndex].last { !removedSet.contains($0.path) }?.path
    }

    private func toggleQuickLook() {
        if quickLookURL != nil {
            quickLookURL = nil
            return
        }
        guard let target = quickLookTarget else { return }
        quickLookURL = target
        centerQuickLookPanel()
    }

    private func showSelectionInFinder() {
        var paths = visibleItems.filter { selectedPaths.contains($0.path) }.map(\.path)
        if paths.isEmpty, let item = focusedItem, !item.path.hasPrefix("::") {
            paths = [item.path]
        }
        guard !paths.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
    }

    private func selectAllItems() {
        selectedPaths = Set(visibleItems.map(\.path).filter { !$0.hasPrefix("::") })
    }

    private func quickLook(_ item: FolderItem) {
        guard !item.path.hasPrefix("::") else { return }
        selectedPaths = [item.path]
        selectionAnchor = item.path
        quickLookURL = URL(fileURLWithPath: item.path)
        centerQuickLookPanel()
    }

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

    private var listScale: ListScale { ListScale(level: listScaleLevel) }

    private var showsDetailColumns: Bool { listIsWide }

    private var pathBar: some View {
        BreadcrumbBar(
            currentPath: currentPath,
            rootPath: rootPath,
            rootName: rootName,
            sizeOfPath: analyzer.size(ofPath:),
            onNavigate: { navigateLeavingSearch(to: $0) }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func columnHeader(kindWidth: CGFloat) -> some View {
        HStack(spacing: FileColumns.spacing) {
            Color.clear
                .frame(width: listScale.icon, height: 1)
            sortHeaderButton(.name, "Name")
                .frame(maxWidth: .infinity, alignment: .leading)
            sortHeaderButton(.size, "Size")
                .frame(width: listScale.scaled(FileColumns.size), alignment: .trailing)
            Color.clear
                .frame(width: listScale.scaled(FileColumns.bar), height: 1)
            if showsDetailColumns {
                Text("Kind")
                    .frame(width: kindWidth, alignment: .leading)
            }
        }
        .font(.system(size: listScale.headerFontSize, weight: .medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, FileColumns.inset * 2)
        .padding(.vertical, 5)
    }

    private func sortHeaderButton(_ field: SortField, _ label: LocalizedStringKey) -> some View {
        Button {
            if sort == field {
                sortAscending.toggle()
            } else {
                sort = field
                sortAscending = (field == .name)
            }
        } label: {
            HStack(spacing: 3) {
                Text(label)
                Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(sort == field ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func selectRow(_ item: FolderItem) {
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

        selectedPaths = selectable ? [item.path] : []
        selectionAnchor = item.path
    }

    private func openRow(_ item: FolderItem) {
        selectionAnchor = item.path
        if isSearchActive {
            selectedPaths.removeAll()
            openSearchResult(item)
        } else if item.isDirectory {
            selectedPaths.removeAll()
            navigateToFolder(item)
        } else {
            quickLook(item)
        }
    }

    private func openSearchResult(_ item: FolderItem) {
        let destination = item.isDirectory
            ? item.path
            : (item.path as NSString).deletingLastPathComponent
        searchPresented = false
        searchText = ""
        navigateToPath(destination)
    }

    @ViewBuilder
    private var inspectorPane: some View {
        VStack(spacing: 0) {
            Group {
                if let chartRoot = analyzer.chartRoot {
                    RingsChartView(
                        root: chartRoot,
                        freeBytes: chartFreeBytes,
                        onSelectDirectory: { navigateLeavingSearch(to: $0) },
                        onSelectCenter: {
                            exitSearch()
                            goBack()
                        }
                    )
                } else if analyzer.isScanning || !analyzer.rootItems.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(8)
            .padding(.bottom, Self.collectorReservedHeight)
        }
        .overlay(alignment: .bottom) {
            CollectorBar(collector: collector, isTargeted: isCollectorTargeted) { _ in
                history.reset()
                currentPath = rootPath
                Task { await analyzer.scanDirectory(rootPath) }
            }
        }
        .coordinateSpace(.collectorDrop)
        .overlay {
            InAppFileDropTarget(
                onTargetChange: { isCollectorTargeted = $0 },
                perform: handleCollectorDrop
            )
        }
    }

    private static let collectorReservedHeight: CGFloat = 64

    private var chartFreeBytes: Int64? {
        guard showFreeSpace, isVolumeRoot, currentPath == rootPath,
              let capacity = volumeCapacity, capacity.available > 0
        else { return nil }
        return capacity.available
    }

    private func handleCollectorDrop(_ files: [CollectedFile], at location: CGPoint) -> Bool {
        if collector.draggingOut != nil {
            collector.resolveDragOut(droppedAt: location)
            return true
        }
        return collect(files)
    }

    @discardableResult
    private func collect(_ files: [CollectedFile]) -> Bool {
        let expanded = files.flatMap { file in
            file.path == HiddenSpaceInfo.sentinelPath
                ? analyzer.collectablePurgeableFiles()
                : [file]
        }
        collector.flagDraggedProtected(nil)
        let allowed = expanded.filter { !ProtectedPaths.isProtected($0.path) }
        guard !allowed.isEmpty else { return false }
        collector.add(allowed)
        selectedPaths.subtract(allowed.map(\.path))
        return true
    }

    private func refresh() {
        Task {
            await analyzer.scanDirectory(currentPath.hasPrefix("::") ? rootPath : currentPath)
        }
    }

    private func rescanFromTop() {
        history.reset()
        currentPath = rootPath
        Task { await analyzer.scanDirectory(rootPath) }
    }

    private var progressFraction: Double? {
        guard totalUsedDiskSpace > 0 else { return nil }
        return min(1.0, Double(analyzer.totalDiskScannedBytes) / Double(totalUsedDiskSpace))
    }

    private func refreshVolumeCapacity() async {
        let path = rootPath
        let capacity = await Task.detached(priority: .utility) {
            DeviceMonitor.volumeCapacity(ofPath: path)
        }.value
        if capacity != volumeCapacity { volumeCapacity = capacity }
    }

    private var windowTitle: String {
        if currentPath == rootPath { return rootName }
        if currentPath.hasPrefix("::") { return String(currentPath.dropFirst(2)) }
        return (currentPath as NSString).lastPathComponent
    }

    private var windowSubtitle: String {
        guard analyzer.displayedTotalBytes > 0 else {
            return analyzer.isScanning ? String(localized: "Scanning…") : ""
        }
        let count = analyzer.rootItems.count
        return "\(ByteFormatter.formatFileSize(analyzer.displayedTotalBytes)) · " + String(localized: "\(count) items")
    }

    @ViewBuilder
    private var emptyStateView: some View {
        if analyzer.needsFullDiskAccess {
            ContentUnavailableView {
                Label("Full Disk Access Required", systemImage: "exclamationmark.shield")
            } description: {
                Text("OpenDisk needs Full Disk Access to analyze your entire system. Turn it on in System Settings, then **quit and reopen OpenDisk**. macOS only applies the change to a freshly launched app.")
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
            ContentUnavailableView {
                Label("Couldn't Read This Location", systemImage: "lock.slash")
            } description: {
                Text("macOS denied access to this location. Check its permissions, or remove and re-grant it, then rescan.")
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

    private func navigateToFolder(_ item: FolderItem) {
        guard item.isDirectory else { return }
        navigateToPath(item.path)
    }

    private var parentPath: String? {
        NavigationHistory.parent(of: currentPath, root: rootPath)
    }

    private func goBack() {
        guard let parentPath else { return }
        guard showContents(of: parentPath) else { return }
        history.didGoBack(from: currentPath)
        pendingFocus = NavigationHistory.childLeading(to: currentPath, from: parentPath)
            ?? (currentPath.hasPrefix("::") ? currentPath : nil)
        currentPath = parentPath
    }

    private func goForward() {
        guard let target = history.forwardTarget, target != currentPath else { return }
        guard showContents(of: target) else { return }
        _ = history.goForward()
        currentPath = target
    }

    private func exitSearch() {
        guard isSearchActive || searchPresented else { return }
        searchPresented = false
        searchText = ""
    }

    private func navigateLeavingSearch(to path: String) {
        exitSearch()
        navigateToPath(path)
    }

    private func navigateToPath(_ path: String) {
        guard path != currentPath else { return }
        guard showContents(of: path) else { return }
        history.didNavigate(to: path)
        pendingFocus = NavigationHistory.childLeading(to: currentPath, from: path)
        currentPath = path
    }

    private func handleNavigationEvent(_ event: NSEvent) -> NSEvent? {
        guard event.windowNumber == windowNumber, !isSearchActive else { return event }
        switch event.type {
        case .otherMouseUp:
            switch event.buttonNumber {
            case 3: goBack()
            case 4: goForward()
            default: return event
            }
            return nil
        case .swipe:
            if event.deltaX > 0 {
                goBack()
            } else if event.deltaX < 0 {
                goForward()
            } else {
                return event
            }
            return nil
        case .scrollWheel:
            return trackTwoFingerSwipe(event) ? nil : event
        default:
            return event
        }
    }

    private func trackTwoFingerSwipe(_ event: NSEvent) -> Bool {
        guard NSEvent.isSwipeTrackingFromScrollEventsEnabled,
              event.phase == .began, event.hasPreciseScrollingDeltas,
              abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        else { return false }
        let canGoBack = parentPath != nil
        let canGoForward = history.canGoForward
        if event.scrollingDeltaX > 0 ? !canGoBack : !canGoForward { return false }
        var handled = false
        event.trackSwipeEvent(
            options: [.lockDirection, .clampGestureAmount],
            dampenAmountThresholdMin: canGoForward ? -1 : 0,
            max: canGoBack ? 1 : 0
        ) { amount, phase, isComplete, _ in
            guard phase == .ended, !handled else { return }
            handled = true
            MainActor.assumeIsolated {
                if amount > 0 { goBack() } else if amount < 0 { goForward() }
            }
        }
        return true
    }

    private func showContents(of path: String) -> Bool {
        if analyzer.navigateToPath(path) { return true }
        guard !analyzer.isScanning, !path.hasPrefix("::") else { return false }
        Task { await analyzer.scanDirectory(path) }
        return true
    }
}

private struct WindowNumberReader: NSViewRepresentable {
    let onChange: (Int?) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {
        nsView.onChange = onChange
    }

    final class ReaderView: NSView {
        var onChange: ((Int?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let number = window?.windowNumber
            DispatchQueue.main.async { [weak self] in
                self?.onChange?(number)
            }
        }
    }
}

#Preview {
    NavigationSplitView {
        EmptyView()
    } detail: {
        DiskAnalysisView(rootPath: "/", totalUsedSpace: 500_000_000_000)
    }
}

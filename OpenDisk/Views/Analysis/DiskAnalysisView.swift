import AppKit
import QuickLook
import QuickLookUI
import SwiftUI

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
    @State private var selectedPaths = Set<String>()
    @State private var selectionAnchor: String?
    @State private var quickLookURL: URL?
    @State private var quickLookKeyMonitor: Any?
    @State private var sort: SortField = .size
    @State private var sortAscending = false
    private let totalUsedDiskSpace: Int64
    @State private var volumeCapacity: VolumeCapacity?

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
                    itemCount: analyzer.rootItems.count,
                    volumeCapacity: volumeCapacity
                )
            } else if analyzer.isScanning {
                Spacer()
                ProgressView("Preparing scan…")
                Spacer()
            } else {
                Spacer()
                emptyStateView
                Spacer()
            }
        }
        .frame(
            minWidth: 900, idealWidth: 1100, maxWidth: .infinity,
            minHeight: 600, idealHeight: 720, maxHeight: .infinity
        )
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
                Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
                .keyboardShortcut("r", modifiers: .command)
                .help("Rescan the current folder")
            }
        }
        .onAppear {
            if quickLookKeyMonitor == nil {
                quickLookKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    handleQuickLookKey(event)
                }
            }
            guard !hasInitiallyScanned else { return }
            hasInitiallyScanned = true
            scanAccess.beginAccess(toPath: rootPath)
            Task { await analyzer.scanDirectory(rootPath) }
        }
        .task(id: rootPath) { await refreshVolumeCapacity() }
        .onChange(of: analyzer.isScanning) { _, isScanning in
            if !isScanning { Task { await refreshVolumeCapacity() } }
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
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if analyzer.needsFullDiskAccess {
                Task { await analyzer.scanDirectory(rootPath) }
            }
        }
        .searchable(
            text: $searchText,
            isPresented: $searchPresented,
            placement: .toolbar,
            prompt: "Search scanned files and folders"
        )
        .onChange(of: searchText) {
            analyzer.updateSearch(query: searchText, scope: .all)
            selectedPaths.removeAll()
            selectionAnchor = nil
        }
        .onChange(of: currentPath) {
            selectedPaths.removeAll()
            selectionAnchor = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: FileDragSource.filesMovedNotification)) { _ in
            refresh()
        }
        .onChange(of: analyzer.currentPath) { _, newPath in
            guard !newPath.isEmpty, newPath != currentPath else { return }
            if let index = breadcrumbs.firstIndex(of: newPath) {
                breadcrumbs.removeSubrange(index...)
            } else {
                breadcrumbs = []
            }
            currentPath = newPath
        }
        .environment(collector)
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
                let result = $0.name.localizedCaseInsensitiveCompare($1.name)
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
        .quickLookPreview(
            $quickLookURL,
            in: items.compactMap {
                $0.path.hasPrefix("::") ? nil : URL(fileURLWithPath: $0.path)
            }
        )
    }

    private func handleQuickLookKey(_ event: NSEvent) -> NSEvent? {
        guard event.keyCode == 49, !event.isARepeat,
              event.modifierFlags.intersection([.command, .option, .control]).isEmpty
        else { return event }
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
            selectedPaths = [item.path]
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
                    ProgressView("Building chart…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(8)

            CollectorBar(collector: collector, isTargeted: isCollectorTargeted) { _ in
                breadcrumbs = []
                currentPath = rootPath
                Task { await analyzer.scanDirectory(rootPath) }
            }
        }
        .coordinateSpace(.collectorDrop)
        .onDrop(
            of: [.fileURL, .collectedFile],
            delegate: InAppFileDropDelegate(
                onTargetChange: { isCollectorTargeted = $0 },
                perform: handleCollectorDrop
            )
        )
    }

    private func handleCollectorDrop(_ files: [CollectedFile], at location: CGPoint) -> Bool {
        if collector.draggingOut != nil {
            collector.resolveDragOut(droppedAt: location)
            return true
        }
        let expanded = files.flatMap { file in
            file.path == HiddenSpaceInfo.sentinelPath
                ? analyzer.collectablePurgeableFiles()
                : [file]
        }
        collector.flagDraggedProtected(nil)
        let allowed = expanded.filter { ProtectedPaths.reason(for: $0.path) == nil }
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

    private var progressFraction: Double? {
        guard totalUsedDiskSpace > 0 else { return nil }
        return min(1.0, Double(analyzer.totalDiskScannedBytes) / Double(totalUsedDiskSpace))
    }

    private func refreshVolumeCapacity() async {
        let path = rootPath
        volumeCapacity = await Task.detached(priority: .utility) {
            DeviceMonitor.volumeCapacity(ofPath: path)
        }.value
    }

    private var windowTitle: String {
        if currentPath == rootPath { return rootName }
        if currentPath.hasPrefix("::") { return String(currentPath.dropFirst(2)) }
        return (currentPath as NSString).lastPathComponent
    }

    private var windowSubtitle: String {
        analyzer.displayedTotalBytes > 0
            ? ByteFormatter.formatFileSize(analyzer.displayedTotalBytes)
            : ""
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
        if let index = breadcrumbs.firstIndex(of: path) {
            breadcrumbs.removeSubrange(index...)
        } else {
            breadcrumbs.append(currentPath)
        }
        currentPath = path
    }

    private func showContents(of path: String) -> Bool {
        if analyzer.navigateToPath(path) { return true }
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

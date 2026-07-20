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

    @Environment(\.dismiss) private var dismiss
    @State private var analyzer = DiskAnalyzer()
    @State private var collector = Collector()
    @State private var currentPath: String
    @State private var breadcrumbs: [String] = []
    @State private var hasInitiallyScanned = false
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
                onNavigate: navigateToPath,
                onRootTap: { dismiss() }
            )

            if !analyzer.rootItems.isEmpty {
                // The split starts at 60% list / 40% chart (ideal widths
                // seed HSplitView's initial divider position); the divider
                // stays user-draggable.
                GeometryReader { geometry in
                    HSplitView {
                        ScanResultsView(
                            items: analyzer.rootItems,
                            displayVersion: analyzer.displayVersion,
                            onFolderTap: navigateToFolder
                        )
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
        .navigationTitle(rootName)
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
            Task { await analyzer.scanDirectory(rootPath) }
        }
        .onDisappear {
            analyzer.cancelCurrentScan()
        }
        // Make the Collector reachable from the row context menus in the list.
        .environment(collector)
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

            // Centered under the graph: a drop target that invites files from
            // the list and expands into the deletion tray once it holds any.
            CollectorBar(collector: collector) { _ in
                // Files were removed — rescan the root and return to the top
                // so the freed space is reflected immediately.
                breadcrumbs = []
                currentPath = rootPath
                Task { await analyzer.scanDirectory(rootPath) }
            }
        }
        // Dropping anywhere on the chart side collects the file.
        .dropDestination(for: CollectedFile.self) { files, _ in
            collector.add(files)
            return true
        }
    }

    /// Fraction of the device's used space scanned so far, or nil (an
    /// indeterminate bar) when the device's usage is unknown.
    private var progressFraction: Double? {
        guard totalUsedDiskSpace > 0 else { return nil }
        return min(1.0, Double(analyzer.totalDiskScannedBytes) / Double(totalUsedDiskSpace))
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

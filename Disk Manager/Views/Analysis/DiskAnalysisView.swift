import AppKit
import SwiftUI

/// How the current directory's usage is displayed.
enum AnalysisDisplayMode: String, CaseIterable, Identifiable {
    case list
    case rings
    case treemap

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .list: "list.bullet"
        case .rings: "chart.pie"
        case .treemap: "square.grid.2x2"
        }
    }

    var title: String {
        switch self {
        case .list: "List"
        case .rings: "Rings"
        case .treemap: "Treemap"
        }
    }
}

/// Detail pane for a selected device: scans it, streams results live, and
/// hosts breadcrumb navigation through them, as a list, a rings chart or a
/// treemap.
///
/// There is no separate "scanning" screen — results render from the first
/// instant (a skeleton of top-level names, then live sizes) and the scan's
/// progress lives in the shared bottom status bar.
struct DiskAnalysisView: View {
    let rootPath: String
    let rootName: String
    let onBack: () -> Void

    @State private var analyzer = DiskAnalyzer()
    @State private var currentPath: String
    @State private var breadcrumbs: [String] = []
    @State private var hasInitiallyScanned = false
    @AppStorage("analysisDisplayMode") private var displayModeRaw = AnalysisDisplayMode.list.rawValue
    private let totalUsedDiskSpace: Int64

    init(
        rootPath: String,
        rootName: String = "Computer",
        totalUsedSpace: Int64 = 0,
        onBack: @escaping () -> Void = {}
    ) {
        self.rootPath = rootPath
        self.rootName = rootName
        self.totalUsedDiskSpace = totalUsedSpace
        self.onBack = onBack
        self._currentPath = State(initialValue: rootPath)
    }

    private var displayMode: AnalysisDisplayMode {
        AnalysisDisplayMode(rawValue: displayModeRaw) ?? .list
    }

    var body: some View {
        VStack(spacing: 0) {
            BreadcrumbBar(
                currentPath: currentPath,
                rootPath: rootPath,
                rootName: rootName,
                onNavigate: navigateToPath,
                onBack: goBack,
                onRootTap: {
                    if currentPath == rootPath {
                        onBack()
                    } else {
                        navigateToPath(rootPath)
                    }
                },
                onRefresh: {
                    Task { await analyzer.scanDirectory(currentPath) }
                }
            )

            if !analyzer.rootItems.isEmpty {
                modePickerBar
                content
                ScanStatusBar(
                    isScanning: analyzer.isScanning,
                    progressFraction: progressFraction,
                    scanStatus: analyzer.statusDescription,
                    filesPerSecond: analyzer.filesPerSecond,
                    scanDuration: analyzer.scanDuration,
                    totalBytes: analyzer.rootItems.reduce(0) { $0 + $1.size },
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
        .onAppear {
            guard !hasInitiallyScanned else { return }
            hasInitiallyScanned = true
            Task { await analyzer.scanDirectory(rootPath) }
        }
        .onDisappear {
            analyzer.cancelCurrentScan()
        }
    }

    // MARK: - Content modes

    private var modePickerBar: some View {
        HStack {
            Spacer()
            Picker("Display mode", selection: $displayModeRaw) {
                ForEach(AnalysisDisplayMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.symbolName)
                        .tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var content: some View {
        switch displayMode {
        case .list:
            ScanResultsView(items: analyzer.rootItems, onFolderTap: navigateToFolder)

        case .rings:
            if let chartRoot = analyzer.chartRoot {
                RingsChartView(
                    root: chartRoot,
                    onSelectDirectory: navigateToPath,
                    onSelectCenter: goBack
                )
                .padding(8)
            } else {
                chartPlaceholder
            }

        case .treemap:
            if let chartRoot = analyzer.chartRoot {
                TreemapChartView(
                    root: chartRoot,
                    onSelectDirectory: navigateToPath
                )
                .padding(8)
            } else {
                chartPlaceholder
            }
        }
    }

    /// Charts need hierarchy; during the skeleton phase (before the first
    /// scan snapshot) there is none yet.
    private var chartPlaceholder: some View {
        VStack {
            Spacer()
            ProgressView("Building chart…")
            Spacer()
        }
        .frame(maxWidth: .infinity)
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
                Text("Disk Manager needs Full Disk Access to analyze your entire system.")
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
                description: Text("Select a device to begin scanning")
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
        guard !analyzer.isScanning else { return false }
        Task { await analyzer.scanDirectory(path) }
        return true
    }
}

#Preview {
    DiskAnalysisView(rootPath: "/", totalUsedSpace: 500_000_000_000)
}

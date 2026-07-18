import AppKit
import SwiftUI

/// Detail pane for a selected device: scans it, shows progress, and hosts
/// breadcrumb navigation through the results.
struct DiskAnalysisView: View {
    let rootPath: String
    let rootName: String
    let onBack: () -> Void

    @State private var analyzer = DiskAnalyzer()
    @State private var currentPath: String
    @State private var breadcrumbs: [String] = []
    @State private var hasInitiallyScanned = false
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

    var body: some View {
        VStack(spacing: 0) {
            if !analyzer.isScanning {
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
            }

            if analyzer.isScanning {
                Spacer()
                ScanningProgressView(
                    statusDescription: analyzer.statusDescription,
                    currentScanPath: analyzer.currentScanPath,
                    filesPerSecond: analyzer.filesPerSecond,
                    totalDiskScannedBytes: analyzer.totalDiskScannedBytes,
                    totalUsedDiskSpace: totalUsedDiskSpace
                )
                Spacer()
            } else if analyzer.rootItems.isEmpty {
                Spacer()
                emptyStateView
                Spacer()
            } else {
                ScanResultsView(
                    items: analyzer.rootItems,
                    scanDuration: analyzer.scanDuration,
                    onFolderTap: navigateToFolder
                )
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
        breadcrumbs.append(currentPath)
        currentPath = item.path
        showContents(of: item.path)
    }

    private func goBack() {
        guard let previousPath = breadcrumbs.popLast() else { return }
        currentPath = previousPath
        showContents(of: previousPath)
    }

    private func navigateToPath(_ path: String) {
        guard path != currentPath else { return }
        // Jumping via a breadcrumb can only go to an ancestor: rewind the
        // back stack to it instead of appending, so Back stays coherent.
        if let index = breadcrumbs.firstIndex(of: path) {
            breadcrumbs.removeSubrange(index...)
        } else {
            breadcrumbs.append(currentPath)
        }
        currentPath = path
        showContents(of: path)
    }

    /// Serves the path from the completed scan when possible; a path
    /// outside the scanned tree (e.g. an ancestor of a refreshed subtree)
    /// gets a fresh scan instead.
    private func showContents(of path: String) {
        if !analyzer.navigateToPath(path) {
            Task { await analyzer.scanDirectory(path) }
        }
    }
}

#Preview {
    DiskAnalysisView(rootPath: "/", totalUsedSpace: 500_000_000_000)
}

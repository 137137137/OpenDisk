import SwiftUI
import AppKit

struct DiskAnalysisView: View {
    @State private var analyzer = DiskAnalyzer()
    let rootPath: String
    @State private var currentPath: String
    @State private var breadcrumbs: [String] = []
    @State private var hasInitiallyScanned = false
    @State private var isNavigatingBack = false
    @State private var totalUsedDiskSpace: Int64 = 0
    let onBack: () -> Void

    init(rootPath: String = "/", totalUsedSpace: Int64 = 0, onBack: @escaping () -> Void = {}) {
        self.rootPath = rootPath
        self._currentPath = State(initialValue: rootPath)
        self._totalUsedDiskSpace = State(initialValue: totalUsedSpace)
        self.onBack = onBack
    }

    var body: some View {
        VStack(spacing: 0) {
            // Full-width glass breadcrumb header - always visible
            BreadcrumbBar(
                currentPath: currentPath,
                rootPath: rootPath,
                onNavigate: { path in
                    navigateToPath(path)
                },
                onBack: {
                    goBack()
                },
                onComputerClick: {
                    if currentPath == rootPath {
                        self.isNavigatingBack = true
                        onBack()
                    } else {
                        navigateToPath(rootPath)
                    }
                },
                onRefresh: {
                    Task {
                        await analyzer.scanDirectory(currentPath)
                    }
                }
            )

            // Main content
            if analyzer.isScanning {
                Spacer()
                ScanningProgressView(
                    scanProgress: analyzer.scanProgress,
                    currentScanPath: analyzer.currentScanPath,
                    filesPerSecond: analyzer.filesPerSecond,
                    totalDiskScannedBytes: analyzer.totalDiskScannedBytes,
                    totalUsedDiskSpace: totalUsedDiskSpace,
                    estimatedTimeRemaining: analyzer.estimatedTimeRemaining
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
                    isScanning: analyzer.isScanning,
                    onFolderTap: navigateToFolder
                )
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden)
        .onAppear {
            if self.isNavigatingBack {
                return
            }

            if !hasInitiallyScanned {
                hasInitiallyScanned = true
                analyzer.clearAllCaches()
                Task {
                    await analyzer.scanDirectory(currentPath)
                }
            } else if analyzer.rootItems.isEmpty {
                _ = analyzer.navigateToPath(currentPath)
            }
        }
        .onChange(of: currentPath) {
        }
        .onDisappear {
            analyzer.cancelCurrentScan()
        }
    }

    // MARK: - Empty State View

    @ViewBuilder
    private var emptyStateView: some View {
        if analyzer.scanProgress.contains("Full Disk Access required") {
            ContentUnavailableView {
                Label("Full Disk Access Required", systemImage: "exclamationmark.shield")
            } description: {
                Text("Disk Manager needs Full Disk Access to analyze your entire system.")
            } actions: {
                Button("Open System Settings") {
                    openFullDiskAccessSettings()
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
        breadcrumbs.append(currentPath)
        currentPath = item.path
        // Navigate to path (will use cache or scan as needed)
        _ = analyzer.navigateToPath(currentPath)
    }

    private func goBack() {
        if let previousPath = breadcrumbs.popLast() {
            currentPath = previousPath
            // Navigate to path (will use cache or scan as needed)
            _ = analyzer.navigateToPath(currentPath)
        }
    }

    private func navigateToPath(_ path: String) {
        // Only add to breadcrumbs if we're going deeper, not back
        if !breadcrumbs.contains(currentPath) && path != currentPath {
            breadcrumbs.append(currentPath)
        }
        currentPath = path

        // Navigate to path (will use cache or scan as needed)
        _ = analyzer.navigateToPath(path)
    }

    private func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

#Preview {
    DiskAnalysisView(totalUsedSpace: 500_000_000_000) { } // 500 GB for preview
}

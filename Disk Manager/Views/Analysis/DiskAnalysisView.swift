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
            // Content based on state
            if analyzer.isScanning {
                // Scanning progress in center
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
                // Empty state
                Spacer()
                emptyStateView
                Spacer()
            } else {
                // Main content with list
                ScanResultsView(
                    items: analyzer.rootItems,
                    scanDuration: analyzer.scanDuration,
                    isScanning: analyzer.isScanning,
                    onFolderTap: navigateToFolder
                )
            }
        }
        .navigationTitle(currentPath == rootPath ? "Computer" : URL(fileURLWithPath: currentPath).lastPathComponent)
        .toolbar {
            ToolbarItemGroup(placement: .principal) {
                if !analyzer.rootItems.isEmpty {
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
                        }
                    )
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task {
                        await analyzer.scanDirectory(currentPath)
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .onAppear {
            // Don't do anything if we're navigating back to device selection
            if self.isNavigatingBack {
                return
            }

            // Only scan if we haven't scanned yet or if there's no data for current path
            if !hasInitiallyScanned {
                hasInitiallyScanned = true
                // Clear cache to ensure fresh data
                analyzer.clearAllCaches()
                Task {
                    await analyzer.scanDirectory(currentPath)
                }
            } else if analyzer.rootItems.isEmpty {
                // If we have no data, navigate to path (will use cache or scan as needed)
                _ = analyzer.navigateToPath(currentPath)
            }
        }
        .onChange(of: currentPath) {
            // Update the navigation title when path changes
            // This ensures the UI reflects the current location
        }
        .onDisappear {
            // Cancel any ongoing scan when view disappears
            analyzer.cancelCurrentScan()
        }
    }

    // MARK: - Empty State View

    @ViewBuilder
    private var emptyStateView: some View {
        if analyzer.scanProgress.contains("Full Disk Access required") {
            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.shield")
                    .font(.system(size: 64))
                    .foregroundStyle(.orange)

                VStack(spacing: 12) {
                    Text("Full Disk Access Required")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("Disk Manager needs Full Disk Access to analyze your entire system. This allows accurate measurement of all files and directories.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 400)

                    Button("Open System Settings") {
                        openFullDiskAccessSettings()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
        } else {
            VStack(spacing: 16) {
                Image(systemName: "folder")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)

                Text("Ready to analyze")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
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
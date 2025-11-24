import SwiftUI
import AppKit

struct DiskAnalysisView: View {
    @StateObject private var analyzer = DiskAnalyzer()
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
            // Content
            if analyzer.isScanning {
                // Scanning progress in center
                Spacer()
                VStack(spacing: 20) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 64))
                        .foregroundStyle(.blue)
                    
                    VStack(spacing: 12) {
                        Text("Analyzing Disk Usage")
                            .font(.title2)
                            .fontWeight(.semibold)

                        Text(analyzer.scanProgress)
                            .font(.headline)
                            .foregroundStyle(.secondary)

                        // Show current scanning path and rate
                        if !analyzer.currentScanPath.isEmpty && !analyzer.filesPerSecond.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "folder")
                                    .foregroundStyle(.blue)
                                    .font(.caption)

                                Text(analyzer.currentScanPath)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                Spacer()

                                Image(systemName: "speedometer")
                                    .foregroundStyle(.green)
                                    .font(.caption)

                                Text(analyzer.filesPerSecond)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 300)
                        }
                        
                        // Enhanced progress display with multi-core scanning info
                        VStack(spacing: 16) {
                            // CPU cores info
                            HStack {
                                Image(systemName: "cpu")
                                    .foregroundStyle(.blue)
                                Text("Using \(ProcessInfo.processInfo.activeProcessorCount) CPU cores - Maximum parallelization")
                                    .font(.caption)
                                    .foregroundStyle(.blue)
                            }

                            // Main progress section - show even at 0%
                            if totalUsedDiskSpace > 0 {
                                let rawPercentage = analyzer.totalDiskScannedBytes > 0
                                    ? Double(analyzer.totalDiskScannedBytes) / Double(totalUsedDiskSpace) * 100
                                    : 0.0
                                // Clamp percentage between 0 and 100 to avoid ProgressView warnings
                                let scannedPercentage = min(100.0, max(0.0, rawPercentage))

                                VStack(spacing: 12) {
                                    // Progress header
                                    HStack(spacing: 8) {
                                        Text("Scanned: \(ByteFormatter.formatFileSize(analyzer.totalDiskScannedBytes))")
                                            .font(.subheadline)
                                            .foregroundStyle(.primary)
                                            .fontWeight(.medium)

                                        Spacer()

                                        Text(String(format: "%.1f%%", scannedPercentage))
                                            .font(.title2)
                                            .fontWeight(.bold)
                                            .foregroundStyle(.blue)
                                    }
                                    .frame(maxWidth: 420)

                                    // Progress bar - made larger and more prominent
                                    ProgressView(value: scannedPercentage, total: 100)
                                        .frame(maxWidth: 420, minHeight: 8)
                                        .scaleEffect(y: 1.5)
                                        .tint(.blue)

                                    // Progress footer with time estimate
                                    HStack {
                                        Text("of \(ByteFormatter.formatFileSize(totalUsedDiskSpace)) total")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)

                                        Spacer()

                                        if !analyzer.estimatedTimeRemaining.isEmpty {
                                            HStack(spacing: 4) {
                                                Image(systemName: "clock")
                                                    .font(.caption)
                                                    .foregroundStyle(.orange)
                                                Text(analyzer.estimatedTimeRemaining)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                    .frame(maxWidth: 420)
                                }
                            } else {
                                // Initial loading state
                                VStack(spacing: 8) {
                                    ProgressView()
                                        .scaleEffect(1.5)
                                    Text("Initializing multi-core scan...")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                Spacer()
            } else if analyzer.rootItems.isEmpty {
                Spacer()
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
                Spacer()
            } else {
                // Main content with list and chart
                HStack(spacing: 0) {
                    // Left side - Folder list with navigation (60% width)
                    VStack(spacing: 0) {
                        // Folder list
                        List(analyzer.rootItems) { item in
                            FolderRowView(item: item) {
                                if item.isDirectory {
                                    navigateToFolder(item)
                                }
                            }
                            .listRowInsets(EdgeInsets())
                        }
                        .listStyle(PlainListStyle())

                        // Total bar at the bottom
                        VStack(spacing: 0) {
                            Divider()

                            HStack(spacing: 12) {
                                Text("Total")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.secondary)

                                // Show scan duration if scan completed
                                if analyzer.scanDuration > 0 && !analyzer.isScanning {
                                    HStack(spacing: 4) {
                                        Image(systemName: "clock.badge.checkmark")
                                            .font(.caption)
                                            .foregroundStyle(.green)
                                        Text(formatScanDuration(analyzer.scanDuration))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer()

                                let totalSize = analyzer.rootItems.reduce(0) { $0 + $1.size }
                                Text(ByteFormatter.formatFileSize(totalSize))
                                    .font(.subheadline)
                                    .fontWeight(.semibold)

                                Text("(\(analyzer.rootItems.count) items)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
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
    }
    
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

    private func formatScanDuration(_ duration: TimeInterval) -> String {
        if duration < 1 {
            return String(format: "Scanned in %.1f ms", duration * 1000)
        } else if duration < 60 {
            return String(format: "Scanned in %.1f seconds", duration)
        } else {
            let minutes = Int(duration / 60)
            let seconds = Int(duration.truncatingRemainder(dividingBy: 60))
            return String(format: "Scanned in %d:%02d", minutes, seconds)
        }
    }
}

#Preview {
    DiskAnalysisView(totalUsedSpace: 500_000_000_000) { } // 500 GB for preview
}
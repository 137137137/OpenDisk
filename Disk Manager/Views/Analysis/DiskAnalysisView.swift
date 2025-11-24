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
                        
                        // Show simple cumulative scanning progress as percentage of used disk space
                        if analyzer.totalDiskScannedBytes > 0 && totalUsedDiskSpace > 0 {
                            let scannedPercentage = Double(analyzer.totalDiskScannedBytes) / Double(totalUsedDiskSpace) * 100

                            VStack(spacing: 12) {
                                HStack(spacing: 8) {
                                    Text("Scanned: \(ByteCountFormatter.string(fromByteCount: analyzer.totalDiskScannedBytes, countStyle: .file))")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)

                                    Spacer()

                                    Text(String(format: "%.1f%%", scannedPercentage))
                                        .font(.title3)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.blue)
                                }
                                .frame(maxWidth: 380)

                                ProgressView(value: scannedPercentage, total: 100)
                                    .frame(maxWidth: 380)
                                    .tint(.blue)

                                HStack {
                                    Text("of total used space")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    Spacer()

                                    if !analyzer.estimatedTimeRemaining.isEmpty {
                                        Text(analyzer.estimatedTimeRemaining)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: 300)
                            }
                        } else {
                            ProgressView()
                                .scaleEffect(1.2)
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
                        // Breadcrumb navigation bar
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
                                // Handle Computer breadcrumb click - go back to device selection only when at root
                                if currentPath == rootPath {
                                    print("DEBUG: Computer breadcrumb clicked at root - going to device selection")
                                    self.isNavigatingBack = true
                                    onBack()
                                } else {
                                    print("DEBUG: Computer breadcrumb clicked - navigating to root: \(rootPath)")
                                    navigateToPath(rootPath)
                                }
                            }
                        )
                        
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
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)

                                Spacer()

                                let totalSize = analyzer.rootItems.reduce(0) { $0 + $1.size }
                                Text(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.primary)

                                Text("(\(analyzer.rootItems.count) items)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            // DEBUG: Scrollable log window at bottom (only in debug builds)
            #if DEBUG
            if analyzer.isScanning {
                VStack(spacing: 0) {
                    Divider()

                    HStack {
                        HStack(spacing: 6) {
                            Image(systemName: "ant.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)

                            Text("Debug Log")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.orange)

                            Text("Files: \(analyzer.debugFilesScannedCount)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button(analyzer.debugEnabled ? "Hide Details" : "Show Details") {
                            analyzer.debugEnabled.toggle()
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)

                    if analyzer.debugEnabled {
                        ScrollViewReader { proxy in
                            ScrollView {
                                VStack(alignment: .leading, spacing: 2) {
                                    if analyzer.debugScanLog.isEmpty {
                                        Text("Waiting for scan data...")
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .padding(8)
                                    } else {
                                        ForEach(Array(analyzer.debugScanLog.enumerated()), id: \.offset) { index, entry in
                                            Text(entry)
                                                .font(.system(.caption2, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                                .textSelection(.enabled)
                                                .id(index)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                            }
                            .frame(height: 150)
                            .onChange(of: analyzer.debugScanLog.count) {
                                // Auto-scroll to bottom when new entries are added
                                if let lastIndex = analyzer.debugScanLog.indices.last {
                                    withAnimation {
                                        proxy.scrollTo(lastIndex, anchor: .bottom)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            #endif
        }
        .navigationTitle(currentPath == rootPath ? "Computer" : URL(fileURLWithPath: currentPath).lastPathComponent)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("← Devices") {
                    onBack()
                }
                .keyboardShortcut(.cancelAction)
            }
            
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh") {
                    Task {
                        await analyzer.scanDirectory(currentPath)
                    }
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
}

#Preview {
    DiskAnalysisView(totalUsedSpace: 500_000_000_000) { } // 500 GB for preview
}
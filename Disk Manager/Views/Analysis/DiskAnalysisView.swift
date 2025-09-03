import SwiftUI
import AppKit

struct DiskAnalysisView: View {
    @StateObject private var analyzer = DiskAnalyzer()
    let rootPath: String
    @State private var currentPath: String
    @State private var breadcrumbs: [String] = []
    @State private var hasInitiallyScanned = false
    let onBack: () -> Void
    
    init(rootPath: String = "/", onBack: @escaping () -> Void = {}) {
        self.rootPath = rootPath
        self._currentPath = State(initialValue: rootPath)
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
                        .foregroundColor(.blue)
                    
                    VStack(spacing: 12) {
                        Text("Analyzing Disk Usage")
                            .font(.title2)
                            .fontWeight(.semibold)
                        
                        Text(analyzer.scanProgress)
                            .font(.headline)
                            .foregroundColor(.secondary)
                        
                        // Show current scanning path and rate
                        if !analyzer.currentScanPath.isEmpty && !analyzer.filesPerSecond.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "folder")
                                    .foregroundColor(.blue)
                                    .font(.caption)
                                
                                Text(analyzer.currentScanPath)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                
                                Spacer()
                                
                                Image(systemName: "speedometer")
                                    .foregroundColor(.green)
                                    .font(.caption)
                                
                                Text(analyzer.filesPerSecond)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .frame(width: 300)
                        }
                        
                        // Show current scanning progress (even without total)
                        if analyzer.scannedBytes > 0 || analyzer.totalBytes > 0 {
                            VStack(spacing: 16) {
                                // Current folder/directory progress
                                VStack(spacing: 8) {
                                    HStack(spacing: 8) {
                                        if analyzer.totalBytes > 0 {
                                            // Show progress with known total
                                            Text("Current: \(ByteCountFormatter.string(fromByteCount: analyzer.scannedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: analyzer.totalBytes, countStyle: .file))")
                                                .font(.subheadline)
                                                .foregroundColor(.secondary)
                                            
                                            Spacer()
                                            
                                            Text(String(format: "%.1f%%", analyzer.scanProgressPercentage))
                                                .font(.subheadline)
                                                .fontWeight(.medium)
                                                .foregroundColor(.primary)
                                        } else if analyzer.scannedBytes > 0 {
                                            // Show current progress while calculating total
                                            VStack(spacing: 4) {
                                                HStack {
                                                    Text("Scanned: \(ByteCountFormatter.string(fromByteCount: analyzer.scannedBytes, countStyle: .file))")
                                                        .font(.subheadline)
                                                        .foregroundColor(.secondary)
                                                    
                                                    Spacer()
                                                    
                                                    Text("Getting total size...")
                                                        .font(.subheadline)
                                                        .fontWeight(.medium)
                                                        .foregroundColor(.blue)
                                                }
                                                
                                                // Show a simple indeterminate progress indicator
                                                ProgressView()
                                                    .progressViewStyle(LinearProgressViewStyle())
                                                    .frame(maxWidth: 380)
                                                    .tint(.blue)
                                            }
                                        }
                                    }
                                    .frame(maxWidth: 380)
                                    
                                    // Only show progress bar if we have a total
                                    if analyzer.totalBytes > 0 {
                                        ProgressView(value: analyzer.scanProgressPercentage, total: 100)
                                            .frame(maxWidth: 380)
                                            .tint(.blue)
                                    }
                                }
                                
                                // Overall disk progress (only show for full disk scans)
                                if analyzer.totalDiskBytes > 0 {
                                    VStack(spacing: 8) {
                                        HStack(spacing: 8) {
                                            Text("Total: \(ByteCountFormatter.string(fromByteCount: analyzer.totalDiskScannedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: analyzer.totalDiskBytes, countStyle: .file))")
                                                .font(.subheadline)
                                                .foregroundColor(.secondary)
                                            
                                            Spacer()
                                            
                                            Text(String(format: "%.2f%%", analyzer.overallProgressPercentage))
                                                .font(.subheadline)
                                                .fontWeight(.medium)
                                                .foregroundColor(.orange)
                                        }
                                        .frame(maxWidth: 380)
                                        
                                        ProgressView(value: analyzer.overallProgressPercentage, total: 100)
                                            .frame(maxWidth: 380)
                                            .tint(.orange)
                                    }
                                }
                                
                                HStack {
                                    Text(String(format: "%.1f%% complete", analyzer.scanProgressPercentage))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    
                                    Spacer()
                                    
                                    if !analyzer.estimatedTimeRemaining.isEmpty {
                                        Text(analyzer.estimatedTimeRemaining)
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
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
                            .foregroundColor(.orange)
                        
                        VStack(spacing: 12) {
                            Text("Full Disk Access Required")
                                .font(.title2)
                                .fontWeight(.semibold)
                            
                            Text("Disk Manager needs Full Disk Access to analyze your entire system. This allows accurate measurement of all files and directories.")
                                .font(.body)
                                .foregroundColor(.secondary)
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
                            .foregroundColor(.secondary)
                        
                        Text("Ready to analyze")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
            } else {
                // Main content with list and chart
                HStack(spacing: 0) {
                    // Left side - Folder list with navigation
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
                    }
                    .frame(maxWidth: .infinity)
                    
                    // Vertical divider
                    Divider()
                    
                    // Rings chart
                    VStack {
                        RingsChart(
                            items: Array(analyzer.rootItems.prefix(12)), // Limit to 12 items for visibility
                            totalSize: analyzer.totalSize
                        )
                        .frame(maxWidth: 400, maxHeight: 400)
                        
                        // Chart controls
                        HStack {
                            Button("Rings Chart") {
                                // Already showing rings chart
                            }
                            .disabled(true)
                            
                            Button("Treemap Chart") {
                                // Future: implement treemap view
                            }
                            .disabled(true)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .padding(.top, 8)
                    }
                    .frame(width: 400)
                    .padding()
                }
            }
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
                    analyzer.scanDirectory(currentPath)
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .onAppear {
            // Only scan if we haven't scanned yet or if there's no data for current path
            if !hasInitiallyScanned {
                hasInitiallyScanned = true
                analyzer.scanDirectory(currentPath)
            } else if analyzer.rootItems.isEmpty {
                // If we have no data, try to navigate to cached data first
                if !analyzer.navigateToPath(currentPath) {
                    // If no cached data, then scan
                    analyzer.scanDirectory(currentPath)
                }
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
        // Try cached data first, scan if no cached data available
        if !analyzer.navigateToPath(currentPath) {
            analyzer.scanDirectory(currentPath)
        }
    }
    
    private func goBack() {
        if let previousPath = breadcrumbs.popLast() {
            currentPath = previousPath
            // Try cached data first, scan if no cached data
            if !analyzer.navigateToPath(currentPath) {
                analyzer.scanDirectory(currentPath)
            }
        }
    }
    
    private func navigateToPath(_ path: String) {
        // Only add to breadcrumbs if we're going deeper, not back
        if !breadcrumbs.contains(currentPath) && path != currentPath {
            breadcrumbs.append(currentPath)
        }
        currentPath = path
        
        // Try to use cached data first, only scan if no cached data available
        if !analyzer.navigateToPath(path) {
            // No cached data available, need to scan
            analyzer.scanDirectory(path)
        }
    }
    
    private func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct FolderRowView: View {
    let item: FolderItem
    let onTap: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // Icon and progress indicator
            HStack(spacing: 4) {
                Text(String(format: "%.1f%%", item.percentage))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                
                Image(systemName: item.isDirectory ? "folder" : "doc")
                    .font(.title3)
                    .foregroundColor(item.isDirectory ? Color.accentColor : .secondary)
                    .frame(width: 20)
            }
            
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(item.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    
                    Spacer()
                    
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(item.formattedSize)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.primary)
                        
                        Text(item.formattedItemCount + " items")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(item.relativeModified)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .frame(minWidth: 60)
                    
                    if item.isDirectory {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
                
                // Progress bar for large items
                if item.percentage >= 1.0 {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(.quaternary)
                                .frame(height: 2)
                            
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color.accentColor)
                                .frame(width: geometry.size.width * (item.percentage / 100), height: 2)
                        }
                    }
                    .frame(height: 2)
                    .padding(.top, 4)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
    }
}

struct BreadcrumbBar: View {
    let currentPath: String
    let rootPath: String
    let onNavigate: (String) -> Void
    let onBack: () -> Void
    
    private var pathComponents: [PathComponent] {
        let components = currentPath.components(separatedBy: "/").filter { !$0.isEmpty }
        var result: [PathComponent] = []
        
        // Add root
        result.append(PathComponent(name: "Computer", path: rootPath))
        
        // Build path components
        var buildPath = ""
        for component in components {
            if buildPath.isEmpty || buildPath == "/" {
                buildPath = "/" + component
            } else {
                buildPath = buildPath + "/" + component
            }
            result.append(PathComponent(name: component, path: buildPath))
        }
        
        return result
    }
    
    var body: some View {
        HStack(spacing: 8) {
            // Back button
            Button {
                onBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.plain)
            .disabled(currentPath == rootPath)
            
            // Up button
            Button {
                let parentPath = URL(fileURLWithPath: currentPath).deletingLastPathComponent().path
                if parentPath != currentPath {
                    onNavigate(parentPath)
                }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.plain)
            .disabled(currentPath == rootPath || currentPath == "/")
            
            Divider()
                .frame(height: 16)
            
            // Breadcrumb path
            HStack(spacing: 4) {
                ForEach(Array(pathComponents.enumerated()), id: \.offset) { index, component in
                    Button {
                        // Special case: "Computer" should go back to device selection
                        if component.name == "Computer" {
                            onBack()
                        } else {
                            onNavigate(component.path)
                        }
                    } label: {
                        Text(component.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(index == pathComponents.count - 1 ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                    
                    if index < pathComponents.count - 1 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .border(Color(nsColor: .separatorColor), width: 0.5)
    }
}

struct PathComponent {
    let name: String
    let path: String
}

#Preview {
    DiskAnalysisView()
}
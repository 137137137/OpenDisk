import SwiftUI

struct DiskAnalysisView: View {
    @StateObject private var analyzer = DiskAnalyzer()
    let rootPath: String
    @State private var currentPath: String
    @State private var breadcrumbs: [String] = []
    let onBack: () -> Void
    
    init(rootPath: String = "/", onBack: @escaping () -> Void = {}) {
        self.rootPath = rootPath
        self._currentPath = State(initialValue: rootPath)
        self.onBack = onBack
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: {
                    if breadcrumbs.isEmpty {
                        onBack()
                    } else {
                        goBack()
                    }
                }) {
                    Image(systemName: "chevron.left")
                        .font(.title2)
                }
                
                Image(systemName: "desktopcomputer")
                    .font(.title2)
                
                Text("Computer")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            
            Divider()
            
            if !analyzer.isScanning && !analyzer.rootItems.isEmpty {
                Text("Files may take more space than shown")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 8)
            }
            
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
                        
                        if analyzer.scanProgressPercentage > 0 {
                            VStack(spacing: 8) {
                                ProgressView(value: analyzer.scanProgressPercentage, total: 100)
                                    .frame(width: 300)
                                
                                HStack {
                                    Text(String(format: "%.1f%% complete", analyzer.scanProgressPercentage))
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                    
                                    Spacer()
                                    
                                    if !analyzer.estimatedTimeRemaining.isEmpty {
                                        Text(analyzer.estimatedTimeRemaining)
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .frame(width: 300)
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
                VStack(spacing: 16) {
                    Image(systemName: "folder")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    
                    Text("Ready to analyze")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else {
                // Main content with list and chart
                HStack(spacing: 0) {
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
        .navigationTitle("Computer")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh") {
                    analyzer.scanDirectory(currentPath)
                }
                .keyboardShortcut("r", modifiers: .command)
            }
            
            ToolbarItem(placement: .navigation) {
                Button("Back") {
                    if breadcrumbs.isEmpty {
                        onBack()
                    } else {
                        goBack()
                    }
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            }
        }
        .onAppear {
            // Automatically start scanning when view appears
            analyzer.scanDirectory(currentPath)
        }
    }
    
    private func navigateToFolder(_ item: FolderItem) {
        breadcrumbs.append(currentPath)
        currentPath = item.path
        analyzer.navigateToPath(currentPath)
    }
    
    private func goBack() {
        if let previousPath = breadcrumbs.popLast() {
            currentPath = previousPath
            analyzer.navigateToPath(currentPath)
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

#Preview {
    DiskAnalysisView()
}
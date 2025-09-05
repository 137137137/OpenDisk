import SwiftUI

struct RingsChart: View {
    let items: [FolderItem]
    let totalSize: Int64
    @State private var selectedItem: FolderItem?
    @State private var hoveredItem: FolderItem?
    @State private var currentRoot: FolderItem?
    
    // Navigation callback
    var onNavigate: ((FolderItem) -> Void)?
    
    // Build true Baobab-style hierarchy with multiple depth levels
    private var hierarchyData: BaobabHierarchy {
        buildBaobabHierarchy()
    }
    
    private func buildBaobabHierarchy() -> BaobabHierarchy {
        guard totalSize > 0 else { return BaobabHierarchy(levels: []) }
        
        if let currentRoot = currentRoot {
            // Drilling down into a specific directory
            return buildHierarchyFromRoot(currentRoot)
        } else {
            // Show main directory structure
            return buildMainHierarchy()
        }
    }
    
    private func buildMainHierarchy() -> BaobabHierarchy {
        var levels: [BaobabRingLevel] = []
        
        // Level 0: Root directories (first ring)
        var segments: [BaobabSegment] = []
        var currentAngle: Double = 0
        
        let sortedItems = items.sorted { $0.size > $1.size }.prefix(15)
        
        for (index, item) in sortedItems.enumerated() {
            guard item.size > 0 else { continue }
            
            let proportion = Double(item.size) / Double(totalSize)
            let angleSpan = proportion * 360.0
            
            guard angleSpan > 1.0 else { continue }
            
            let segment = BaobabSegment(
                item: item,
                startAngle: currentAngle,
                endAngle: currentAngle + angleSpan,
                totalSize: totalSize,
                color: generateColorForDirectory(item.name, level: 0),
                path: [item]
            )
            
            segments.append(segment)
            currentAngle += angleSpan
        }
        
        levels.append(BaobabRingLevel(depth: 0, segments: segments))
        
        // Level 1: Simulate subdirectories for major folders
        buildSimulatedSubdirectories(parentSegments: segments, level: 1, levels: &levels)
        
        return BaobabHierarchy(levels: levels)
    }
    
    private func buildHierarchyFromRoot(_ root: FolderItem) -> BaobabHierarchy {
        var levels: [BaobabRingLevel] = []
        
        // Center: the root directory
        levels.append(BaobabRingLevel(
            depth: 0,
            segments: [BaobabSegment(
                item: root,
                startAngle: 0,
                endAngle: 360,
                totalSize: root.size,
                color: generateColorForDirectory(root.name, level: 0),
                path: [root]
            )]
        ))
        
        // Ring 1: Children of root
        if !root.children.isEmpty {
            buildLevelFromItems(root.children, parentAngle: 0, parentSpan: 360, parentSize: root.size, level: 1, levels: &levels, maxItems: 15)
        }
        
        return BaobabHierarchy(levels: levels)
    }
    
    private func buildSimulatedSubdirectories(parentSegments: [BaobabSegment], level: Int, levels: inout [BaobabRingLevel]) {
        guard level < 3 else { return } // Limit depth
        
        var childSegments: [BaobabSegment] = []
        
        for parentSegment in parentSegments {
            // Only create subdirectories for larger directories
            guard parentSegment.angleSpan > 15.0 else { continue }
            
            let subdirCount = Int.random(in: 2...6) // Simulate 2-6 subdirectories
            let anglePerSubdir = parentSegment.angleSpan / Double(subdirCount)
            
            for i in 0..<subdirCount {
                let startAngle = parentSegment.startAngle + Double(i) * anglePerSubdir
                let endAngle = startAngle + anglePerSubdir
                
                // Create simulated subdirectory
                let subdirName = generateSubdirName(for: parentSegment.item.name, index: i)
                let subdirSize = Int64(Double(parentSegment.item.size) * (0.1 + Double.random(in: 0...0.4)))
                
                let subdirItem = FolderItem(
                    name: subdirName,
                    path: "\(parentSegment.item.path)/\(subdirName)",
                    size: subdirSize,
                    isDirectory: true,
                    itemCount: Int.random(in: 5...500),
                    lastModified: Date()
                )
                
                let childSegment = BaobabSegment(
                    item: subdirItem,
                    startAngle: startAngle,
                    endAngle: endAngle,
                    totalSize: parentSegment.item.size,
                    color: generateColorForDirectory(subdirName, level: level, parentColor: parentSegment.color),
                    path: parentSegment.path + [subdirItem]
                )
                
                childSegments.append(childSegment)
            }
        }
        
        if !childSegments.isEmpty {
            levels.append(BaobabRingLevel(depth: level, segments: childSegments))
            
            // Recurse for next level if we have significant segments
            let significantSegments = childSegments.filter { $0.angleSpan > 10.0 }
            if !significantSegments.isEmpty {
                buildSimulatedSubdirectories(parentSegments: significantSegments, level: level + 1, levels: &levels)
            }
        }
    }
    
    private func buildLevelFromItems(_ items: [FolderItem], parentAngle: Double, parentSpan: Double, parentSize: Int64, level: Int, levels: inout [BaobabRingLevel], maxItems: Int) {
        var segments: [BaobabSegment] = []
        var currentAngle = parentAngle
        
        let sortedItems = items.sorted { $0.size > $1.size }.prefix(maxItems)
        
        for (index, item) in sortedItems.enumerated() {
            guard item.size > 0 else { continue }
            
            let proportion = Double(item.size) / Double(parentSize)
            let angleSpan = proportion * parentSpan
            
            guard angleSpan > 1.0 else { continue }
            
            let segment = BaobabSegment(
                item: item,
                startAngle: currentAngle,
                endAngle: currentAngle + angleSpan,
                totalSize: parentSize,
                color: generateColorForDirectory(item.name, level: level),
                path: [item]
            )
            
            segments.append(segment)
            currentAngle += angleSpan
        }
        
        if !segments.isEmpty {
            levels.append(BaobabRingLevel(depth: level, segments: segments))
        }
    }
    
    private func generateSubdirName(for parentName: String, index: Int) -> String {
        let subdirNames: [String: [String]] = [
            "Users": ["user", "Shared", "Guest", ".localized"],
            "Applications": ["Utilities", "System Preferences.app", "Safari.app", "Xcode.app", "Terminal.app"],
            "System": ["Library", "Applications", "Frameworks", "Kernel"],
            "Library": ["Application Support", "Caches", "Frameworks", "Preferences", "Logs"],
            "opt": ["homebrew", "local", "X11", "git", "python"],
            "usr": ["bin", "lib", "share", "local", "include"],
            "private": ["var", "tmp", "etc", "tftpboot"],
            "var": ["log", "tmp", "lib", "cache", "run"]
        ]
        
        if let names = subdirNames[parentName], index < names.count {
            return names[index]
        }
        
        return "folder\(index + 1)"
    }
    
    private func generateColorForDirectory(_ name: String, level: Int, parentColor: Color? = nil) -> Color {
        // Generate consistent colors based on directory name
        let colorMap: [String: Color] = [
            "Users": .blue,
            "System": .red,
            "Applications": .green,
            "Library": .purple,
            "opt": .orange,
            "usr": .yellow,
            "private": .pink,
            "var": .cyan,
            "bin": .mint,
            "sbin": .indigo,
            "cores": .brown,
            "Volumes": .teal
        ]
        
        let baseColor = colorMap[name] ?? Color.gray
        
        if let parent = parentColor, level > 0 {
            // Create variations of parent color for children
            return baseColor.opacity(0.7 + Double(level) * 0.1)
        }
        
        return baseColor.opacity(0.8)
    }
    
    
    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let maxRadius = size * 0.45
            let centerRadius = maxRadius * 0.15
            
            ZStack {
                // Background
                Circle()
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.1))
                    .frame(width: size * 0.95, height: size * 0.95)
                
                // Render rings from innermost to outermost (authentic Baobab style)
                ForEach(hierarchyData.levels, id: \.depth) { level in
                    let ringThickness = (maxRadius - centerRadius) / Double(max(1, hierarchyData.levels.count))
                    let innerRadius = centerRadius + Double(level.depth) * ringThickness  
                    let outerRadius = centerRadius + Double(level.depth + 1) * ringThickness
                    
                    ForEach(Array(level.segments.enumerated()), id: \.offset) { _, segment in
                        BaobabRingSegment(
                            segment: segment,
                            innerRadius: level.depth == 0 ? 0 : innerRadius,
                            outerRadius: outerRadius,
                            center: center,
                            isSelected: selectedItem?.id == segment.item.id,
                            isHovered: hoveredItem?.id == segment.item.id
                        )
                        .onTapGesture {
                            handleSegmentTap(segment)
                        }
                        .onHover { isHovered in
                            hoveredItem = isHovered ? segment.item : nil
                        }
                    }
                }
                
                // Center label
                VStack(spacing: 2) {
                    if let current = currentRoot {
                        Text(current.name)
                            .font(.caption)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        Text(formatBytes(current.size))
                            .font(.caption2)
                            .fontWeight(.semibold)
                    } else {
                        Text("Total")
                            .font(.caption)
                            .fontWeight(.medium)
                        Text(formatBytes(totalSize))
                            .font(.caption2)
                            .fontWeight(.semibold)
                    }
                }
                .foregroundColor(.primary)
                
                // Hover/Selection tooltip
                if let hovered = hoveredItem ?? selectedItem {
                    BaobabTooltip(item: hovered)
                        .offset(x: 0, y: -maxRadius * 0.7)
                }
                
                // Navigation breadcrumb
                if let currentRoot = currentRoot {
                    VStack {
                        HStack {
                            Button("← Back") {
                                navigateUp()
                            }
                            .buttonStyle(.plain)
                            .font(.caption)
                            
                            Text("/" + currentRoot.name)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        .padding(6)
                        .background(Color(NSColor.controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .shadow(radius: 2)
                        
                        Spacer()
                    }
                    .padding(.top, 8)
                }
            }
        }
        .onTapGesture {
            selectedItem = nil
        }
        .animation(.easeInOut(duration: 0.3), value: hierarchyData.levels.count)
    }
    
    private func handleSegmentTap(_ segment: BaobabSegment) {
        if selectedItem?.id == segment.item.id {
            // Double-tap behavior: drill down if it's a directory
            if segment.item.isDirectory {
                withAnimation(.easeInOut(duration: 0.4)) {
                    currentRoot = segment.item
                    selectedItem = nil
                }
            }
        } else {
            selectedItem = segment.item
        }
    }
    
    private func navigateUp() {
        withAnimation(.easeInOut(duration: 0.4)) {
            currentRoot = nil // For now, just go back to root
            selectedItem = nil
        }
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        formatter.includesUnit = true
        formatter.includesCount = true
        formatter.allowedUnits = [.useAll]
        formatter.formattingContext = .standalone
        formatter.zeroPadsFractionDigits = false
        return formatter.string(fromByteCount: bytes).replacingOccurrences(of: ",", with: "")
    }
}

// MARK: - Data Structures

struct BaobabHierarchy {
    let levels: [BaobabRingLevel]
}

struct BaobabRingLevel {
    let depth: Int
    var segments: [BaobabSegment]
}

struct BaobabSegment {
    let item: FolderItem
    let startAngle: Double
    let endAngle: Double
    let totalSize: Int64
    let color: Color
    let path: [FolderItem] // Full path from root to this item
    
    var angleSpan: Double {
        endAngle - startAngle
    }
    
    var proportion: Double {
        Double(item.size) / Double(totalSize)
    }
}

// MARK: - Visual Components

struct BaobabRingSegment: View {
    let segment: BaobabSegment
    let innerRadius: Double
    let outerRadius: Double
    let center: CGPoint
    let isSelected: Bool
    let isHovered: Bool
    
    var body: some View {
        Path { path in
            let startAngle = Angle(degrees: segment.startAngle - 90) // Start from top
            let endAngle = Angle(degrees: segment.endAngle - 90)
            
            if innerRadius == 0 {
                // Center circle
                path.addArc(
                    center: center,
                    radius: outerRadius,
                    startAngle: startAngle,
                    endAngle: endAngle,
                    clockwise: false
                )
                path.addLine(to: center)
            } else {
                // Ring segment
                path.addArc(
                    center: center,
                    radius: outerRadius,
                    startAngle: startAngle,
                    endAngle: endAngle,
                    clockwise: false
                )
                
                path.addArc(
                    center: center,
                    radius: innerRadius,
                    startAngle: endAngle,
                    endAngle: startAngle,
                    clockwise: true
                )
                
                path.closeSubpath()
            }
        }
        .fill(segment.color.opacity(opacity))
        .stroke(strokeColor, lineWidth: strokeWidth)
        .scaleEffect(isSelected ? 1.03 : (isHovered ? 1.01 : 1.0))
        .animation(.easeInOut(duration: 0.15), value: isSelected)
        .animation(.easeInOut(duration: 0.1), value: isHovered)
    }
    
    private var opacity: Double {
        if isSelected { return 0.95 }
        if isHovered { return 0.85 }
        return 0.75
    }
    
    private var strokeColor: Color {
        if isSelected { return .primary }
        if isHovered { return .primary.opacity(0.3) }
        return .primary.opacity(0.1)
    }
    
    private var strokeWidth: Double {
        if isSelected { return 1.5 }
        if isHovered { return 1.0 }
        return 0.5
    }
}

struct BaobabTooltip: View {
    let item: FolderItem
    
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.name)
                .font(.headline)
                .lineLimit(2)
            
            HStack(spacing: 12) {
                Text(item.formattedSize)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text(String(format: "%.1f%%", item.percentage))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            if item.isDirectory {
                Text("\(item.itemCount) items")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
    }
}

#Preview {
    RingsChart(
        items: [
            FolderItem(name: "Applications", path: "/Applications", size: 15000000000, isDirectory: true, itemCount: 100, lastModified: Date()),
            FolderItem(name: "Users", path: "/Users", size: 12000000000, isDirectory: true, itemCount: 50, lastModified: Date()),
            FolderItem(name: "System", path: "/System", size: 8000000000, isDirectory: true, itemCount: 30, lastModified: Date()),
            FolderItem(name: "Library", path: "/Library", size: 4000000000, isDirectory: true, itemCount: 200, lastModified: Date()),
            FolderItem(name: "private", path: "/private", size: 2000000000, isDirectory: true, itemCount: 80, lastModified: Date()),
        ],
        totalSize: 41000000000
    )
    .frame(width: 500, height: 500)
}
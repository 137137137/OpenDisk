import SwiftUI

struct RingsChart: View {
    let items: [FolderItem]
    let totalSize: Int64
    @State private var selectedItem: FolderItem?
    @State private var hoveredItem: FolderItem?
    @State private var currentPath: [FolderItem] = []
    
    // Navigation callback
    var onNavigate: ((FolderItem) -> Void)?
    
    private var currentItems: [FolderItem] {
        guard !items.isEmpty else { return [] }
        
        if let current = currentPath.last {
            // Safely access children with validation
            let childItems = current.children.compactMap { child -> FolderItem? in
                guard child.size > 0,
                      !child.name.isEmpty,
                      !child.path.isEmpty else {
                    return nil
                }
                return child
            }
            
            if childItems.isEmpty {
                return items.compactMap { item -> FolderItem? in
                    guard item.size > 0,
                          !item.name.isEmpty,
                          !item.path.isEmpty else {
                        return nil
                    }
                    return item
                }
            }
            return childItems
        }
        
        return items.compactMap { item -> FolderItem? in
            guard item.size > 0,
                  !item.name.isEmpty,
                  !item.path.isEmpty else {
                return nil
            }
            return item
        }
    }
    
    private var currentTotalSize: Int64 {
        currentPath.last?.size ?? totalSize
    }
    
    private var hierarchyData: [RingLevel] {
        buildHierarchy()
    }
    
    private func buildHierarchy() -> [RingLevel] {
        let maxDepth = 3
        var levels: [RingLevel] = []
        
        // First ring: Current level items
        levels.append(buildRingLevel(items: currentItems, depth: 0, totalSize: currentTotalSize))
        
        // Additional rings: Show children of larger directories (safely)
        var currentLevelItems = currentItems.filter { item in
            item.isDirectory && item.size > 0 && !item.children.isEmpty
        }
        
        for depth in 1..<maxDepth {
            guard !currentLevelItems.isEmpty else { break }
            
            var nextLevelSegments: [RingSegment] = []
            
            for parentItem in currentLevelItems {
                guard parentItem.size > 0 else { continue }
                
                let parentProportion = Double(parentItem.size) / Double(currentTotalSize)
                let parentSpan = parentProportion * 360.0
                
                // Only show children if parent is significant enough
                guard parentSpan > 10.0 else { continue }
                
                let childSegments = buildChildSegments(
                    parent: parentItem,
                    parentSpan: parentSpan,
                    depth: depth,
                    totalSize: currentTotalSize
                )
                
                nextLevelSegments.append(contentsOf: childSegments)
            }
            
            if !nextLevelSegments.isEmpty {
                levels.append(RingLevel(depth: depth, segments: nextLevelSegments))
                currentLevelItems = nextLevelSegments.compactMap { segment -> FolderItem? in
                    guard segment.item.isDirectory,
                          segment.item.size > 0,
                          !segment.item.children.isEmpty else { return nil }
                    
                    let itemProportion = Double(segment.item.size) / Double(currentTotalSize) * 360.0
                    return itemProportion > 5.0 ? segment.item : nil
                }
            } else {
                break
            }
        }
        
        return levels
    }
    
    private func buildRingLevel(items: [FolderItem], depth: Int, totalSize: Int64) -> RingLevel {
        var segments: [RingSegment] = []
        var currentAngle: Double = 0
        
        guard !items.isEmpty, totalSize > 0 else {
            return RingLevel(depth: depth, segments: [])
        }
        
        // Filter out any potentially problematic items before sorting
        let validItems = items.compactMap { item -> FolderItem? in
            // Validate that the item has proper data
            guard item.size >= 0,
                  !item.name.isEmpty,
                  !item.path.isEmpty else {
                return nil
            }
            return item
        }

        guard !validItems.isEmpty else {
            return RingLevel(depth: depth, segments: [])
        }

        // CRASH FIX: Use array-based sorting to avoid stack overflow
        // Convert to array of tuples to avoid accessing potentially deallocated objects
        let itemsWithSizes = validItems.map { ($0, $0.size) }

        // Sort using the captured sizes
        let sortedPairs = itemsWithSizes.sorted { lhs, rhs in
            return lhs.1 > rhs.1  // Compare by size only
        }

        // Extract the sorted items
        let sortedItems = sortedPairs.map { $0.0 }
        
        let limitedItems = Array(sortedItems.prefix(20))
        
        for item in limitedItems {
            guard item.size > 0 else { continue }
            
            let proportion = Double(item.size) / Double(totalSize)
            let angleSpan = proportion * 360.0
            
            guard angleSpan > 0.5, angleSpan.isFinite else { continue }
            
            let segment = RingSegment(
                item: item,
                startAngle: currentAngle,
                endAngle: currentAngle + angleSpan,
                color: colorForItem(item, depth: depth),
                depth: depth
            )
            
            segments.append(segment)
            currentAngle += angleSpan
        }
        
        return RingLevel(depth: depth, segments: segments)
    }
    
    private func buildChildSegments(parent: FolderItem, parentSpan: Double, depth: Int, totalSize: Int64) -> [RingSegment] {
        var segments: [RingSegment] = []
        var currentAngle: Double = 0
        
        guard parent.size > 0, !parent.children.isEmpty else {
            return []
        }
        
        // CRASH FIX: Safer sorting with memory optimization
        let childrenWithSizes = parent.children.map { ($0, $0.size) }
        let sortedPairs = childrenWithSizes.sorted { $0.1 > $1.1 }
        let sortedChildren = Array(sortedPairs.map { $0.0 }.prefix(10))
        let parentStartAngle = findParentStartAngle(for: parent, in: hierarchyData)
        
        for child in sortedChildren {
            guard child.size > 0 else { continue }
            
            let childProportion = Double(child.size) / Double(parent.size)
            let childSpan = childProportion * parentSpan
            
            guard childSpan > 0.5 else { continue }
            
            let segment = RingSegment(
                item: child,
                startAngle: parentStartAngle + currentAngle,
                endAngle: parentStartAngle + currentAngle + childSpan,
                color: colorForItem(child, depth: depth, parentItem: parent),
                depth: depth
            )
            
            segments.append(segment)
            currentAngle += childSpan
        }
        
        return segments
    }
    
    private func findParentStartAngle(for item: FolderItem, in levels: [RingLevel]) -> Double {
        for level in levels {
            if let segment = level.segments.first(where: { $0.item.id == item.id }) {
                return segment.startAngle
            }
        }
        return 0
    }
    
    private func colorForItem(_ item: FolderItem, depth: Int, parentItem: FolderItem? = nil) -> Color {
        // Generate more subtle, Baobab-like colors
        let colorMap: [String: (hue: Double, saturation: Double)] = [
            "System": (0.0, 0.6),      // Red family
            "Users": (0.6, 0.5),       // Blue family  
            "Applications": (0.33, 0.5), // Green family
            "Library": (0.75, 0.5),    // Purple family
            "opt": (0.08, 0.6),        // Orange family
            "usr": (0.15, 0.5),        // Yellow family
            "private": (0.9, 0.4),     // Pink family
            "var": (0.5, 0.4),         // Cyan family
            "bin": (0.4, 0.4),         // Teal family
            "sbin": (0.65, 0.4),       // Light blue family
        ]
        
        let baseColor = colorMap[item.name] ?? (hue: Double(abs(item.name.hashValue)) / Double(Int.max), saturation: 0.4)
        
        // Adjust brightness and saturation based on depth
        let brightness = max(0.3, 0.8 - Double(depth) * 0.15)
        let saturation = max(0.2, baseColor.saturation - Double(depth) * 0.1)
        
        return Color(hue: baseColor.hue, saturation: saturation, brightness: brightness)
    }
    
    
    var body: some View {
        // Check if data is invalid and show appropriate content
        if items.isEmpty || totalSize <= 0 {
            Text("No data to display")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { geometry in
                let size = min(geometry.size.width, geometry.size.height)
                let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                let maxRadius = size * 0.45
                let centerHoleRadius = maxRadius * 0.2  // Create hollow center like Baobab
                
                ZStack {
                    // Background circle
                    Circle()
                        .fill(Color(NSColor.controlBackgroundColor).opacity(0.05))
                        .frame(width: size * 0.95, height: size * 0.95)
                    
                    // Render rings with proper hollow center
                    ForEach(Array(hierarchyData.enumerated()), id: \.offset) { levelIndex, level in
                        let ringThickness = (maxRadius - centerHoleRadius) / Double(max(1, hierarchyData.count))
                        let innerRadius = centerHoleRadius + Double(levelIndex) * ringThickness
                        let outerRadius = centerHoleRadius + Double(levelIndex + 1) * ringThickness
                        
                        ForEach(Array(level.segments.enumerated()), id: \.offset) { segmentIndex, segment in
                            RingSegmentView(
                                segment: segment,
                                innerRadius: innerRadius,
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
                
                    // Center hole with label
                    Circle()
                        .fill(Color(NSColor.controlBackgroundColor))
                        .frame(width: centerHoleRadius * 2, height: centerHoleRadius * 2)
                        .overlay(
                            VStack(spacing: 2) {
                                if let current = currentPath.last {
                                    Text(current.name)
                                        .font(.caption)
                                        .fontWeight(.medium)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.center)
                                    Text(formatBytes(current.size))
                                        .font(.caption2)
                                        .fontWeight(.semibold)
                                } else {
                                    Text("Computer")
                                        .font(.caption)
                                        .fontWeight(.medium)
                                    Text(formatBytes(totalSize))
                                        .font(.caption2)
                                        .fontWeight(.semibold)
                                }
                            }
                            .foregroundColor(.primary)
                            .padding(8)
                        )
                    
                    // Hover/Selection tooltip
                    if let hovered = hoveredItem ?? selectedItem {
                        TooltipView(item: hovered)
                            .offset(x: 0, y: -maxRadius * 0.7)
                    }
                    
                    // Navigation breadcrumb
                    if !currentPath.isEmpty {
                        VStack {
                            HStack {
                                Button("← Back") {
                                    navigateUp()
                                }
                                .buttonStyle(.plain)
                                .font(.caption)
                                
                                Text("/" + currentPath.map { $0.name }.joined(separator: "/"))
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
                .onTapGesture {
                    selectedItem = nil
                }
                .animation(.easeInOut(duration: 0.3), value: hierarchyData.count)
            }
        }
    }
    
    private func handleSegmentTap(_ segment: RingSegment) {
        if selectedItem?.id == segment.item.id {
            // Double-tap behavior: drill down if it's a directory
            if segment.item.isDirectory && !segment.item.children.isEmpty {
                withAnimation(.easeInOut(duration: 0.4)) {
                    currentPath.append(segment.item)
                    selectedItem = nil
                }
            }
        } else {
            selectedItem = segment.item
        }
    }
    
    private func navigateUp() {
        withAnimation(.easeInOut(duration: 0.4)) {
            if !currentPath.isEmpty {
                currentPath.removeLast()
            }
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

struct RingLevel {
    let depth: Int
    let segments: [RingSegment]
}

struct RingSegment {
    let item: FolderItem
    let startAngle: Double
    let endAngle: Double
    let color: Color
    let depth: Int
    
    var angleSpan: Double {
        endAngle - startAngle
    }
}

// MARK: - Visual Components

struct RingSegmentView: View {
    let segment: RingSegment
    let innerRadius: Double
    let outerRadius: Double
    let center: CGPoint
    let isSelected: Bool
    let isHovered: Bool
    
    var body: some View {
        Path { path in
            let startAngle = Angle(degrees: segment.startAngle - 90) // Start from top
            let endAngle = Angle(degrees: segment.endAngle - 90)
            
            // Ring segment with hollow center
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
        .fill(segment.color.opacity(fillOpacity))
        .stroke(strokeColor, lineWidth: strokeWidth)
        .scaleEffect(isSelected ? 1.02 : (isHovered ? 1.01 : 1.0))
        .animation(.easeInOut(duration: 0.15), value: isSelected)
        .animation(.easeInOut(duration: 0.1), value: isHovered)
    }
    
    private var fillOpacity: Double {
        if isSelected { return 0.9 }
        if isHovered { return 0.8 }
        return 0.7
    }
    
    private var strokeColor: Color {
        if isSelected { return .primary }
        if isHovered { return .primary.opacity(0.4) }
        return Color(NSColor.separatorColor).opacity(0.3)
    }
    
    private var strokeWidth: Double {
        if isSelected { return 1.5 }
        if isHovered { return 0.8 }
        return 0.3
    }
}

struct TooltipView: View {
    let item: FolderItem
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.name)
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            
            HStack(spacing: 12) {
                Text(formatBytes(item.size))
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
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
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

#Preview {
    RingsChart(
        items: [
            FolderItem(name: "System", path: "/System", size: 671500000000, isDirectory: true, itemCount: 3971545, lastModified: Date()),
            FolderItem(name: "Users", path: "/Users", size: 396200000000, isDirectory: true, itemCount: 2454487, lastModified: Date()),
            FolderItem(name: "opt", path: "/opt", size: 194600000000, isDirectory: true, itemCount: 174089, lastModified: Date()),
            FolderItem(name: "Applications", path: "/Applications", size: 36000000000, isDirectory: true, itemCount: 411709, lastModified: Date()),
            FolderItem(name: "usr", path: "/usr", size: 10700000000, isDirectory: true, itemCount: 269727, lastModified: Date()),
            FolderItem(name: "private", path: "/private", size: 4400000000, isDirectory: true, itemCount: 7146, lastModified: Date()),
            FolderItem(name: "Library", path: "/Library", size: 4000000000, isDirectory: true, itemCount: 98859, lastModified: Date()),
        ],
        totalSize: 1317400000000
    )
    .frame(width: 600, height: 600)
    .background(Color(NSColor.controlBackgroundColor))
}
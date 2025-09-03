import SwiftUI

struct RingsChart: View {
    let items: [FolderItem]
    let totalSize: Int64
    @State private var selectedItem: FolderItem?
    
    // Build hierarchical structure for sunburst visualization
    private var hierarchyData: [RingLevel] {
        buildHierarchy()
    }
    
    private func buildHierarchy() -> [RingLevel] {
        // For now, just create one ring level with proportional segments
        // This is a simplified version - a full implementation would parse paths to build true hierarchy
        
        var currentAngle: Double = 0
        var segments: [RingSegmentData] = []
        
        for item in items.prefix(12) { // Limit for visibility
            let proportion = Double(item.size) / Double(totalSize)
            let angleWidth = proportion * 360
            
            segments.append(RingSegmentData(
                item: item,
                startAngle: currentAngle,
                endAngle: currentAngle + angleWidth,
                parentSize: totalSize
            ))
            
            currentAngle += angleWidth
        }
        
        return [RingLevel(segments: segments)]
    }
    
    private let colors: [Color] = [
        .red, .green, .blue, .orange, .purple, .pink, .yellow, .cyan,
        .mint, .indigo, .teal, .brown, .gray, .primary, .secondary
    ]
    
    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let maxRadius = size * 0.45
            
            ZStack {
                // Background circle
                Circle()
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.1))
                    .frame(width: size * 0.9, height: size * 0.9)
                
                // Render rings from innermost (level 0) to outermost
                ForEach(Array(hierarchyData.enumerated()), id: \.offset) { levelIndex, level in
                    let innerRadius = Double(levelIndex) * (maxRadius / Double(hierarchyData.count))
                    let outerRadius = Double(levelIndex + 1) * (maxRadius / Double(hierarchyData.count))
                    
                    ForEach(Array(level.segments.enumerated()), id: \.offset) { segmentIndex, segment in
                        RingSegment(
                            segment: segment,
                            color: colors[segmentIndex % colors.count],
                            innerRadius: innerRadius,
                            outerRadius: outerRadius,
                            center: center,
                            isSelected: selectedItem?.id == segment.item.id
                        )
                        .onTapGesture {
                            selectedItem = selectedItem?.id == segment.item.id ? nil : segment.item
                        }
                    }
                }
                
                // Center label
                VStack(spacing: 2) {
                    Text(formatBytes(totalSize))
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text("Total")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                // Selection info
                if let selected = selectedItem {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selected.name)
                            .font(.headline)
                            .lineLimit(1)
                        Text(selected.formattedSize)
                            .font(.subheadline)
                        Text(String(format: "%.1f%%", selected.percentage))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(8)
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .shadow(radius: 3)
                    .offset(x: 0, y: -maxRadius * 0.8)
                }
            }
        }
        .onTapGesture {
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

// Data structures for hierarchical visualization
struct RingLevel {
    let segments: [RingSegmentData]
}

struct RingSegmentData {
    let item: FolderItem
    let startAngle: Double
    let endAngle: Double
    let parentSize: Int64
}

// Build hierarchy from flat list of items
private func buildHierarchy(from items: [FolderItem], totalSize: Int64) -> [RingLevel] {
    // For now, just create one ring level with proportional segments
    // This is a simplified version - a full implementation would parse paths to build true hierarchy
    
    var currentAngle: Double = 0
    var segments: [RingSegmentData] = []
    
    for item in items.prefix(12) { // Limit for visibility
        let proportion = Double(item.size) / Double(totalSize)
        let angleWidth = proportion * 360
        
        segments.append(RingSegmentData(
            item: item,
            startAngle: currentAngle,
            endAngle: currentAngle + angleWidth,
            parentSize: totalSize
        ))
        
        currentAngle += angleWidth
    }
    
    return [RingLevel(segments: segments)]
}

struct RingSegment: View {
    let segment: RingSegmentData
    let color: Color
    let innerRadius: Double
    let outerRadius: Double
    let center: CGPoint
    let isSelected: Bool
    
    var body: some View {
        Path { path in
            let startAngle = Angle(degrees: segment.startAngle - 90) // Adjust for top start
            let endAngle = Angle(degrees: segment.endAngle - 90)
            
            // Create arc segment
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
        .fill(color.opacity(isSelected ? 0.9 : 0.7))
        .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
        .scaleEffect(isSelected ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isSelected)
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
    .frame(width: 400, height: 400)
}
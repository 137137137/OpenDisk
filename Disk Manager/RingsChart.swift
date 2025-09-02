import SwiftUI

struct RingsChart: View {
    let items: [FolderItem]
    let totalSize: Int64
    @State private var selectedItem: FolderItem?
    
    private let colors: [Color] = [
        .red, .green, .blue, .orange, .purple, .pink, .yellow, .cyan,
        .mint, .indigo, .teal, .brown, .gray
    ]
    
    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            
            ZStack {
                // Background circle
                Circle()
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.3))
                    .frame(width: size * 0.9, height: size * 0.9)
                
                // Total size in center
                VStack(spacing: 4) {
                    Text(formatBytes(totalSize))
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Total")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                // Rings - concentric circles from largest to smallest
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if item.size > 0 {
                        RingSegment(
                            item: item,
                            color: colors[index % colors.count],
                            radius: Double(size * 0.45) - Double(index * 8), // Closer rings
                            thickness: 6, // Thinner rings for better visibility
                            totalSize: totalSize,
                            center: center
                        )
                        .onTapGesture {
                            selectedItem = item
                        }
                    }
                }
                
                // Hover info
                if let selected = selectedItem {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selected.name)
                            .font(.headline)
                        Text(selected.formattedSize)
                            .font(.subheadline)
                        Text(String(format: "%.1f%%", selected.percentage))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(8)
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .shadow(radius: 4)
                    .offset(x: 0, y: -size * 0.3)
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
        return formatter.string(fromByteCount: bytes)
    }
}

struct RingSegment: View {
    let item: FolderItem
    let color: Color
    let radius: Double
    let thickness: Double
    let totalSize: Int64
    let center: CGPoint
    
    var body: some View {
        // Create a full circle ring (concentric ring like baobab)
        Circle()
            .stroke(color.opacity(0.8), lineWidth: thickness)
            .frame(width: radius * 2, height: radius * 2)
            .position(center)
    }
}

#Preview {
    RingsChart(
        items: [
            FolderItem(name: "Documents", path: "/Users/test/Documents", size: 1000000000, isDirectory: true, itemCount: 100, lastModified: Date()),
            FolderItem(name: "Pictures", path: "/Users/test/Pictures", size: 500000000, isDirectory: true, itemCount: 50, lastModified: Date()),
            FolderItem(name: "Downloads", path: "/Users/test/Downloads", size: 300000000, isDirectory: true, itemCount: 30, lastModified: Date())
        ],
        totalSize: 1800000000
    )
    .frame(width: 400, height: 400)
}

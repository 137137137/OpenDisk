import SwiftUI

/// Baobab-style chart tooltip: dark pill following the pointer with the
/// hovered item's name, size and share.
struct ChartHoverTip: View {
    let name: String
    let size: Int64
    let fractionOfRoot: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.caption)
                .fontWeight(.semibold)
                .lineLimit(1)
            Text("\(ByteFormatter.formatFileSize(size)) · \(fractionOfRoot * 100, specifier: "%.1f")%")
                .font(.caption2)
                .monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .allowsHitTesting(false)
    }
}

/// Positions a hover tip near the pointer, kept inside the container.
struct ChartHoverTipOverlay: View {
    let name: String
    let size: Int64
    let fractionOfRoot: Double
    let location: CGPoint
    let bounds: CGSize

    var body: some View {
        ChartHoverTip(name: name, size: size, fractionOfRoot: fractionOfRoot)
            .fixedSize()
            .alignmentGuide(.leading) { _ in 0 }
            .position(
                x: min(max(location.x + 14, 60), bounds.width - 60),
                y: max(location.y - 24, 20)
            )
    }
}

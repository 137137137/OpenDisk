import CoreGraphics
import Foundation

/// Pure geometry for the rings chart (baobab-style sunburst): concentric
/// rings, one per depth level, each item an annular sector whose sweep is
/// proportional to its share of the whole.
///
/// Angles are in radians, measured with `atan2(dy, dx)` semantics in a
/// y-down coordinate space: 0 points east and angles grow toward the
/// visually clockwise direction. Drawing and hit-testing share this
/// convention.
enum RingsChartLayout {

    /// Sectors sweeping less than this are not drawn (≈1.7°).
    static let itemMinAngle = 0.03
    /// Stroke marking items whose children were cut off by the depth limit.
    static let continuedEdgeWidth: CGFloat = 3
    static let continuedEdgeGap: CGFloat = 4
    static let borderWidth: CGFloat = 1
    static let padding: CGFloat = 10

    struct Segment: Equatable {
        let path: String
        let name: String
        let size: Int64
        let isDirectory: Bool
        let depth: Int
        let fractionOfRoot: Double
        let hasHiddenChildren: Bool
        /// Radians; see the coordinate convention above.
        let startAngle: Double
        let sweep: Double
        let innerRadius: CGFloat
        let outerRadius: CGFloat
        /// 0..200 input to `ChartPalette.fill`.
        let colorPosition: Double
    }

    struct Layout: Equatable {
        let center: CGPoint
        let ringThickness: CGFloat
        /// Root first, then outer rings in traversal order.
        let segments: [Segment]

        /// The segment under `point`, or nil over empty space.
        func segment(at point: CGPoint) -> Segment? {
            let dx = point.x - center.x
            let dy = point.y - center.y
            let radius = (dx * dx + dy * dy).squareRoot()
            guard let root = segments.first else { return nil }
            if radius <= root.outerRadius { return root }
            var angle = atan2(dy, dx)
            if angle < 0 { angle += 2 * .pi }
            return segments.first { segment in
                segment.depth > 0
                    && radius > segment.innerRadius && radius <= segment.outerRadius
                    && angle >= segment.startAngle
                    && angle < segment.startAngle + segment.sweep
            }
        }
    }

    static func layout(root: ChartItem, in size: CGSize) -> Layout {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let maxRadius = max(min(size.width, size.height) / 2 - padding, 1)
        let thickness = maxRadius / CGFloat(ChartItem.maxDepth + 1)

        var segments: [Segment] = []
        appendSegments(
            of: root, startAngle: 0, sweep: 2 * .pi,
            thickness: thickness, into: &segments
        )
        return Layout(center: center, ringThickness: thickness, segments: segments)
    }

    private static func appendSegments(
        of item: ChartItem,
        startAngle: Double,
        sweep: Double,
        thickness: CGFloat,
        into segments: inout [Segment]
    ) {
        guard item.depth == 0 || sweep >= itemMinAngle else { return }

        let innerRadius = CGFloat(item.depth) * thickness
        segments.append(Segment(
            path: item.path, name: item.name, size: item.size,
            isDirectory: item.isDirectory, depth: item.depth,
            fractionOfRoot: item.fractionOfRoot,
            hasHiddenChildren: item.hasHiddenChildren,
            startAngle: startAngle, sweep: sweep,
            innerRadius: innerRadius, outerRadius: innerRadius + thickness,
            colorPosition: (startAngle + sweep / 2) / (2 * .pi) * 200
        ))

        for child in item.children {
            appendSegments(
                of: child,
                startAngle: startAngle + sweep * child.relStart / 100,
                sweep: sweep * child.relSize / 100,
                thickness: thickness,
                into: &segments
            )
        }
    }
}

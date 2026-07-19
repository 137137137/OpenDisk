import SwiftUI

/// Baobab-style rings chart (sunburst): the viewed directory as a center
/// disk, each depth level a concentric ring, sector sweep proportional to
/// size. Redraws live as scan snapshots stream in.
///
/// Everything — including the hover tip — is drawn inside one `Canvas`,
/// so hover state changes can only trigger repaints, never re-layout.
struct RingsChartView: View {
    let root: ChartItem
    /// Called with a directory segment's path when it is clicked.
    let onSelectDirectory: (String) -> Void
    /// Called when the center (the viewed directory itself) is clicked.
    let onSelectCenter: () -> Void

    @State private var hoveredPath: String?
    @State private var hoverLocation: CGPoint = .zero

    var body: some View {
        GeometryReader { geometry in
            let layout = RingsChartLayout.layout(root: root, in: geometry.size)
            Canvas { context, size in
                draw(layout: layout, in: &context)
                if let hoveredPath,
                   let segment = layout.segments.first(where: { $0.path == hoveredPath }) {
                    ChartTipRenderer.draw(
                        name: segment.name, size: segment.size,
                        fractionOfRoot: segment.fractionOfRoot,
                        near: hoverLocation, in: &context, bounds: size
                    )
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoverLocation = location
                    hoveredPath = layout.segment(at: location)?.path
                case .ended:
                    hoveredPath = nil
                }
            }
            .onTapGesture { location in
                guard let segment = layout.segment(at: location) else { return }
                if segment.depth == 0 {
                    onSelectCenter()
                } else if segment.isDirectory {
                    onSelectDirectory(segment.path)
                }
            }
        }
    }

    // MARK: - Drawing

    private func draw(layout: RingsChartLayout.Layout, in context: inout GraphicsContext) {
        let border = GraphicsContext.Shading.color(.black.opacity(0.35))

        for segment in layout.segments {
            let highlighted = segment.path == hoveredPath
            let fill = ChartPalette.fill(
                position: segment.colorPosition,
                depth: segment.depth,
                highlighted: highlighted
            ).color

            if segment.depth == 0 {
                let disk = Path(ellipseIn: CGRect(
                    x: layout.center.x - segment.outerRadius,
                    y: layout.center.y - segment.outerRadius,
                    width: segment.outerRadius * 2,
                    height: segment.outerRadius * 2
                ))
                context.fill(disk, with: .color(fill))
                context.stroke(disk, with: border, lineWidth: RingsChartLayout.borderWidth)
                drawCenterLabel(for: segment, layout: layout, in: &context)
                continue
            }

            let sector = sectorPath(for: segment, center: layout.center)
            context.fill(sector, with: .color(fill))
            context.stroke(sector, with: border, lineWidth: RingsChartLayout.borderWidth)
            drawSectorLabel(for: segment, layout: layout, in: &context)

            if segment.hasHiddenChildren {
                // Baobab marks depth-limited directories with a short edge
                // just outside the sector: "there is more in here".
                var edge = Path()
                edge.addArc(
                    center: layout.center,
                    radius: segment.outerRadius + RingsChartLayout.continuedEdgeGap,
                    startAngle: .radians(segment.startAngle),
                    endAngle: .radians(segment.startAngle + segment.sweep),
                    clockwise: false
                )
                context.stroke(
                    edge, with: .color(fill),
                    lineWidth: RingsChartLayout.continuedEdgeWidth
                )
            }
        }
    }

    private func sectorPath(for segment: RingsChartLayout.Segment, center: CGPoint) -> Path {
        var path = Path()
        let a0 = segment.startAngle
        let a1 = segment.startAngle + segment.sweep
        path.move(to: CGPoint(
            x: center.x + cos(a0) * segment.innerRadius,
            y: center.y + sin(a0) * segment.innerRadius
        ))
        path.addArc(
            center: center, radius: segment.outerRadius,
            startAngle: .radians(a0), endAngle: .radians(a1), clockwise: false
        )
        path.addLine(to: CGPoint(
            x: center.x + cos(a1) * segment.innerRadius,
            y: center.y + sin(a1) * segment.innerRadius
        ))
        path.addArc(
            center: center, radius: segment.innerRadius,
            startAngle: .radians(a1), endAngle: .radians(a0), clockwise: true
        )
        path.closeSubpath()
        return path
    }

    /// Names the larger sectors with text curved along the ring, glyph by
    /// glyph at the sector's mid-radius — so a label uses the space the
    /// arc actually offers instead of spilling straight across ring
    /// boundaries. Drawn only when the whole name fits along the arc and
    /// within the ring's thickness.
    private func drawSectorLabel(
        for segment: RingsChartLayout.Segment,
        layout: RingsChartLayout.Layout,
        in context: inout GraphicsContext
    ) {
        let midRadius = (segment.innerRadius + segment.outerRadius) / 2
        let thickness = segment.outerRadius - segment.innerRadius
        let arcLength = CGFloat(segment.sweep) * midRadius
        guard thickness >= 12, arcLength >= 30 else { return }

        let unbounded = CGSize(width: CGFloat.greatestFiniteMagnitude, height: 40)
        let glyphs = segment.name.map { character in
            context.resolve(
                Text(String(character)).font(.caption2)
                    .foregroundStyle(.black.opacity(0.75))
            )
        }
        let glyphWidths = glyphs.map { $0.measure(in: unbounded).width }
        let totalWidth = glyphWidths.reduce(0, +)
        let lineHeight = glyphs.first?.measure(in: unbounded).height ?? 12
        guard totalWidth <= arcLength * 0.85, lineHeight <= thickness * 0.85 else { return }

        // In the lower half of the circle, glyphs run along decreasing
        // angle with flipped rotation so the text never reads upside down
        // (arch on top, bowl on the bottom).
        let bisector = segment.startAngle + segment.sweep / 2
        let readsReversed = sin(bisector) > 0
        let totalAngle = Double(totalWidth / midRadius)
        var cursor = readsReversed ? bisector + totalAngle / 2 : bisector - totalAngle / 2

        for (index, glyph) in glyphs.enumerated() {
            let glyphAngle = Double(glyphWidths[index] / midRadius)
            let angle = readsReversed ? cursor - glyphAngle / 2 : cursor + glyphAngle / 2
            var glyphContext = context
            glyphContext.translateBy(
                x: layout.center.x + cos(angle) * midRadius,
                y: layout.center.y + sin(angle) * midRadius
            )
            glyphContext.rotate(by: .radians(readsReversed ? angle - .pi / 2 : angle + .pi / 2))
            glyphContext.draw(glyph, at: .zero)
            cursor += readsReversed ? -glyphAngle : glyphAngle
        }
    }

    private func drawCenterLabel(
        for segment: RingsChartLayout.Segment,
        layout: RingsChartLayout.Layout,
        in context: inout GraphicsContext
    ) {
        let name = context.resolve(
            Text(segment.name).font(.caption).fontWeight(.semibold)
                .foregroundStyle(.black.opacity(0.75))
        )
        let size = context.resolve(
            Text(ByteFormatter.formatFileSize(segment.size)).font(.caption2)
                .foregroundStyle(.black.opacity(0.6))
        )
        let maxWidth = segment.outerRadius * 1.7
        let nameSize = name.measure(in: CGSize(width: maxWidth, height: 40))
        let sizeSize = size.measure(in: CGSize(width: maxWidth, height: 40))
        guard nameSize.width <= maxWidth else {
            // Tight center: show the size only.
            context.draw(size, at: layout.center)
            return
        }
        context.draw(name, at: CGPoint(x: layout.center.x, y: layout.center.y - sizeSize.height / 2 - 1))
        context.draw(size, at: CGPoint(x: layout.center.x, y: layout.center.y + nameSize.height / 2 + 1))
    }
}

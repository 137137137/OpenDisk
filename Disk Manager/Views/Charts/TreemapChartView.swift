import SwiftUI

/// Baobab-style treemap: nested slice-and-dice blocks, alternating split
/// axis per depth, block area proportional to size. Redraws live as scan
/// snapshots stream in.
struct TreemapChartView: View {
    let root: ChartItem
    /// Called with a directory block's path when it is clicked.
    let onSelectDirectory: (String) -> Void

    @State private var hoveredPath: String?
    @State private var hoverLocation: CGPoint = .zero

    var body: some View {
        GeometryReader { geometry in
            let layout = TreemapChartLayout.layout(
                root: root, in: CGRect(origin: .zero, size: geometry.size)
            )
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    draw(layout: layout, in: &context)
                }
                if let hoveredPath,
                   let block = layout.blocks.last(where: { $0.path == hoveredPath }) {
                    ChartHoverTipOverlay(
                        name: block.name, size: block.size,
                        fractionOfRoot: block.fractionOfRoot,
                        location: hoverLocation, bounds: geometry.size
                    )
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoverLocation = location
                    hoveredPath = layout.block(at: location)?.path
                case .ended:
                    hoveredPath = nil
                }
            }
            .onTapGesture { location in
                guard let block = layout.block(at: location), block.isDirectory,
                      block.depth > 0 else { return }
                onSelectDirectory(block.path)
            }
        }
    }

    // MARK: - Drawing

    private func draw(layout: TreemapChartLayout.Layout, in context: inout GraphicsContext) {
        let border = GraphicsContext.Shading.color(.black.opacity(0.35))

        for block in layout.blocks {
            let highlighted = block.path == hoveredPath
            let fill = ChartPalette.fill(
                position: block.colorPosition,
                depth: block.depth,
                highlighted: highlighted
            ).color

            let shape = Path(block.rect)
            context.fill(shape, with: .color(fill))
            context.stroke(shape, with: border, lineWidth: TreemapChartLayout.borderWidth)

            if block.isLeafBlock {
                drawLabel(for: block, in: &context)
            }
        }
    }

    /// Leaf blocks carry a centered label when it fits (name, and the size
    /// beneath it when there is room for both).
    private func drawLabel(for block: TreemapChartLayout.Block, in context: inout GraphicsContext) {
        let inset = TreemapChartLayout.textPadding * 2
        let available = CGSize(
            width: block.rect.width - inset,
            height: block.rect.height - inset
        )
        guard available.width >= 20, available.height >= 12 else { return }

        let name = context.resolve(
            Text(block.name).font(.caption2)
                .foregroundStyle(.black.opacity(0.75))
        )
        let nameSize = name.measure(in: available)
        guard nameSize.width <= available.width, nameSize.height <= available.height else {
            return
        }

        let size = context.resolve(
            Text(ByteFormatter.formatFileSize(block.size)).font(.caption2)
                .foregroundStyle(.black.opacity(0.55))
        )
        let sizeSize = size.measure(in: available)
        let center = CGPoint(x: block.rect.midX, y: block.rect.midY)

        if sizeSize.width <= available.width,
           nameSize.height + sizeSize.height <= available.height {
            context.draw(name, at: CGPoint(x: center.x, y: center.y - sizeSize.height / 2))
            context.draw(size, at: CGPoint(x: center.x, y: center.y + nameSize.height / 2))
        } else {
            context.draw(name, at: center)
        }
    }
}

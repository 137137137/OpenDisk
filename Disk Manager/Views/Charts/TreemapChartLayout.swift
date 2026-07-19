import CoreGraphics
import Foundation

/// Pure geometry for the treemap (baobab-style): slice-and-dice nesting
/// that alternates split axis per depth — odd depths divide the width,
/// even depths the height — with fixed padding so nesting stays legible.
enum TreemapChartLayout {

    static let itemPadding: CGFloat = 6
    static let borderWidth: CGFloat = 1
    static let textPadding: CGFloat = 3
    /// Blocks smaller than this (after padding) are not drawn.
    static let minDimension: CGFloat = 3

    struct Block: Equatable {
        let path: String
        let name: String
        let size: Int64
        let isDirectory: Bool
        let depth: Int
        let fractionOfRoot: Double
        let rect: CGRect
        /// True when none of the item's children were drawn, so the block's
        /// interior is free for a label.
        let isLeafBlock: Bool
        /// 0..200 input to `ChartPalette.fill`.
        let colorPosition: Double
    }

    struct Layout: Equatable {
        let bounds: CGRect
        /// Parents precede their children.
        let blocks: [Block]

        /// The deepest block under `point`.
        func block(at point: CGPoint) -> Block? {
            blocks.last { $0.rect.contains(point) }
        }
    }

    static func layout(root: ChartItem, in bounds: CGRect) -> Layout {
        var blocks: [Block] = []
        appendBlocks(of: root, slice: bounds, canvas: bounds, into: &blocks)
        return Layout(bounds: bounds, blocks: blocks)
    }

    private static func appendBlocks(
        of item: ChartItem,
        slice: CGRect,
        canvas: CGRect,
        into blocks: inout [Block]
    ) {
        // Blocks sit inside their slice with half the padding per side, so
        // adjacent siblings end up a full padding apart.
        let rect = slice.insetBy(dx: itemPadding / 2, dy: itemPadding / 2)
        guard rect.width >= minDimension, rect.height >= minDimension else { return }

        // Children of odd-depth items split the height; children of
        // even-depth items (including the root) split the width.
        let childrenSplitWidth = item.depth.isMultiple(of: 2)
        let blockIndex = blocks.count
        var drewChild = false

        // Placeholder appended first so parents precede children; patched
        // below once we know whether any child was drawn.
        blocks.append(Block(
            path: item.path, name: item.name, size: item.size,
            isDirectory: item.isDirectory, depth: item.depth,
            fractionOfRoot: item.fractionOfRoot, rect: rect,
            isLeafBlock: true,
            colorPosition: colorPosition(for: rect, depth: item.depth, canvas: canvas)
        ))

        for child in item.children {
            let childSlice: CGRect
            if childrenSplitWidth {
                childSlice = CGRect(
                    x: rect.minX + rect.width * child.relStart / 100,
                    y: rect.minY,
                    width: rect.width * child.relSize / 100,
                    height: rect.height
                )
            } else {
                childSlice = CGRect(
                    x: rect.minX,
                    y: rect.minY + rect.height * child.relStart / 100,
                    width: rect.width,
                    height: rect.height * child.relSize / 100
                )
            }
            let before = blocks.count
            appendBlocks(of: child, slice: childSlice, canvas: canvas, into: &blocks)
            drewChild = drewChild || blocks.count > before
        }

        if drewChild {
            let placeholder = blocks[blockIndex]
            blocks[blockIndex] = Block(
                path: placeholder.path, name: placeholder.name,
                size: placeholder.size, isDirectory: placeholder.isDirectory,
                depth: placeholder.depth,
                fractionOfRoot: placeholder.fractionOfRoot,
                rect: placeholder.rect, isLeafBlock: false,
                colorPosition: placeholder.colorPosition
            )
        }
    }

    /// Baobab keys the hue on the block's position along the split axis.
    private static func colorPosition(
        for rect: CGRect, depth: Int, canvas: CGRect
    ) -> Double {
        guard canvas.width > 0, canvas.height > 0 else { return 0 }
        if depth.isMultiple(of: 2) {
            return (rect.midY - canvas.minY) / canvas.height * 200
        } else {
            return (rect.midX - canvas.minX) / canvas.width * 200
        }
    }
}

import Foundation

/// One node of the chart model shared by the rings and treemap views: a
/// depth-limited, noise-filtered slice of a scan's `FileTree`.
///
/// Geometry-independent: `relStart`/`relSize` are percentages within the
/// parent, which the rings chart maps to angles and the treemap maps to
/// lengths. The design (depth limit, thresholds, proportional layout)
/// follows GNOME baobab's charts; the implementation is original Swift.
struct ChartItem: Equatable, Identifiable, Sendable {
    /// Paths are stable across successive live snapshots, so hover state
    /// and SwiftUI diffing can track an item while its size streams in.
    var id: String { path }

    let name: String
    let path: String
    let size: Int64
    /// 0 is the chart root (the center disk / whole canvas).
    let depth: Int
    /// Offset within the parent, 0..100 (percent).
    let relStart: Double
    /// Share of the parent, 0..100 (percent).
    let relSize: Double
    /// Share of the whole chart, 0..1.
    let fractionOfRoot: Double
    let isDirectory: Bool
    /// True when children exist but `maxDepth` cut them off; the rings
    /// chart marks such items with an outer "continues" edge.
    let hasHiddenChildren: Bool
    let children: [ChartItem]

    /// Levels shown below the root, matching baobab's MAX_DEPTH.
    static let maxDepth = 5
    /// Items below this share of the whole chart are dropped at build
    /// time — slightly finer than either view's own drawing threshold
    /// (rings: 0.03 rad ≈ 0.48% of the circle; treemap: 3 px).
    static let minVisibleFraction = 0.0015

    /// Builds the chart tree for the directory `node` of `tree`.
    static func build(
        from tree: FileTree,
        at node: FileTree.NodeID,
        name: String,
        path: String
    ) -> ChartItem {
        buildItem(
            tree: tree, node: node, name: name, path: path,
            depth: 0, relStart: 0, relSize: 100, fractionOfRoot: 1
        )
    }

    private static func buildItem(
        tree: FileTree,
        node: FileTree.NodeID,
        name: String,
        path: String,
        depth: Int,
        relStart: Double,
        relSize: Double,
        fractionOfRoot: Double
    ) -> ChartItem {
        let isDirectory = tree.isDirectory(node)
        let hasChildren = isDirectory && tree.childCount(of: node) > 0
        var children: [ChartItem] = []

        if hasChildren && depth < maxDepth {
            let parentSize = max(tree.size(of: node), 1)
            let prefix = path.hasSuffix("/") ? path : path + "/"
            // Largest first (name as a deterministic tiebreak); matches
            // the list view and keeps successive live snapshots stable.
            let ordered = tree.children(of: node).sorted {
                let (a, b) = (tree.size(of: $0), tree.size(of: $1))
                return a == b ? tree.name(of: $0) < tree.name(of: $1) : a > b
            }
            var cursor = 0.0
            for child in ordered {
                let childSize = tree.size(of: child)
                guard childSize > 0 else { break }
                let share = Double(childSize) / Double(parentSize) * 100
                let childFraction = fractionOfRoot * share / 100
                // Ordered by size, so everything after the first
                // too-small child is also too small.
                guard childFraction >= minVisibleFraction else { break }
                let childName = tree.name(of: child)
                children.append(buildItem(
                    tree: tree, node: child, name: childName,
                    path: prefix + childName,
                    depth: depth + 1, relStart: cursor, relSize: share,
                    fractionOfRoot: childFraction
                ))
                cursor += share
            }
        }

        return ChartItem(
            name: name, path: path, size: tree.size(of: node),
            depth: depth, relStart: relStart, relSize: relSize,
            fractionOfRoot: fractionOfRoot,
            isDirectory: isDirectory,
            hasHiddenChildren: hasChildren && depth >= maxDepth,
            children: children
        )
    }
}

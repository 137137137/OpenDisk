import Foundation

/// One node of the rings chart's model: a depth-limited, noise-filtered
/// slice of a scan's `FileTree`.
///
/// Geometry-independent: `relStart`/`relSize` are percentages within the
/// parent, which the rings chart maps to angles. The design (depth limit,
/// thresholds, proportional layout) follows GNOME baobab's chart; the
/// implementation is original Swift.
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
    /// Synthetic "hidden space" slice (purgeable pool, snapshots, unread
    /// directories) rather than a real filesystem item; drawn gray and
    /// not navigable.
    var isHiddenSpace: Bool = false
    let children: [ChartItem]

    /// Sentinel path for the synthetic hidden-space slice.
    static let hiddenSpacePath = "::hidden-space"

    /// Levels shown below the root, matching baobab's MAX_DEPTH.
    static let maxDepth = 5
    /// Items below this share of the whole chart are dropped at build
    /// time — slightly finer than either view's own drawing threshold
    /// (the rings chart hides sweeps under 0.03 rad ≈ 0.48% of the circle).
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

    /// A copy of this root with a synthetic "hidden space" slice appended
    /// after the real children, which keep their proportions relative to
    /// the enlarged total.
    func appendingHiddenSpace(bytes: Int64) -> ChartItem {
        guard depth == 0, bytes > 0 else { return self }
        let newTotal = size + bytes
        guard newTotal > 0 else { return self }

        let factor = Double(size) / Double(newTotal)
        let hiddenShare = Double(bytes) / Double(newTotal) * 100
        var newChildren = children.map { $0.scaled(by: factor, rescaleShares: true) }
        newChildren.append(ChartItem(
            name: "hidden space", path: Self.hiddenSpacePath, size: bytes,
            depth: 1, relStart: 100 - hiddenShare, relSize: hiddenShare,
            fractionOfRoot: hiddenShare / 100,
            isDirectory: false, hasHiddenChildren: false,
            isHiddenSpace: true, children: []
        ))
        return ChartItem(
            name: name, path: path, size: newTotal,
            depth: 0, relStart: 0, relSize: 100, fractionOfRoot: 1,
            isDirectory: isDirectory, hasHiddenChildren: hasHiddenChildren,
            children: newChildren
        )
    }

    /// Scales `fractionOfRoot` through the subtree; only the top level
    /// also rescales its share of the (enlarged) parent.
    private func scaled(by factor: Double, rescaleShares: Bool) -> ChartItem {
        ChartItem(
            name: name, path: path, size: size, depth: depth,
            relStart: rescaleShares ? relStart * factor : relStart,
            relSize: rescaleShares ? relSize * factor : relSize,
            fractionOfRoot: fractionOfRoot * factor,
            isDirectory: isDirectory, hasHiddenChildren: hasHiddenChildren,
            isHiddenSpace: isHiddenSpace,
            children: children.map { $0.scaled(by: factor, rescaleShares: false) }
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

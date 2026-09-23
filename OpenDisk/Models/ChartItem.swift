import Foundation

struct ChartItem: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        case file
        case directory
        case synthetic
    }

    var id: String { path }

    let name: String
    let path: String
    let size: Int64
    let depth: Int
    let relStart: Double
    let relSize: Double
    let fractionOfRoot: Double
    let kind: Kind
    let hasHiddenChildren: Bool
    let children: [ChartItem]

    static let maxDepth = 5
    static let minVisibleFraction = 0.0015

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
        let totalSize = tree.size(of: node)
        let parentSize = max(totalSize, 1)
        let hasChildren = isDirectory && tree.childCount(of: node) > 0
        var children: [ChartItem] = []
        var cursor = 0.0

        if hasChildren && depth < maxDepth {
            let prefix = path.directoryPrefix
            for child in tree.childrenSortedForDisplay(of: node) {
                let childSize = tree.size(of: child)
                guard childSize > 0 else { break }
                let share = Double(childSize) / Double(parentSize) * 100
                let childFraction = fractionOfRoot * share / 100
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
            name: name, path: path, size: totalSize,
            depth: depth, relStart: relStart, relSize: relSize,
            fractionOfRoot: fractionOfRoot,
            kind: isDirectory ? .directory : .file,
            hasHiddenChildren: hasChildren && depth >= maxDepth,
            children: children
        )
    }
}

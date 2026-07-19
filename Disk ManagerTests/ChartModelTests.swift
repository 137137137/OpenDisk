import CoreGraphics
import Foundation
import Testing
@testable import Disk_Manager

@Suite("Chart model and layouts")
struct ChartModelTests {

    /// root(1000) ├─ big(600: a 400, b 200) ├─ small(300) └─ file(100)
    private func makeTree() -> FileTree {
        var tree = FileTree(rootName: "/Volumes/T")
        let big = tree.addNode(name: "big", parent: FileTree.rootID, size: 0, isDirectory: true)
        tree.addNode(name: "a.bin", parent: big, size: 400, isDirectory: false)
        tree.addNode(name: "b.bin", parent: big, size: 200, isDirectory: false)
        let small = tree.addNode(name: "small", parent: FileTree.rootID, size: 0, isDirectory: true)
        tree.addNode(name: "c.bin", parent: small, size: 300, isDirectory: false)
        tree.addNode(name: "file.dat", parent: FileTree.rootID, size: 100, isDirectory: false)
        tree.rollUpDirectorySizes()
        return tree
    }

    @Test("builds proportional rel sizes, largest first")
    func chartTreeProportions() {
        let tree = makeTree()
        let root = ChartItem.build(
            from: tree, at: FileTree.rootID, name: "/Volumes/T", path: "/Volumes/T"
        )

        #expect(root.size == 1_000)
        #expect(root.children.map(\.name) == ["big", "small", "file.dat"])
        let big = root.children[0]
        #expect(abs(big.relSize - 60) < 0.001)
        #expect(abs(big.relStart - 0) < 0.001)
        let small = root.children[1]
        #expect(abs(small.relSize - 30) < 0.001)
        #expect(abs(small.relStart - 60) < 0.001)
        #expect(big.children.map(\.name) == ["a.bin", "b.bin"])
        #expect(abs(big.children[0].relSize - (400.0 / 600.0 * 100)) < 0.001)
        #expect(abs(big.children[0].fractionOfRoot - 0.4) < 0.001)
        #expect(big.children[0].path == "/Volumes/T/big/a.bin")
    }

    @Test("drops items below the minimum visible fraction")
    func chartTreeDropsNoise() {
        var tree = FileTree(rootName: "/r")
        tree.addNode(name: "huge.bin", parent: FileTree.rootID, size: 1_000_000, isDirectory: false)
        tree.addNode(name: "dust.bin", parent: FileTree.rootID, size: 100, isDirectory: false)
        tree.rollUpDirectorySizes()

        let root = ChartItem.build(from: tree, at: FileTree.rootID, name: "/r", path: "/r")
        #expect(root.children.map(\.name) == ["huge.bin"])
    }

    @Test("rings layout: angles proportional and nested within parents")
    func ringsGeometry() {
        let tree = makeTree()
        let root = ChartItem.build(
            from: tree, at: FileTree.rootID, name: "/Volumes/T", path: "/Volumes/T"
        )
        let layout = RingsChartLayout.layout(root: root, in: CGSize(width: 400, height: 400))

        let rootSegment = layout.segments[0]
        #expect(rootSegment.depth == 0)
        #expect(abs(rootSegment.sweep - 2 * .pi) < 0.001)

        let big = layout.segments.first { $0.name == "big" }
        #expect(big != nil)
        if let big {
            #expect(abs(big.sweep - 0.6 * 2 * .pi) < 0.001)
            #expect(big.innerRadius == layout.ringThickness)
            // Children stay inside the parent's angular span, one ring out.
            let a = layout.segments.first { $0.name == "a.bin" }
            #expect(a != nil)
            if let a {
                #expect(a.startAngle >= big.startAngle - 0.001)
                #expect(a.startAngle + a.sweep <= big.startAngle + big.sweep + 0.001)
                #expect(a.innerRadius == big.outerRadius)
            }
        }

        // Hit-testing: the center resolves to the root, a point in the
        // first ring at big's mid-angle resolves to big.
        #expect(layout.segment(at: layout.center)?.depth == 0)
        if let big {
            let angle = big.startAngle + big.sweep / 2
            let radius = (big.innerRadius + big.outerRadius) / 2
            let point = CGPoint(
                x: layout.center.x + cos(angle) * radius,
                y: layout.center.y + sin(angle) * radius
            )
            #expect(layout.segment(at: point)?.name == "big")
        }
    }

    @Test("palette: depth dims, highlight restores full brightness")
    func paletteBehavior() {
        let base = ChartPalette.fill(position: 50, depth: 1, highlighted: false)
        let deep = ChartPalette.fill(position: 50, depth: 5, highlighted: false)
        #expect(deep.red < base.red || deep.green < base.green || deep.blue < base.blue)

        let highlighted = ChartPalette.fill(position: 50, depth: 5, highlighted: true)
        #expect(max(highlighted.red, max(highlighted.green, highlighted.blue)) > 0.999)

        let root = ChartPalette.fill(position: 0, depth: 0, highlighted: false)
        #expect(root == ChartPalette.level)
    }
}

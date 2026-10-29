import CoreGraphics
import Testing
@testable import OpenDisk

@Suite("File list columns")
struct FileListColumnTests {
    private let scale = ListScale(level: ListScale.defaultLevel)

    @Test("stored selection round-trips in display order")
    func roundTrip() {
        let stored = FileListColumnSelection(columns: [.permissions, .kind, .modified]).storedValue
        #expect(FileListColumnSelection(storedValue: stored).columns == [.kind, .modified, .permissions])
    }

    @Test("unknown and empty stored values are ignored")
    func decodeIgnoresGarbage() {
        #expect(FileListColumnSelection(storedValue: "").columns.isEmpty)
        #expect(FileListColumnSelection(storedValue: "bogus,created,,").columns == [.created])
    }

    @Test("default selection shows kind and modified")
    func defaultSelection() {
        let selection = FileListColumnSelection(storedValue: FileListColumnSelection.defaultStoredValue)
        #expect(selection.columns == [.kind, .modified])
    }

    @Test("toggling a column keeps the display order")
    func toggling() {
        let selection = FileListColumnSelection(columns: [.modified])
            .setting(.kind, visible: true)
            .setting(.lastOpened, visible: true)
            .setting(.modified, visible: false)
        #expect(selection.columns == [.kind, .lastOpened])
        #expect(selection.setting(.kind, visible: true) == selection)
    }

    /// Width of Kind in a list of plain folders and documents.
    private let kindWidth: CGFloat = 70

    private func columnsThatFit(_ columns: [FileListColumn], in width: CGFloat) -> [FileListColumn] {
        FileListLayout.columnsThatFit(columns, in: width, scale: scale, kindWidth: kindWidth)
    }

    @Test("all columns fit in a wide list")
    func wideList() {
        let all = FileListColumn.allCases
        #expect(columnsThatFit(all, in: 2_000) == all)
    }

    @Test("no columns fit in the narrowest list")
    func narrowList() {
        #expect(columnsThatFit(FileListColumn.allCases, in: 340).isEmpty)
    }

    @Test("kind takes its measured width")
    func kindUsesMeasuredWidth() {
        let widthForKind: CGFloat = 340 + kindWidth + FileColumns.spacing
        #expect(columnsThatFit([.kind], in: widthForKind) == [.kind])
        #expect(columnsThatFit([.kind], in: widthForKind - 1).isEmpty)
        #expect(FileListColumn.kind.width(scale: scale, kindWidth: kindWidth) == kindWidth)
        #expect(FileListColumn.kind.width(scale: scale, kindWidth: nil) == FileColumns.kind)
    }

    @Test("trailing columns are dropped first")
    func partialFit() {
        let columns: [FileListColumn] = [.kind, .modified, .permissions]
        let modifiedWidth = FileListColumn.modified.width(scale: scale, kindWidth: nil)
        let widthForTwo: CGFloat = 340 + kindWidth + modifiedWidth + FileColumns.spacing * 2
        #expect(columnsThatFit(columns, in: widthForTwo) == [.kind, .modified])
    }

    @Test("bigger text needs more room for the same columns")
    func scaledFit() {
        let largest = ListScale(level: ListScale.fontSizes.count - 1)
        let widthAtDefaultSize: CGFloat = 340 + kindWidth + FileColumns.spacing
        #expect(FileListLayout.columnsThatFit([.kind], in: widthAtDefaultSize, scale: largest, kindWidth: kindWidth).isEmpty)
    }
}

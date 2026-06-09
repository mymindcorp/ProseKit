import Foundation
import DocumentModel
import SchemaKit
import TestHarness

// Ported from prosemirror-tables/test/tablespanMap.test.ts.

private func mapStr(_ t: TaggedNode) -> String { TableMap.get(t.node).map.map(String.init).joined(separator: ", ") }
private let spanMap = TableMap.get(table(tr(cell(2, 3), c11(), cell(1, 2)), tr(c11()), tr(cell(2, 1))).node)

func registerPMTableMapTests() {
    test("PM TableMap: simple table shape") {
        let t = table(tr(c11(), c11(), c11()), tr(c11(), c11(), c11()), tr(c11(), c11(), c11()), tr(c11(), c11(), c11()))
        try expectEqual(mapStr(t), "1, 6, 11, 18, 23, 28, 35, 40, 45, 52, 57, 62")
    }
    test("PM TableMap: colspans") {
        let t = table(tr(c11(), cell(2, 1)), tr(cell(2, 1), c11()), tr(c11(), c11(), c11()))
        try expectEqual(mapStr(t), "1, 6, 6, 13, 13, 18, 25, 30, 35")
    }
    test("PM TableMap: rowspans") {
        let t = table(tr(cell(1, 2), c11(), cell(1, 2)), tr(c11()))
        try expectEqual(mapStr(t), "1, 6, 11, 1, 18, 11")
    }
    test("PM TableMap: deep rowspans") {
        let t = table(tr(cell(1, 4), cell(2, 1)), tr(cell(1, 2), cell(1, 2)), tr())
        try expectEqual(mapStr(t), "1, 6, 6, 1, 13, 18, 1, 13, 18")
    }
    test("PM TableMap: larger rectangles") {
        let t = table(tr(c11(), cell(4, 4)), tr(c11()), tr(c11()), tr(c11()))
        try expectEqual(mapStr(t), "1, 6, 6, 6, 6, 13, 6, 6, 6, 6, 20, 6, 6, 6, 6, 27, 6, 6, 6, 6")
    }

    test("PM TableMap: cell sizes") {
        try expectEqual(spanMap.width, 4)
        try expectEqual(spanMap.height, 3)
        try expectEqual(spanMap.findCell(1), TableRect(left: 0, top: 0, right: 2, bottom: 3))
        try expectEqual(spanMap.findCell(6), TableRect(left: 2, top: 0, right: 3, bottom: 1))
        try expectEqual(spanMap.findCell(11), TableRect(left: 3, top: 0, right: 4, bottom: 2))
        try expectEqual(spanMap.findCell(18), TableRect(left: 2, top: 1, right: 3, bottom: 2))
        try expectEqual(spanMap.findCell(25), TableRect(left: 2, top: 2, right: 4, bottom: 3))
    }
    test("PM TableMap: rectangle between two cells") {
        func between(_ a: Int, _ b: Int) -> String { spanMap.cellsInRect(spanMap.rectBetween(a, b)).map(String.init).joined(separator: ", ") }
        try expectEqual(between(1, 6), "1, 6, 18, 25")
        try expectEqual(between(1, 25), "1, 6, 11, 18, 25")
        try expectEqual(between(1, 1), "1")
        try expectEqual(between(6, 25), "6, 11, 18, 25")
        try expectEqual(between(6, 11), "6, 11, 18")
        try expectEqual(between(11, 6), "6, 11, 18")
        try expectEqual(between(18, 25), "18, 25")
        try expectEqual(between(6, 18), "6, 18")
    }
    test("PM TableMap: adjacent cells") {
        try expectEqual(spanMap.nextCell(1, .horiz, 1), 6)
        try expect(spanMap.nextCell(1, .horiz, -1) == nil)
        try expect(spanMap.nextCell(1, .vert, 1) == nil)
        try expect(spanMap.nextCell(1, .vert, -1) == nil)
        try expectEqual(spanMap.nextCell(18, .horiz, 1), 11)
        try expectEqual(spanMap.nextCell(18, .horiz, -1), 1)
        try expectEqual(spanMap.nextCell(18, .vert, 1), 25)
        try expectEqual(spanMap.nextCell(18, .vert, -1), 6)
        try expect(spanMap.nextCell(25, .vert, 1) == nil)
        try expectEqual(spanMap.nextCell(25, .vert, -1), 18)
        try expect(spanMap.nextCell(25, .horiz, 1) == nil)
        try expectEqual(spanMap.nextCell(25, .horiz, -1), 1)
    }
}

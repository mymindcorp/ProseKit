import Foundation
import DocumentModel
import SchemaKit
import TestHarness

// Ported from prosemirror-tables/test/{transpose, move-row-in-array-of-rows,
// convert-array-of-rows-to-table-node, convert-table-node-to-array-of-rows}.

func registerPMTableMoveTests() {
    // MARK: transpose
    test("PM transpose: inverts columns to rows (and back)") {
        let arr = [["a1", "a2", "a3"], ["b1", "b2", "b3"], ["c1", "c2", "c3"], ["d1", "d2", "d3"]]
        let expected = [["a1", "b1", "c1", "d1"], ["a2", "b2", "c2", "d2"], ["a3", "b3", "c3", "d3"]]
        try expectEqual(transpose(arr), expected)
        try expectEqual(transpose(expected), arr)
    }

    // MARK: moveRowInArrayOfRows
    func mv(_ name: String, _ rows: [Int], _ origin: [Int], _ target: [Int], _ dir: Int, _ expected: [Int]) {
        test("PM moveRowInArrayOfRows: \(name)") { try expectEqual(moveRowInArrayOfRows(rows, origin, target, dir), expected) }
    }
    mv("move element down", [0, 1, 2, 3, 4], [1], [3], 0, [0, 2, 3, 1, 4])
    mv("move element up", [0, 1, 2, 3, 4], [3], [1], 0, [0, 3, 1, 2, 4])
    mv("first to end", [0, 1, 2, 3], [0], [3], 0, [1, 2, 3, 0])
    mv("last to beginning", [0, 1, 2, 3], [3], [0], 0, [3, 0, 1, 2])
    mv("two consecutive down", [0, 1, 2, 3, 4, 5], [1, 2], [4, 5], 0, [0, 3, 4, 5, 1, 2])
    mv("two consecutive up", [0, 1, 2, 3, 4, 5], [4, 5], [1, 2], 0, [0, 4, 5, 1, 2, 3])
    mv("three elements", [0, 1, 2, 3, 4, 5, 6], [1, 2, 3], [5, 6], 0, [0, 4, 5, 6, 1, 2, 3])
    mv("override -1 (force before)", [0, 1, 2, 3, 4, 5], [1], [4], -1, [0, 2, 3, 1, 4, 5])
    mv("override 0 (natural)", [0, 1, 2, 3, 4, 5], [1], [4], 0, [0, 2, 3, 4, 1, 5])
    mv("override +1 (force after)", [0, 1, 2, 3, 4], [3], [1], 1, [0, 1, 3, 2, 4])
    mv("single element array", [0], [0], [0], 0, [0])
    mv("two element array", [0, 1], [0], [1], 0, [1, 0])
    mv("move to same position", [0, 1, 2, 3], [2], [2], 0, [0, 1, 2, 3])
    mv("adjacent elements", [0, 1, 2, 3], [1], [2], 0, [0, 2, 1, 3])
    mv("large arrays", Array(0..<10), [2, 3, 4], [7, 8, 9], 0, [0, 1, 5, 6, 7, 8, 9, 2, 3, 4])
    mv("entire beginning to end", [0, 1, 2, 3, 4], [0, 1, 2], [4], 0, [3, 4, 0, 1, 2])
    mv("entire end to beginning", [0, 1, 2, 3, 4], [3, 4], [0, 1], 0, [3, 4, 0, 1, 2])
    test("PM moveRowInArrayOfRows: works with strings") {
        try expectEqual(moveRowInArrayOfRows(["a", "b", "c", "d"], [0], [2], 0), ["b", "c", "a", "d"])
    }

    // MARK: convertTableNodeToArrayOfRows
    func grid(_ t: TaggedNode) -> [[String?]] {
        convertTableNodeToArrayOfRows(t.node).map { $0.map { $0?.textContent } }
    }
    test("PM convert→array: simple table") {
        try expectEqual(grid(table(tr(cell(1, 1, "A1"), cell(1, 1, "B1")), tr(cell(1, 1, "A2"), cell(1, 1, "B2")))),
                        [["A1", "B1"], ["A2", "B2"]])
    }
    test("PM convert→array: empty cells") {
        try expectEqual(grid(table(tr(cell(1, 1, "A1"), cEmpty()), tr(cEmpty(), cell(1, 1, "B2")))),
                        [["A1", ""], ["", "B2"]])
    }
    test("PM convert→array: single column") {
        try expectEqual(grid(table(tr(cell(1, 1, "A1")), tr(cell(1, 1, "A2")), tr(cell(1, 1, "A3")))),
                        [["A1"], ["A2"], ["A3"]])
    }
    test("PM convert→array: merged cells produce nils") {
        let t = table(
            tr(cell(1, 1, "A1"), cell(1, 1, "B1"), tdAttrs(["colspan": .int(2)], p("C1"))),
            tr(cell(1, 1, "A2"), tdAttrs(["colspan": .int(2)], p("B2")), tdAttrs(["rowspan": .int(2)], p("D1"))),
            tr(cell(1, 1, "A3"), cell(1, 1, "B3"), cell(1, 1, "C3")))
        try expectEqual(grid(t), [["A1", "B1", "C1", nil], ["A2", "B2", nil, "D1"], ["A3", "B3", "C3", nil]])
    }

    // MARK: convertArrayOfRowsToTableNode
    test("PM array→table: round-trips a plain table") {
        let t = table(tr(cell(1, 1, "A1"), cell(1, 1, "B1")), tr(cell(1, 1, "A2"), cell(1, 1, "B2")))
        let rows = convertTableNodeToArrayOfRows(t.node)
        try expectEqual(convertArrayOfRowsToTableNode(t.node, rows), t.node)
    }
    test("PM array→table: applies a modified cell") {
        let t = table(tr(cell(1, 1, "A1"), cell(1, 1, "B1")), tr(cell(1, 1, "A2"), cell(1, 1, "B2")))
        var rows = convertTableNodeToArrayOfRows(t.node)
        rows[0][1] = td(p("Modified")).node
        let expected = table(tr(cell(1, 1, "A1"), cell(1, 1, "Modified")), tr(cell(1, 1, "A2"), cell(1, 1, "B2")))
        try expectEqual(convertArrayOfRowsToTableNode(t.node, rows), expected.node)
    }
    test("PM array→table: round-trips a merged table") {
        let t = table(
            tr(cell(1, 1, "A1"), cell(1, 1, "B1"), tdAttrs(["colspan": .int(2)], p("C1"))),
            tr(cell(1, 1, "A2"), tdAttrs(["colspan": .int(2)], p("B2")), tdAttrs(["rowspan": .int(2)], p("D1"))),
            tr(cell(1, 1, "A3"), cell(1, 1, "B3"), cell(1, 1, "C3")))
        let rows = convertTableNodeToArrayOfRows(t.node)
        try expectEqual(convertArrayOfRowsToTableNode(t.node, rows), t.node)
    }
}

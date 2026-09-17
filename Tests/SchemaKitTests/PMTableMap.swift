import Foundation
import DocumentModel
import SchemaKit
import TestHarness

// Ported from prosemirror-tables/test/tablespanMap.test.ts.

private func mapStr(_ t: TaggedNode) -> String { TableMap.get(t.node).map.map(String.init).joined(separator: ", ") }
private let spanMap = TableMap.get(table(tr(cell(2, 3), c11(), cell(1, 2)), tr(c11()), tr(cell(2, 1))).node)

func registerPMTableMapTests() {
    for type in ["tableCell", "tableHeader"] {
        for (value, expected) in [(Int.min, 1), (-1, 1), (0, 1), (1, 1), (1000, 1000), (1001, 1000), (1_000_000, 1000), (Int.max, 1000)] {
            test("TableMap: bounded colspan \(value) in \(type)") {
                let editor = try Editor(extensions: fullKit())
                let schema = editor.schema
                let paragraph = try schema.node("paragraph", content: .from(schema.text("preserve me")))
                let cell = try schema.node(type, ["colspan": .int(value)], content: .from(paragraph))
                let row = try schema.node("tableRow", content: .from(cell))
                let table = try schema.node("table", content: .from(row))
                let stored = try schema.nodeFromJSON(table.toJSON())
                let map = TableMap.get(stored)
                try expectEqual(map.width, expected)
                try expectEqual(map.map, Array(repeating: 1, count: expected))
                try expectEqual(map.findCell(1), TableRect(left: 0, top: 0, right: expected, bottom: 1))

                editor.setContent(try schema.node("doc", content: .from(stored)))
                try expectEqual(editor.doc.textContent, "preserve me")
                let fixed = editor.doc.firstChild!
                try expectEqual(fixed.type.name, "table")
                try expectEqual(fixed.firstChild!.firstChild!.attrs["colspan"], .int(expected))
                try expectEqual(TableMap.get(fixed).width, expected)
                try expect(fixTables(editor.state, nil) == nil, "Repair must be idempotent")
            }
        }
    }

    test("TableMap: bounded colspan repair composes with missing cells and widths") {
        let editor = try Editor(extensions: fullKit())
        let schema = editor.schema
        func makeCell(_ text: String, _ span: Int, _ width: Int) throws -> Node {
            let paragraph = try schema.node("paragraph", content: .from(schema.text(text)))
            return try schema.node("tableCell", ["colspan": .int(span), "colwidth": .array([.int(width)])], content: .from(paragraph))
        }
        let first = try schema.node("tableRow", content: .from([makeCell("A", 0, 80), makeCell("B", 1, 90)]))
        let second = try schema.node("tableRow", content: .from(makeCell("C", -1, 0)))
        let table = try schema.node("table", content: .from([first, second]))
        // Two tables also exercise position mapping across preceding repairs.
        editor.setContent(try schema.node("doc", content: .from([table, table])))
        try expectEqual(editor.doc.textContent, "ABCABC")
        try expectEqual(editor.doc.childCount, 2)
        for i in 0..<2 {
            let fixed = editor.doc.child(i)
            try expectEqual(fixed.child(1).childCount, 2)
            try expectEqual(fixed.child(0).child(0).attrs["colspan"], .int(1))
            try expectEqual(fixed.child(1).child(0).attrs["colspan"], .int(1))
            try expectEqual(fixed.child(0).child(0).attrs["colwidth"], .array([.int(80)]))
            try expect(TableMap.get(fixed).problems == nil)
        }
        try expect(fixTables(editor.state, nil) == nil)
    }

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

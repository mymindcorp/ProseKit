import EditorStateKit
import DocumentModel
import EditorSerialization
import SchemaKit
import TestHarness

func registerMalformedTableImportTests() {
    for span in [Int.min, -1, 0, 1, 3, Int.max] {
        for html in [false, true] {
            test("malformed table import: rowspan \(span), HTML \(html)") {
                let editor = try Editor(extensions: fullKit())
                let markup = "<table><tr><td>A</td></tr><tr><td rowspan=\"\(span)\">B</td></tr><tr><td>C</td></tr></table>"
                if html {
                    try editor.setContent(html: markup)
                } else {
                    let doc = try HTMLParser.parse(markup, schema: editor.schema)
                    let loaded = try editor.schema.nodeFromJSON(doc.toJSON())
                    try expect(TableMap.get(loaded.firstChild!).width > 0)
                    editor.setContent(loaded)
                }
                try expectEqual(editor.doc.textContent, "ABC")
                let table = editor.doc.firstChild!
                var importedCell: Node?
                table.descendants { node, _, _, _ in
                    if node.type.name == "tableCell" && node.textContent == "B" { importedCell = node }
                    return true
                }
                try expectEqual(importedCell?.attrs["rowspan"], .int(min(2, max(1, span))))
                try expect(TableMap.get(table).map.allSatisfy { $0 > 0 })
                try expect(TableMap.get(table).problems == nil)
                try expect(fixTables(editor.state, nil) == nil)
                try editor.doc.check()
            }
        }
    }
    for value: AttributeValue in [.string("bad"), .bool(false), .null, .array([])] {
        test("malformed table import: wrong span types \(value)") {
            let editor = try Editor(extensions: fullKit())
            let schema = editor.schema
            let p = try schema.node("paragraph", content: .from(schema.text("keep")))
            let cell = try schema.node("tableHeader", ["colspan": value, "rowspan": value], content: .from(p))
            let row = try schema.node("tableRow", content: .from(cell))
            let table = try schema.node("table", content: .from(row))
            editor.setContent(try schema.nodeFromJSON(schema.node("doc", content: .from(table)).toJSON()))
            let attrs = editor.doc.firstChild!.firstChild!.firstChild!.attrs
            try expectEqual(attrs["colspan"], .int(1))
            try expectEqual(attrs["rowspan"], .int(1))
            try expectEqual(editor.doc.textContent, "keep")
            try expect(fixTables(editor.state, nil) == nil)
        }
    }
    for width in ["", "80", "-5,90,70", "bad,90"] {
        test("malformed table import: HTML colwidth \(width)") {
            let editor = try Editor(extensions: fullKit())
            try editor.setContent(html: "<table><tr><td colspan=\"2\" data-colwidth=\"\(width)\">keep</td></tr></table>")
            let tr = editor.state.tr
            updateColumnWidth(tr, 2, 120)
            editor.dispatch(tr)
            try expectEqual(editor.doc.textContent, "keep")
            try expect(fixTables(editor.state, nil) == nil)
            try expectEqual(TableMap.get(editor.doc.firstChild!).width, 2)
        }
    }
    // Older documents stored a scalar width rather than an array. The layout
    // reads it as the first column's width, so the fixer must canonicalize it
    // to the array form instead of dropping it.
    for scalar in [AttributeValue.int(3), .double(3)] {
        test("malformed table import: scalar colwidth \(scalar) is canonicalized, not erased") {
            let editor = try Editor(extensions: fullKit())
            let schema = editor.schema
            func header(_ text: String, _ width: AttributeValue) throws -> Node {
                try schema.node("tableHeader", ["colwidth": width],
                                content: .from(schema.node("paragraph", content: .from(schema.text(text)))))
            }
            let row = try schema.node("tableRow", content: .from([header("A", scalar), header("B", .int(1))]))
            let table = try schema.node("table", content: .from(row))
            editor.setContent(try schema.node("doc", content: .from(table)))
            let cells = editor.doc.firstChild!.firstChild!
            try expectEqual(cells.child(0).attrs["colwidth"], .array([.int(3)]))
            try expectEqual(cells.child(1).attrs["colwidth"], .array([.int(1)]))
            try expect(fixTables(editor.state, nil) == nil)
        }
    }
    let widths: [AttributeValue] = [.array([]), .array([.int(80)]), .array([.int(-5), .int(90), .int(70)]), .array([.string("bad"), .null]), .string("bad"), .null]
    for (index, width) in widths.enumerated() {
        test("malformed table import: colwidth shape \(index) can resize") {
            let editor = try Editor(extensions: fullKit())
            let schema = editor.schema
            let paragraph = try schema.node("paragraph", content: .from(schema.text("keep")))
            let cell = try schema.node("tableCell", ["colspan": .int(2), "colwidth": width], content: .from(paragraph))
            let row = try schema.node("tableRow", content: .from(cell))
            let table = try schema.node("table", content: .from(row))
            let doc = try schema.node("doc", content: .from(table))
            editor.setContent(try schema.nodeFromJSON(doc.toJSON()))
            let tr = editor.state.tr
            updateColumnWidth(tr, 2, 120)
            editor.dispatch(tr)
            try expectEqual(editor.doc.textContent, "keep")
            let attrs = editor.doc.firstChild!.firstChild!.firstChild!.attrs
            guard case let .array(values)? = attrs["colwidth"] else {
                try expect(false, "resize must produce a width array"); return
            }
            try expectEqual(values.count, 2)
            try expectEqual(values[0], .int(index == 1 ? 80 : 0))
            try expectEqual(values[1], .int(120))
            try expect(fixTables(editor.state, nil) == nil)
        }
    }
}

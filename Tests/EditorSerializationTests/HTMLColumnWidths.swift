import Foundation
import DocumentModel
import EditorSerialization
import TestHarness

// A table pasted from a web page or a document editor carries its column
// widths on `<col>` elements in a `<colgroup>`, not on the cells. They used to
// be dropped with the wrapper (Tiptap Table 3.27.4 fixed the same thing).

private func cell(_ text: String, _ attrs: Attrs = [:]) -> Node { node("tableCell", attrs, [p(text)]) }
private func header(_ text: String, _ attrs: Attrs = [:]) -> Node { node("tableHeader", attrs, [p(text)]) }
private func width(_ w: Int...) -> Attrs { ["colwidth": .array(w.map { .int($0) })] }

func registerHTMLColumnWidthTests() {
    test("HTML colgroup: col widths land on the cells of every row, headers included") {
        let html = """
        <table><colgroup><col width="100"><col style="width: 200px"></colgroup>
        <tr><th>a</th><th>b</th></tr><tr><td>c</td><td>d</td></tr></table>
        """
        try expectEqual(try HTMLParser.parse(html, schema: schema), doc(node("table", [:], [
            node("tableRow", [:], [header("a", width(100)), header("b", width(200))]),
            node("tableRow", [:], [cell("c", width(100)), cell("d", width(200))]),
        ])))
    }

    test("HTML colgroup: bare <col> elements without a colgroup count too") {
        let html = "<table><col width=\"80px\"><col width=\"90\"><tr><td>a</td><td>b</td></tr></table>"
        try expectEqual(try HTMLParser.parse(html, schema: schema), doc(node("table", [:], [
            node("tableRow", [:], [cell("a", width(80)), cell("b", width(90))]),
        ])))
    }

    test("HTML colgroup: a spanning cell takes the widths of every column it spans") {
        let html = "<table><colgroup><col width=\"100\"><col width=\"200\"><col width=\"300\"></colgroup><tr><td colspan=\"2\">a</td><td>b</td></tr></table>"
        try expectEqual(try HTMLParser.parse(html, schema: schema), doc(node("table", [:], [
            node("tableRow", [:], [cell("a", ["colspan": .int(2), "colwidth": .array([.int(100), .int(200)])]),
                                   cell("b", width(300))]),
        ])))
    }

    test("HTML colgroup: a cell spanning rows shifts the cells beneath it") {
        let html = """
        <table><colgroup><col width="100"><col width="200"></colgroup>
        <tr><td rowspan="2">a</td><td>b</td></tr><tr><td>c</td></tr></table>
        """
        try expectEqual(try HTMLParser.parse(html, schema: schema), doc(node("table", [:], [
            node("tableRow", [:], [cell("a", ["rowspan": .int(2), "colwidth": .array([.int(100)])]), cell("b", width(200))]),
            node("tableRow", [:], [cell("c", width(200))]),
        ])))
    }

    test("HTML colgroup: a cell's own data-colwidth wins, and a column without a width leaves its cells alone") {
        let html = "<table><colgroup><col width=\"100\"><col><col width=\"50%\"></colgroup><tr><td data-colwidth=\"120\">a</td><td>b</td><td>c</td></tr></table>"
        try expectEqual(try HTMLParser.parse(html, schema: schema), doc(node("table", [:], [
            node("tableRow", [:], [cell("a", width(120)), cell("b"), cell("c")]),
        ])))
    }

    test("HTML colgroup: a nested table's columns aren't the outer table's") {
        let html = "<table><tr><td><table><colgroup><col width=\"100\"></colgroup><tr><td>in</td></tr></table></td></tr></table>"
        let d = try HTMLParser.parse(html, schema: schema)
        let outer = d.child(0).child(0).child(0)
        try expectEqual(outer.attrs["colwidth"], .null)
    }
}

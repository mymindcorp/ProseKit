import Foundation
import DocumentModel
import EditorSerialization
import TestHarness

// CommonMark's lazy continuation: a line that isn't indented into a list item
// and doesn't start a block of its own still continues the paragraph the item
// is holding — `1. a\nsecond` is one item reading "a second". The parser did
// this for quotes but ended the list instead, leaving "second" as a paragraph
// after it. Every expectation here was checked against commonmark.js.

private func bullets(_ items: Node...) -> Node { node("bulletList", tightList, items) }
private func item(_ blocks: Node...) -> Node { node("listItem", [:], blocks) }

/// A document as one line — `bulletList(listItem(paragraph("a b")))` — which
/// is what a mismatch needs to show, not the node dump.
private func shape(_ n: Node) -> String {
    if n.isText { return (n.text ?? "").debugDescription }
    return n.type.name + "(" + (0..<n.childCount).map { shape(n.child($0)) }.joined(separator: ", ") + ")"
}

func registerMarkdownLazyLineTests() {
    func parses(_ name: String, _ md: String, _ expected: Node) {
        test("md lazy lines: \(name)") {
            let parsed = try MarkdownParser.parse(md, schema: schema)
            try expect(parsed == expected, "\(md.debugDescription) parsed as \(shape(parsed)), expected \(shape(expected))")
        }
    }

    parses("an unindented line continues the item's paragraph",
           "1. a\nsecond",
           doc(node("orderedList", ["order": .int(1), "tight": .bool(true)], [item(p("a second"))])))
    parses("...and the last item's",
           "1. a\n2. b\nlazy",
           doc(node("orderedList", ["order": .int(1), "tight": .bool(true)], [item(p("a")), item(p("b lazy"))])))
    parses("it continues a nested list's paragraph",
           "- a\n  - b\nlazy",
           doc(bullets(item(p("a"), bullets(item(p("b lazy")))))))
    // (The empty paragraph is the schema's: an item has to start with one.)
    parses("it continues a quote's paragraph inside the item",
           "- > q\nlazy",
           doc(bullets(item(p(""), node("blockquote", [:], [p("q lazy")])))))
    parses("a blank line first ends the list as before",
           "- a\n\nlazy",
           doc(bullets(item(p("a"))), p("lazy")))
    parses("a heading ends the list",
           "- a\n# H",
           doc(bullets(item(p("a"))), node("heading", ["level": .int(1)], [t("H")])))
    parses("a heading in the item holds nothing open",
           "- # h\nlazy",
           doc(bullets(item(p(""), node("heading", ["level": .int(1)], [t("h")]))), p("lazy")))
    parses("a thematic break ends the list",
           "- a\n---",
           doc(bullets(item(p("a"))), node("horizontalRule", [:], [])))
    parses("a run of = is text, not an underline across the item's edge",
           "- a\n===",
           doc(bullets(item(p("a ===")))))
    parses("an open fence in the item takes no lazy line",
           "- a\n  ```\n  code\nlazy",
           doc(bullets(item(p("a"), node("codeBlock", [:], [t("code")]))), p("lazy")))
    parses("trailing spaces on the item's line still make a hard break",
           "- a  \nb",
           doc(bullets(item(p(t("a"), node("hardBreak", [:], []), t("b"))))))
}

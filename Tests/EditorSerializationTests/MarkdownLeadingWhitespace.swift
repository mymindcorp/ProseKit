import Foundation
import DocumentModel
import EditorSerialization
import TestHarness

// A paragraph line that starts with whitespace. The reader strips a paragraph
// line's leading whitespace, so it can't survive a round trip — but the rest of
// the paragraph has to. Four columns of it used to open an indented code block
// (`p("    x")` came back as `codeBlock("x")`), and fewer of them sat in front of
// the backslash that escapes a rule or a setext underline, which then escaped
// nothing: `p("   ---")` wrote `\   ---` and came back as "\   ---".

private let br = node("hardBreak")

/// A document as one line — `paragraph("a", hardBreak, "b")` — which is what a
/// mismatch needs to show, not the node dump.
private func shape(_ n: Node) -> String {
    if n.isText { return (n.text ?? "").debugDescription }
    if n.childCount == 0 { return n.type.name }
    return n.type.name + "(" + (0..<n.childCount).map { shape(n.child($0)) }.joined(separator: ", ") + ")"
}

private func dropIndent(_ s: String) -> String { String(s.drop(while: { $0 == " " || $0 == "\t" })) }

func registerMarkdownLeadingWhitespaceTests() {
    func roundTrips(_ name: String, _ d: Node, _ expected: Node) {
        test("md leading whitespace: \(name)") {
            let md = MarkdownSerializer.serialize(d)
            let back = try MarkdownParser.parse(md, schema: schema)
            try expect(back == expected, "\(shape(d)) wrote \(md.debugDescription), read back \(shape(back))")
        }
    }

    roundTrips("four spaces stay a paragraph", doc(p("    x")), doc(p("x")))
    roundTrips("...in front of a heading marker", doc(p("    # x")), doc(p("# x")))
    roundTrips("a tab stays a paragraph", doc(p("\tx")), doc(p("x")))
    roundTrips("an indented rule is escaped after its indent", doc(p("   ---")), doc(p("---")))
    roundTrips("an indented setext underline", doc(p(" --")), doc(p("--")))
    roundTrips("a tab-indented rule", doc(p("\t---")), doc(p("---")))
    roundTrips("an indented rule after a hard break", doc(p(t("a"), br, t("    ---"))), doc(p(t("a"), br, t("---"))))
    roundTrips("four spaces in a list item stay out of a code block",
               doc(node("bulletList", tightList, [node("listItem", [:], [p("    x")])])),
               doc(node("bulletList", tightList, [node("listItem", [:], [p("x")])])))

    // Found by the property below: any line starting with `#` ended the
    // paragraph above it, though only a heading can — `#tag` is text, and so is
    // a run of seven hashes.
    test("md leading whitespace: a hash line that isn't a heading continues the paragraph") {
        for (md, text) in [("a\n#tag", "a #tag"), ("a\n####### x", "a ####### x"), ("a\n#5", "a #5")] {
            let back = try MarkdownParser.parse(md, schema: schema)
            try expect(back == doc(p(text)), "\(md.debugDescription) read back \(shape(back))")
        }
        try expectEqual(try MarkdownParser.parse("a\n# b", schema: schema), doc(p("a"), node("heading", ["level": .int(1)], [t("b")])))
    }

    // The property behind all of the above: whatever indentation a paragraph
    // line starts with, and whatever block marker follows it, the paragraph
    // reads back as itself less that indentation — on its first line, on a line
    // a hard break starts, at the top level, in a list item, and in a quote.
    test("md leading whitespace: property over indents and block markers") {
        let indents = ["", " ", "  ", "   ", "    ", "     ", "        ", "\t", " \t", "\t\t", "  \t "]
        let bodies = ["x", "---", "--", "-", "***", "___", "- - -", " - - -", "* * *", "===", "=",
                      "# x", "#", "###### x", "####### x", "#tag", "#5", "> x", ">", "- x", "* x", "+ x", "-\tx",
                      "1. x", "1) x", "1.", "123456789. x", "^^^fig", "x|y", "-|-", "|a|", "| - |"]
        let contexts: [(String, (Node) -> Node)] = [
            ("top level", { doc($0) }),
            ("list item", { doc(node("bulletList", tightList, [node("listItem", [:], [$0])])) }),
            ("quote", { doc(node("blockquote", [:], [$0])) }),
        ]
        var failures: [String] = []
        for indent in indents {
            for body in bodies {
                let text = indent + body
                let lines: [(Node, Node)] = [
                    (p(text), p(dropIndent(text))),
                    (p(t("a"), br, t(text)), p(t("a"), br, t(dropIndent(text)))),
                ]
                for (context, wrap) in contexts {
                    for (para, expected) in lines {
                        let d = wrap(para)
                        let md = MarkdownSerializer.serialize(d)
                        let back = try MarkdownParser.parse(md, schema: schema)
                        if back != wrap(expected) {
                            failures.append("\(context): \(shape(para)) wrote \(md.debugDescription), read back \(shape(back))")
                        }
                    }
                }
            }
        }
        try expect(failures.isEmpty, "\(failures.count) failed, e.g.\n" + failures.prefix(12).joined(separator: "\n"))
    }
}

import Foundation
import DocumentModel
import EditorSerialization
import TestHarness

// Making the inline scanner linear replaced how three things are worked out:
// emphasis pairing walks a linked list rather than an array it removes from,
// bracket matching is precomputed in one pass rather than walked per bracket,
// and adjacent text is joined in one buffer rather than rebuilt per piece.
//
// These lock in what the parser produces for the constructs those three touch.
// The expectations are the parser's own output, taken from it and checked to be
// byte-identical before and after the change — they say "this still parses the
// way it did", not "this is what CommonMark asks for". Where the two differ it
// is called out at the case; that difference is older than this change and is
// left alone by it.

private func text(_ markdown: String) -> String {
    ((try? MarkdownParser.parse(markdown, schema: schema))?.textContent) ?? "<parse failed>"
}

private func marksOn(_ markdown: String) -> [[String]] {
    guard let doc = try? MarkdownParser.parse(markdown, schema: schema), doc.childCount > 0 else { return [] }
    let block = doc.child(0)
    return (0..<block.childCount).map { i in block.child(i).marks.map(\.type.name).sorted() }
}

func registerMarkdownInlineParityTests() {
    // MARK: - Emphasis pairing

    // The cases the delimiter algorithm exists for: one run supplying two pairs,
    // and an inner pair closing before the outer one can.
    test("inline parity: emphasis nests and doubles up") {
        try expectEqual(marksOn("***foo***"), [["bold", "italic"]])
        try expectEqual(text("***foo***"), "foo")
        try expectEqual(marksOn("*foo **bar** baz*"), [["italic"], ["bold", "italic"], ["italic"]])
        try expectEqual(text("*foo **bar** baz*"), "foo bar baz")
    }

    // The rule of three: `<em>foo<strong>bar</strong>baz</em>`, with the inner
    // pair matched before the outer one closes past it. This is the case that
    // most depends on the traversal order the linked list has to preserve.
    test("inline parity: a run pairs across the middle by the rule of three") {
        try expectEqual(text("*foo**bar**baz*"), "foobarbaz")
        try expectEqual(marksOn("*foo**bar**baz*"), [["italic"], ["bold", "italic"], ["italic"]])
    }

    test("inline parity: delimiters stranded inside a pair stay literal") {
        try expectEqual(text("*a*b*"), "ab*")
        try expectEqual(text("**a*b**"), "a*b")
    }

    test("inline parity: an unmatched run is text") {
        for markdown in ["*a", "a*", "_a", "*a**b", "a * b", "**"] {
            try expectEqual(text(markdown), markdown, "for \(markdown)")
        }
        // A run with nothing to mark is consumed rather than left as text —
        // again the parser's own behaviour, unchanged here.
        try expectEqual(text("*"), "")
        try expectEqual(text("***"), "")
    }

    test("inline parity: underscores pair like asterisks but not inside a word") {
        try expectEqual(text("_foo_"), "foo")
        try expectEqual(marksOn("_foo_"), [["italic"]])
        try expectEqual(text("foo_bar_baz"), "foo_bar_baz")
    }

    // MARK: - Bracket matching

    test("inline parity: a label closes at its own bracket, counting nesting") {
        try expectEqual(text("[link [foo [bar]]](/uri)"), "link [foo [bar]]")
        try expectEqual(marksOn("[link [foo [bar]]](/uri)"), [["link"]])
    }

    test("inline parity: an image inside a link holds together") {
        let doc = try MarkdownParser.parse("[![alt](img.png)](/uri)", schema: schema)
        let block = doc.child(0)
        try expectEqual(block.childCount, 1)
        try expectEqual(block.child(0).type.name, "image")
        try expect(block.child(0).marks.contains { $0.type.name == "link" },
                   "the image should carry the outer link")
    }

    test("inline parity: an escaped bracket doesn't open or close a label") {
        try expectEqual(text("[a\\]b](/uri)"), "a]b")
        try expectEqual(text("\\[not a link](/uri)"), "[not a link](/uri)")
    }

    test("inline parity: unmatched brackets stay literal") {
        for markdown in ["[", "]", "[a", "a]", "[[a", "see [1] there", "[a][", "[a]("] {
            try expectEqual(text(markdown), markdown, "for \(markdown)")
        }
    }

    // Links don't nest: the inner one wins and the outer brackets stay text.
    test("inline parity: links don't nest") {
        try expectEqual(text("[foo [bar](/inner)](/outer)"), "[foo bar](/outer)")
        try expectEqual(marksOn("[foo [bar](/inner)](/outer)"), [[], ["link"], []])
    }

    // MARK: - The link-destination paren bound

    // A destination may hold balanced parentheses; past the bound it stops being
    // read as one, which is the single deliberate behaviour change here.
    test("inline parity: balanced parens in a destination still parse") {
        try expectEqual(text("[a](/uri(inner))"), "a")
        let nested = "[a](" + String(repeating: "(", count: 8) + String(repeating: ")", count: 8) + ")"
        try expectEqual(text(nested), "a")
    }

    test("inline parity: a destination nested past the bound is not a link") {
        let depth = MarkdownParser.maxLinkParenDepth + 2
        let over = "[a](" + String(repeating: "(", count: depth) + String(repeating: ")", count: depth) + ")"
        try expectEqual(text(over), over)
    }

    // MARK: - Two-byte delimiters

    test("inline parity: paired delimiters still close where they should") {
        try expectEqual(text("~~struck~~"), "struck")
        try expectEqual(text("==marked=="), "marked")
        // Unclosed, so literal.
        try expectEqual(text("~~a"), "~~a")
        // The memo that skips a repeat of a failed search must not lose a pair
        // that does close later in the same line.
        try expectEqual(text("~~a~~ and ~~b~~"), "a and b")
        try expectEqual(text("~~a and ~~b~~"), "a and b~~")
    }

    // MARK: - Text joining

    test("inline parity: adjacent text with the same marks becomes one node") {
        let doc = try MarkdownParser.parse("a\\*b\\*c", schema: schema)
        try expectEqual(doc.child(0).childCount, 1)
        try expectEqual(doc.textContent, "a*b*c")
    }

    test("inline parity: text with differing marks stays separate") {
        let doc = try MarkdownParser.parse("plain *em* plain", schema: schema)
        try expectEqual(doc.child(0).childCount, 3)
        try expectEqual(doc.textContent, "plain em plain")
    }

    // MARK: - The hostile payloads still parse to something sensible

    test("inline parity: a line of openers is text, all of it") {
        for opener in ["[", "[a](", "[a][", "<"] {
            let line = String(repeating: opener, count: 300)
            try expectEqual(text(line), line, "for a line of \(opener)")
        }
    }

    test("inline parity: a line of emphasis runs pairs off the same way") {
        try expectEqual(text(String(repeating: "*a", count: 300)),
                        String(repeating: "a", count: 300))
    }
}

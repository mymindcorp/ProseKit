import Foundation
import DocumentModel
import EditorSerialization
import TestHarness

// Adapted from prosemirror-markdown/test/test-parse.ts. PM's serializer asserts
// its own exact dialect (escaping/marker choices), which our hand-rolled
// serializer doesn't reproduce byte-for-byte — so instead of exact-string
// matching we check the two things that ARE correctness:
//   • parse(md) produces the right document structure, and
//   • parse → serialize → parse is idempotent (no structure lost either way).

// Block builders (no clash with the existing doc/p/t/strong/em/h in main.swift).
// ul/ol/li are internal: main.swift's HTML paste tests share them.
// Markdown lists in these tests are written tight; the HTML-paste tests in
// main.swift that share these helpers pass `tight: false`.
func ul(tight: Bool = true, _ c: Node...) -> Node { node("bulletList", ["tight": .bool(tight)], c) }
func ol(tight: Bool = true, _ c: Node...) -> Node { node("orderedList", ["tight": .bool(tight)], c) }
func li(_ c: Node...) -> Node { node("listItem", [:], c) }
private func pre(_ s: String) -> Node { node("codeBlock", [:], s.isEmpty ? [] : [t(s)]) }
private func bq(_ c: Node...) -> Node { node("blockquote", [:], c) }
private func hr() -> Node { node("horizontalRule", [:]) }
private func brk() -> Node { node("hardBreak", [:]) }
private func img(_ src: String = "img.png", _ alt: String = "x") -> Node { node("image", ["src": .string(src), "alt": .string(alt)]) }
private func a(_ s: String, _ href: String = "foo") -> Node { schema.text(s, [schema.mark("link", ["href": .string(href)])]) }
private func codeM(_ s: String) -> Node { schema.text(s, [schema.mark("code")]) }

func registerPMMarkdownTests() {
    func parses(_ name: String, _ md: String, _ expected: Node) {
        test("PM md parse: \(name)") {
            try expectEqual(try MarkdownParser.parse(md, schema: schema), expected)
        }
    }
    func roundTrip(_ name: String, _ md: String) {
        test("PM md round-trip: \(name)") {
            let d = try MarkdownParser.parse(md, schema: schema)
            let md2 = d.toMarkdown()
            let d2 = try MarkdownParser.parse(md2, schema: schema)
            try expectEqual(d2, d, "round-trip changed structure; reserialized as:\n\(md2)")
        }
    }

    // MARK: structural parse checks
    parses("a paragraph", "hello!", doc(p("hello!")))
    parses("headings", "# one\n\n## two\n\nthree", doc(h(1, "one"), h(2, "two"), p("three")))
    parses("a blockquote", "> once\n\n> > twice", doc(bq(p("once")), bq(bq(p("twice")))))
    parses("a flat bullet list", "* foo\n* bar\n* baz", doc(ul(li(p("foo")), li(p("bar")), li(p("baz")))))
    // The blank line between the items makes this list loose.
    parses("an ordered list", "1. Hello\n\n2. Goodbye",
           doc(ol(tight: false, li(p("Hello")), li(p("Goodbye")))))
    // A code span inside emphasis ("**`code` is bold**") is left out of the
    // round-trip corpus: the schema's `code` mark excludes every other mark, so
    // the span can't carry the bold, and the document that results — a code span
    // followed by bold text — has no Markdown spelling, because "**" directly
    // after a backtick can't open emphasis. The parse itself is right; see the
    // dedicated test in main.swift.
    //
    // Nested lists and indented code blocks used to be listed here as known
    // limitations; both are now parsed (see the dedicated tests in main.swift).
    // What remains of the simplified parser's divergence is documented in
    // docs/markdown-gaps.md — chiefly that a ProseMirror listItem always holds
    // block content, so a tight list still serializes in the <li><p> form.
    parses("inline marks", "Hello. Some *em* text, some **strong** text, and some `code`",
           doc(p(t("Hello. Some "), em("em"), t(" text, some "), strong("strong"), t(" text, and some "), codeM("code"))))
    parses("links", "My [link](foo) goes to foo", doc(p(t("My "), a("link"), t(" goes to foo"))))
    parses("an image", "Here's an image: ![x](img.png)", doc(p(t("Here's an image: "), img())))
    parses("a horizontal rule", "one two\n\n---\n\nthree", doc(p("one two"), hr(), p("three")))
    parses("hard breaks", "foo\\\nbar", doc(p(t("foo"), brk(), t("bar"))))
    parses("ignores HTML tags", "Foo < img> bar", doc(p("Foo < img> bar")))
    parses("doesn't accidentally generate list markup", "1\\. foo", doc(p("1. foo")))
    parses("doesn't escape underscores between word characters", "abc_def", doc(p("abc_def")))

    // MARK: round-trip idempotence (parse → serialize → parse)
    let corpus: [(String, String)] = [
        ("paragraph", "hello!"),
        ("headings", "# one\n\n## two\n\nthree"),
        ("blockquote", "> once\n\n> > twice"),
        ("bullet list", "* foo\n\n  * bar\n\n  * baz\n\n* quux"),
        ("ordered list", "1. Hello\n\n2. Goodbye\n\n3. Nest\n\n   1. Hey\n\n   2. Aye"),
        ("heading in a list", "* # Foo"),
        ("indented code block", "Some code:\n\n    Here it is\n\nPara"),
        ("inline marks", "Hello. Some *em* text, some **strong** text, and some `code`"),
        ("overlapping inline marks", "This is **strong *emphasized text with `code` in* it**"),
        ("links inside strong", "**[link](foo) is bold**"),
        ("emphasis inside links", "[link *foo **bar** `#`*](foo)"),
        ("hard break", "foo\\\nbar"),
        ("hard break in emphasis", "*foo\\\nbar*"),
        ("a link", "My [link](foo) goes to foo"),
        ("an image", "Here's an image: ![x](img.png)"),
        ("a horizontal rule", "one two\n\n---\n\nthree"),
        ("HTML tags ignored", "Foo < img> bar"),
        ("escaped list marker", "1\\. foo"),
        ("underscores in words", "abc_def"),
        ("long underscores in words", "abc___def"),
        ("code with star", "foo`*`"),
        ("nested list with paragraphs", "* foo\n\n  bar\n\n* baz"),
        ("doc heading then list", "# Title\n\n* a\n\n* b\n\n* c"),
    ]
    for (name, md) in corpus { roundTrip(name, md) }
}

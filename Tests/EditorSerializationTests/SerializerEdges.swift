import Foundation
import DocumentModel
import EditorSerialization
import TestHarness

// Corners of the Markdown, HTML, and RTF paths with no test: an image title
// that itself contains a quote, a loose list of one item, a pipe table read
// into a schema with no table nodes, inline HTML with a doctype or unquoted
// attributes, block-level stray text and images, `aria-hidden` wrappers at
// the top level, wiki-link target types, RTF's hyphen controls, and what each
// parser's errors say.

private let minimalSchema: Schema = try! Schema(nodes: [
    ("doc", NodeSpec(content: "block+")),
    ("paragraph", NodeSpec(content: "inline*", group: "block")),
    ("text", NodeSpec(group: "inline")),
])

private func rtf(_ body: String) -> String { "{\\rtf1\\ansi\\deff0 " + body + "}" }

func registerSerializerEdgeTests() {
    // MARK: Markdown

    test("md: an image title containing a double quote is written in single quotes") {
        let d = doc(p(node("image", ["src": .string("a.png"), "alt": .string("x"), "title": .string("say \"hi\"")])))
        let md = d.toMarkdown()
        try expect(md.contains("![x](a.png 'say \"hi\"')"), "got: \(md)")
        let back = try MarkdownParser.parse(md, schema: schema)
        try expectEqual(back, d)
    }

    test("md: a loose list with a single item stays loose through a round trip") {
        let d = doc(ol(tight: false, li(p("only"))))
        let md = d.toMarkdown()
        let back = try MarkdownParser.parse(md, schema: schema)
        try expectEqual(back, d, "reserialized as:\n\(md)")
        let bullets = doc(ul(tight: false, li(p("only"))))
        try expectEqual(try MarkdownParser.parse(bullets.toMarkdown(), schema: schema), bullets)
    }

    test("md: a pipe table read into a schema without tables is ordinary text") {
        let md = "| a | b |\n|---|---|\n| 1 | 2 |"
        let d = try MarkdownParser.parse(md, schema: minimalSchema)
        try expect(d.textContent.contains("| a | b |"), "got: \(d.textContent)")
        try expectEqual(d.child(0).type.name, "paragraph")
    }

    test("md: inline HTML with unquoted attributes and a doctype is still read") {
        let d = try MarkdownParser.parse("pic <img src=a.png alt=cat> here", schema: schema)
        var image: Node?
        d.descendants { n, _, _, _ in if n.type.name == "image" { image = n }; return image == nil }
        try expectEqual(image?.attrs["src"], .string("a.png"))
        try expectEqual(image?.attrs["alt"], .string("cat"))
        let declared = try MarkdownParser.parse("<!DOCTYPE html>\n\nafter", schema: schema)
        try expect(declared.textContent.contains("after"))
    }

    test("md: the parser's errors describe themselves") {
        try expect("\(MarkdownParseError.nestingTooDeep(limit: 3))".contains("3"))
        try expect("\(MarkdownParseError.invalidDocument("why"))".contains("why"))
    }

    // MARK: HTML

    test("html: stray text at the top level becomes a paragraph, and blank text is dropped") {
        let d = try HTMLParser.parse("just text", schema: schema)
        try expectEqual(d, doc(p("just text")))
        let blank = try HTMLParser.parse("   \n  <p>x</p>", schema: schema)
        try expectEqual(blank, doc(p("x")))
    }

    test("html: an image at the top level is kept") {
        let d = try HTMLParser.parse("<img src=\"a.png\" alt=\"x\">", schema: schema)
        var image: Node?
        d.descendants { n, _, _, _ in if n.type.name == "image" { image = n }; return image == nil }
        try expectEqual(image?.attrs["src"], .string("a.png"))
    }

    test("html: an aria-hidden wrapper at the top level is skipped") {
        let d = try HTMLParser.parse("<span aria-hidden=\"true\"><p>hidden</p></span><p>shown</p>", schema: schema)
        try expectEqual(d.textContent, "shown")
    }

    test("html: a wiki link's target type is written and read back") {
        let link = node("wikiLink", ["text": .string("Home"), "targetId": .string("42"), "targetType": .string("Note")])
        let d = doc(p(link))
        let html = HTMLSerializer.serialize(d)
        try expect(html.contains("data-wikilink-id=\"42\""), "got: \(html)")
        try expect(html.contains("data-wikilink-type=\"Note\""), "got: \(html)")
        let back = try HTMLParser.parse(html, schema: schema)
        var found: Node?
        back.descendants { n, _, _, _ in if n.type.name == "wikiLink" { found = n }; return found == nil }
        try expectEqual(found?.attrs["targetType"], .string("Note"))
        try expectEqual(found?.attrs["targetId"], .string("42"))
    }

    test("html: the parser's errors describe themselves") {
        try expect("\(HTMLParseError.nestingTooDeep(depth: 9, limit: 8))".contains("9"))
        try expect("\(HTMLParseError.invalidDocument("why"))".contains("why"))
    }

    test("html: the benchmark's token count sees every tag") {
        try expectEqual(HTMLParser.tokenCountForBenchmark("<p>a</p><p>b</p>"), 6)
    }

    // MARK: RTF

    test("rtf: the hyphen controls — non-breaking kept, optional dropped, and a non-breaking space") {
        let d = try RTFParser.parse(rtf("\\pard a\\_b\\-c\\~d\\par"), schema: schema)
        try expectEqual(d.textContent, "a\u{2011}bc\u{00A0}d")
    }

    test("rtf: the parser's errors describe themselves") {
        try expectThrows { _ = try RTFParser.parse("not rtf at all", schema: schema) }
        try expect("\(RTFParseError.notRTF)".contains("RTF"))
        try expect("\(RTFParseError.nestingTooDeep(depth: 5, limit: 4))".contains("5"))
        try expect("\(RTFParseError.invalidDocument("why"))".contains("why"))
    }
}

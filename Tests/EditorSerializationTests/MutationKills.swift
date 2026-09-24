import Foundation
import DocumentModel
import EditorSerialization
import TestHarness

// Cases a mutation-testing pass found missing: each one pins a behaviour that
// could be broken — a comparison flipped, a character dropped from an escape
// set, a guard deleted — without any other test in the suite noticing. They
// assert the exact text written or the exact document read, because a round
// trip alone is often satisfied by both the right answer and the broken one.

private func md(_ d: Node) -> String { MarkdownSerializer.serialize(d) }
private func parseMD(_ s: String) throws -> Node { try MarkdownParser.parse(s, schema: schema) }
private func parseHTML(_ s: String) throws -> Node { try HTMLParser.parse(s, schema: schema) }
private func json(_ s: String) throws -> AttributeValue { try DocumentJSON.parse(Data(s.utf8)) }

private func marked(_ s: String, _ names: String...) -> Node {
    schema.text(s, names.map { schema.mark($0) })
}
private func linked(_ s: String, _ href: String, title: String? = nil, _ extra: String...) -> Node {
    var attrs: Attrs = ["href": .string(href)]
    if let title { attrs["title"] = .string(title) }
    return schema.text(s, [schema.mark("link", attrs)] + extra.map { schema.mark($0) })
}
private func br() -> Node { node("hardBreak") }
private func bullets(_ texts: String...) -> Node {
    node("bulletList", tightList, texts.map { node("listItem", [:], [p($0)]) })
}

/// Every mark-carrying text run in a document, as `text[mark,mark]`.
private func runs(_ n: Node) -> [String] {
    var out: [String] = []
    n.descendants { child, _, _, _ in
        if child.isText {
            out.append((child.text ?? "") + "[" + child.marks.map(\.type.name).sorted().joined(separator: ",") + "]")
        }
        return true
    }
    return out
}

private func hrefs(_ n: Node) -> [String] {
    var out: [String] = []
    n.descendants { child, _, _, _ in
        for m in child.marks where m.type.name == "link" { out.append(m.attrs["href"]?.stringValue ?? "") }
        return true
    }
    return out
}

private func colors(_ n: Node) -> [String] {
    var out: [String] = []
    n.descendants { child, _, _, _ in
        for m in child.marks where m.type.name == "textColor" { out.append(m.attrs["color"]?.stringValue ?? "") }
        return true
    }
    return out
}

private func types(_ n: Node) -> [String] { (0..<n.childCount).map { n.child($0).type.name } }

func registerSerializationMutationKillTests() {
    // MARK: Markdown writer — escaping

    test("mut: a doubled '=' is escaped on both characters") {
        try expectEqual(md(doc(p("a == b"))), #"a \=\= b"#)
        try expectEqual(md(doc(p("x ~~ y"))), #"x \~\~ y"#)
        try expectEqual(md(doc(p("a = b ~ c"))), "a = b ~ c")
    }

    test("mut: an all-space code span is written without padding") {
        // CommonMark strips one space from each end of a code span unless it is
        // all spaces, so padding one would add two spaces to it.
        try expectEqual(md(doc(p(t("a"), marked(" ", "code"), t("b")))), "a` `b")
        let back = try parseMD("a` `b")
        try expectEqual(runs(back), ["a[]", " [code]", "b[]"])
    }

    test("mut: a heading ending in '#' escapes the run") {
        try expectEqual(md(doc(h(2, "C#"))), "## C\\#")
        try expectEqual(try parseMD(md(doc(h(2, "C##")))), doc(h(2, "C##")))
    }

    test("mut: three lists of one kind in a row alternate their markers") {
        let d = doc(bullets("a"), bullets("b"), bullets("c"))
        try expectEqual(md(d), "- a\n\n+ b\n\n- c")
        try expectEqual(try parseMD(md(d)), d)
        let o = { (s: String) in node("orderedList", ["order": .int(1), "tight": .bool(true)], [node("listItem", [:], [p(s)])]) }
        try expectEqual(md(doc(o("a"), o("b"), o("c"))), "1. a\n\n1) b\n\n1. c")
    }

    test("mut: a task list is written tight") {
        let d = doc(node("taskList", [:], [
            node("taskItem", ["checked": .bool(false)], [p("a")]),
            node("taskItem", ["checked": .bool(true)], [p("b")]),
        ]))
        try expectEqual(md(d), "- [ ] a\n- [x] b")
    }

    test("mut: blank lines inside a list item stay blank") {
        let d = doc(node("bulletList", ["tight": .bool(false)], [
            node("listItem", [:], [p("a"), p("b")]),
            node("listItem", [:], [p("c")]),
        ]))
        try expectEqual(md(d), "- a\n\n  b\n\n- c")
    }

    test("mut: a six-hash paragraph line is escaped, a seven-hash one isn't") {
        try expectEqual(md(doc(p("###### x"))), "\\###### x")
        try expectEqual(md(doc(p("####### x"))), "####### x")
        try expectEqual(try parseMD(md(doc(p("###### x")))), doc(p("###### x")))
    }

    test("mut: a nine-digit number opening a paragraph is escaped") {
        try expectEqual(md(doc(p("123456789. x"))), #"123456789\. x"#)
        try expectEqual(md(doc(p("1234567890. x"))), "1234567890. x")
        try expectEqual(try parseMD(md(doc(p("123456789. x")))), doc(p("123456789. x")))
    }

    test("mut: a paragraph opening '1)' is escaped") {
        try expectEqual(md(doc(p("1) x"))), #"1\) x"#)
        try expectEqual(try parseMD(md(doc(p("1) x")))), doc(p("1) x")))
    }

    test("mut: a block marker after a hard break is escaped too") {
        let d = doc(p(t("a"), br(), t("> b")))
        try expectEqual(md(d), "a\\\n\\> b")
        try expectEqual(try parseMD(md(d)), d)
    }

    test("mut: a marker indented four columns on a continuation line isn't escaped") {
        // Four columns in, `# x` can't open a heading — and on a paragraph's
        // continuation line it can't open indented code either — so it needs
        // no backslash. Three columns in, it would open one, so it does.
        let four = doc(p(t("a"), br(), t("    # x")))
        try expectEqual(md(four), "a\\\n    # x")
        try expectEqual(types(try parseMD(md(four))), ["paragraph"])
        let three = doc(p(t("a"), br(), t("   # x")))
        try expectEqual(md(three), "a\\\n   \\# x")
        try expectEqual(types(try parseMD(md(three))), ["paragraph"])
    }

    // MARK: Markdown writer — destinations, titles, alt text

    test("mut: a destination with a closing parenthesis is angle-bracketed") {
        let d = doc(p(linked("x", "a)b")))
        try expectEqual(md(d), "[x](<a)b>)")
        try expectEqual(try parseMD(md(d)), d)
    }

    test("mut: a backslash in a destination is doubled") {
        let d = doc(p(linked("x", #"a\b"#)))
        try expectEqual(md(d), #"[x](a\\b)"#)
        try expectEqual(try parseMD(md(d)), d)
    }

    test("mut: a backslash in an image's alt text is escaped") {
        let img = node("image", ["src": .string("i.png"), "alt": .string(#"a\b"#)])
        try expectEqual(md(doc(p(img))), #"![a\\b](i.png)"#)
        try expectEqual(try parseMD(md(doc(p(img)))), doc(p(img)))
    }

    test("mut: a link title holding a double quote is single-quoted") {
        let d = doc(p(linked("x", "u", title: #"say "hi""#)))
        try expectEqual(md(d), #"[x](u 'say "hi"')"#)
        try expectEqual(try parseMD(md(d)), d)
    }

    test("mut: an exclamation mark before a link is escaped") {
        let d = doc(p(t("wow!"), linked("x", "u")))
        try expectEqual(md(d), #"wow\![x](u)"#)
        try expectEqual(try parseMD(md(d)), d)
    }

    // MARK: Markdown writer — marks

    test("mut: bold that can't close before a letter is written as a tag") {
        // `**x.**a` isn't bold: the closing run follows punctuation and precedes
        // a letter, so it isn't right-flanking.
        let d = doc(p(marked("x.", "bold"), t("a")))
        try expectEqual(md(d), "<strong>x.</strong>a")
        try expectEqual(try parseMD(md(d)), d)
    }

    test("mut: a tab before a closing run moves outside it") {
        let d = doc(p(marked("a\t", "bold"), t("b")))
        try expectEqual(md(d), "**a**\tb")
    }

    test("mut: a leading tab moves outside an opening run") {
        let d = doc(p(t("a"), marked("\tb", "bold")))
        try expectEqual(md(d), "a\t**b**")
    }

    test("mut: a strike holding only a space keeps its delimiters") {
        let d = doc(p(t("a"), marked(" ", "strike"), t("b")))
        try expectEqual(md(d), "a~~ ~~b")
        try expectEqual(try parseMD(md(d)), d)
    }

    test("mut: a link and bold over the same text nest link outermost") {
        let d = doc(p(linked("a", "u", "bold")))
        try expectEqual(md(d), "[**a**](u)")
        try expectEqual(try parseMD(md(d)), d)
    }

    // MARK: Markdown writer — math

    test("mut: a dollar after an escaped backslash is escaped in inline math") {
        let math = node("inlineMath", ["latex": .string(#"a\\$b"#)])
        try expectEqual(md(doc(p(math))), #"$a\\\$b$"#)
    }

    test("mut: a display-math line starting '$$' is held back") {
        let d = doc(node("blockMath", ["latex": .string("a\n$$b")]))
        try expectEqual(md(d), "$$\na\n\\$$b\n$$")
        try expectEqual(try parseMD(md(d)), d)
    }

    test("mut: a display-math line already escaping its '$$' round-trips") {
        let d = doc(node("blockMath", ["latex": .string(#"\$$b"#)]))
        try expectEqual(md(d), "$$\n\\\\$$b\n$$")
        try expectEqual(try parseMD(md(d)), d)
    }

    // MARK: Markdown parser — emphasis

    test("mut: emphasis opens after punctuation before punctuation") {
        // CommonMark: `*` between `(` and `"` is left-flanking, so it opens.
        try expectEqual(try parseMD(#"(*"foo"*)"#), doc(p(t("("), em(#""foo""#), t(")"))))
    }

    test("mut: an underscore run opens when punctuation precedes it") {
        // CommonMark example: `foo-_(bar)_` is emphasis on `(bar)`.
        try expectEqual(try parseMD("foo-_(bar)_"), doc(p(t("foo-"), em("(bar)"))))
    }

    test("mut: the rule of three applies only to runs that can open and close") {
        // CommonMark example: `**foo*` is `*<em>foo</em>`.
        try expectEqual(try parseMD("**foo*"), doc(p(t("*"), em("foo"))))
        try expectEqual(try parseMD("*foo**"), doc(p(em("foo"), t("*"))))
    }

    // MARK: Markdown parser — links

    test("mut: text after a link title makes it not a link") {
        try expectEqual(hrefs(try parseMD(#"[a](b "t" x)"#)), [])
        try expectEqual(hrefs(try parseMD(#"[a](b "t")"#)), ["b"])
    }

    test("mut: an angle-bracketed destination can't span lines") {
        try expectEqual(hrefs(try parseMD("[a](<b\nc>)")), [])
    }

    test("mut: a destination nests parentheses exactly as deep as the limit") {
        let limit = MarkdownParser.maxLinkParenDepth
        let nested = { (n: Int) in String(repeating: "(", count: n) + "x" + String(repeating: ")", count: n) }
        try expectEqual(hrefs(try parseMD("[a](\(nested(limit)))")), [nested(limit)])
        try expectEqual(hrefs(try parseMD("[a](\(nested(limit + 1)))")), [])
    }

    test("mut: reference labels match case-insensitively") {
        try expectEqual(hrefs(try parseMD("[a][FOO]\n\n[foo]: /u")), ["/u"])
        try expectEqual(hrefs(try parseMD("[Foo]\n\n[fOO]: /v")), ["/v"])
    }

    // MARK: Markdown parser — tables

    test("mut: an escaped pipe at the end of a row stays in its cell") {
        let d = try parseMD("| a | b \\|\n| - | - |")
        try expectEqual(types(d), ["table"])
        let row = d.child(0).child(0)
        try expectEqual(row.childCount, 2)
        try expectEqual(row.child(1).textContent, "b |")
    }

    test("mut: a delimiter cell of only colons isn't one") {
        let d = try parseMD("| a |\n| : |")
        try expectEqual(types(d), ["paragraph"])
    }

    // MARK: Markdown parser — blocks

    test("mut: a setext underline indented four columns continues the paragraph") {
        // CommonMark example 87 (with `=`): the underline is paragraph text.
        let d = try parseMD("Foo\n    ===")
        try expectEqual(types(d), ["paragraph"])
    }

    test("mut: four spaces after a marker set the content column") {
        // `-    foo` puts content at column 5, so `  bar` is outside the item.
        let d = try parseMD("-    foo\n\n  bar")
        try expectEqual(types(d), ["bulletList", "paragraph"])
        try expectEqual(d.child(1).textContent, "bar")
    }

    test("mut: a nine-digit ordered marker is a list") {
        let d = try parseMD("123456789. x")
        try expectEqual(types(d), ["orderedList"])
        try expectEqual(d.child(0).attrs["order"], .int(123456789))
    }

    test("mut: only an ordered list starting at 1 interrupts a paragraph") {
        try expectEqual(types(try parseMD("a\n2. b")), ["paragraph"])
        try expectEqual(types(try parseMD("a\n1. b")), ["paragraph", "orderedList"])
    }

    test("mut: a backtick fence's info string can't hold a backtick") {
        try expectEqual(types(try parseMD("```a`\nfoo")), ["paragraph"])
    }

    test("mut: a longer closing fence closes a code block") {
        let d = try parseMD("```\ncode\n````\nafter")
        try expectEqual(d, doc(node("codeBlock", [:], [t("code")]), p("after")))
    }

    test("mut: a tab after a space reaches the next four-column stop") {
        // ` \tfoo` is indented four columns: indented code holding `foo`.
        let d = try parseMD(" \tfoo")
        try expectEqual(d, doc(node("codeBlock", [:], [t("foo")])))
    }

    // MARK: JSON

    test("mut: JSON writes a slash escaped and control characters as \\u00XX") {
        try expectEqual(String(decoding: try DocumentJSON.encode(.string("a/b")), as: UTF8.self), #""a\/b""#)
        try expectEqual(String(decoding: try DocumentJSON.encode(.string("\u{1F}\u{01}")), as: UTF8.self),
                        #""\u001f\u0001""#)
    }

    test("mut: JSON reads every short escape") {
        try expectEqual(try json(#""\b\f\n\r\t\/\\\"""#), .string("\u{08}\u{0C}\n\r\t/\\\""))
    }

    test("mut: JSON joins a surrogate pair and refuses a low surrogate leading") {
        try expectEqual(try json(#""\uD83D\uDE00""#), .string("😀"))
        try expectEqual(try json(#""\uDBFF\uDFFF""#), .string("\u{10FFFF}"))
        try expectThrows { _ = try json(#""\uDC00\uDC00""#) }
    }

    test("mut: JSON reads upper and lower case hex digits alike") {
        try expectEqual(try json(#""\u00E9\u00e9\u004A""#), .string("ééJ"))
    }

    test("mut: JSON refuses a leading zero") {
        try expectThrows { _ = try json("01") }
        try expectThrows { _ = try json("-01") }
        try expectEqual(try json("0"), .int(0))
        try expectEqual(try json("-0.5"), .double(-0.5))
    }

    test("mut: JSON reads Int.min as an integer") {
        try expectEqual(try json("-9223372036854775808"), .int(.min))
        try expectEqual(try json("9223372036854775807"), .int(.max))
    }

    test("mut: JSON reads a negative exponent") {
        try expectEqual(try json("1e-2"), .double(0.01))
        try expectEqual(try json("1E+2"), .double(100))
    }

    test("mut: JSON accepts one trailing comma in an object") {
        try expectEqual(try json(#"{"a":1,}"#), .object(["a": .int(1)]))
        try expectEqual(try json("[1,]"), .array([.int(1)]))
    }

    test("mut: JSON skips a UTF-8 byte-order mark") {
        try expectEqual(try DocumentJSON.parse(Data([0xEF, 0xBB, 0xBF] + Array("[1]".utf8))), .array([.int(1)]))
    }

    test("mut: JSON reads UTF-16LE without a byte-order mark") {
        let data = "[1]".data(using: .utf16LittleEndian)!
        try expectEqual(try DocumentJSON.parse(data), .array([.int(1)]))
    }

    test("mut: JSON nests exactly as deep as its limit and no deeper") {
        let limit = DocumentJSON.maxNestingDepth
        let arrays = { (n: Int) in String(repeating: "[", count: n) + String(repeating: "]", count: n) }
        _ = try json(arrays(limit))
        try expectThrows { _ = try json(arrays(limit + 1)) }
        let objects = { (n: Int) in String(repeating: #"{"a":"#, count: n - 1) + "{}" + String(repeating: "}", count: n - 1) }
        _ = try json(objects(limit))
        try expectThrows { _ = try json(objects(limit + 1)) }
    }

    test("mut: JSON keeps the first of two equal keys") {
        try expectEqual(try json(#"{"a":1,"a":2}"#), .object(["a": .int(1)]))
    }

    // MARK: URL and colour sanitizing

    test("mut: a space inside a scheme doesn't hide it") {
        try expectEqual(hrefs(try parseHTML(#"<p><a href="java script:alert(1)">x</a></p>"#)), [])
        try expectEqual(hrefs(try parseHTML("<p><a href=\"java\tscript:alert(1)\">x</a></p>")), [])
    }

    test("mut: a 'scheme' starting with a digit is a relative URL") {
        try expectEqual(hrefs(try parseHTML(#"<p><a href="1a:b">x</a></p>"#)), ["1a:b"])
    }

    test("mut: every allowed link scheme survives") {
        for href in ["http://a", "https://a", "mailto:a@b", "tel:1", "sms:1", "ftp://a", "ftps://a"] {
            try expectEqual(hrefs(try parseHTML("<p><a href=\"\(href)\">x</a></p>")), [href], href)
        }
    }

    test("mut: a base64 PNG data URL is a safe image source") {
        let d = try parseHTML(#"<p><img src="data:image/png;base64,AAAA"></p>"#)
        var srcs: [String] = []
        d.descendants { n, _, _, _ in
            if n.type.name == "image" { srcs.append(n.attrs["src"]?.stringValue ?? "") }
            return true
        }
        try expectEqual(srcs, ["data:image/png;base64,AAAA"])
    }

    test("mut: CSS colours in every accepted spelling") {
        for c in ["#f00", "#f00a", "#ff0000", "#ff0000aa", "rgb(10%, 20%, 30%)", "hsl(0 0% 0% / 50%)"] {
            try expectEqual(colors(try parseHTML("<p><span style=\"color:\(c)\">x</span></p>")), [c], c)
        }
    }

    test("mut: a CSS colour may be 64 characters but not 65") {
        let at64 = "rgb(0,0,0" + String(repeating: " ", count: 54) + ")"
        try expectEqual(at64.count, 64)
        try expectEqual(colors(try parseHTML("<p><span style=\"color:\(at64)\">x</span></p>")), [at64])
        let at65 = "rgb(0,0,0" + String(repeating: " ", count: 55) + ")"
        try expectEqual(colors(try parseHTML("<p><span style=\"color:\(at65)\">x</span></p>")), [])
    }

    // MARK: HTML

    test("mut: HTML escapes '>' in text") {
        try expectEqual(HTMLSerializer.serialize(doc(p("a>b<c&d"))), "<p>a&gt;b&lt;c&amp;d</p>")
    }

    test("mut: a font-weight of 500 is bold, 400 isn't") {
        try expectEqual(runs(try parseHTML(#"<p><span style="font-weight:500">x</span></p>"#)), ["x[bold]"])
        try expectEqual(runs(try parseHTML(#"<p><span style="font-weight:400">x</span></p>"#)), ["x[]"])
    }

    test("mut: a cell's align attribute is its alignment") {
        let d = try parseHTML(#"<table><tr><th align="center">a</th></tr></table>"#)
        try expectEqual(d.child(0).child(0).child(0).attrs["align"], .string("center"))
    }

    test("mut: Markdown caps a hex reference at six digits") {
        try expectEqual(try parseMD("&#x1234567;"), doc(p("&#x1234567;")))
        try expectEqual(try parseMD("&#x10FFFF;"), doc(p("\u{10FFFF}")))
    }

    test("mut: a zero character reference is the replacement character") {
        try expectEqual(try parseHTML("<p>a&#0;b</p>"), doc(p("a\u{FFFD}b")))
    }

    test("mut: hex references read every hex letter") {
        try expectEqual(try parseHTML("<p>&#x6f;&#x6F;&#x61;</p>"), doc(p("ooa")))
    }
}


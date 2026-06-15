import Foundation
import DocumentModel
import EditorSerialization
import TestHarness

let collector = TestCollector()
func test(_ name: String, _ body: @escaping @Sendable () throws -> Void) { collector.test(name, body) }

let cellAttrs: [String: AttributeSpec] = [
    "colspan": AttributeSpec(default: .int(1)),
    "rowspan": AttributeSpec(default: .int(1)),
    "colwidth": AttributeSpec(default: .null),
]

let schema: Schema = {
    let nodes: [(String, NodeSpec)] = [
        ("doc", NodeSpec(content: "block+")),
        ("paragraph", NodeSpec(content: "inline*", group: "block")),
        ("blockquote", NodeSpec(content: "block+", group: "block", defining: true)),
        ("heading", NodeSpec(content: "inline*", group: "block", attrs: ["level": AttributeSpec(default: .int(1))], defining: true)),
        ("codeBlock", NodeSpec(content: "text*", marks: "", group: "block", code: true, defining: true)),
        ("horizontalRule", NodeSpec(group: "block")),
        ("text", NodeSpec(group: "inline")),
        ("hardBreak", NodeSpec(group: "inline", inline: true)),
        ("image", NodeSpec(group: "inline", inline: true, atom: true, attrs: ["src": AttributeSpec(), "alt": AttributeSpec(default: .null), "title": AttributeSpec(default: .null)])),
        ("wikiLink", NodeSpec(group: "inline", inline: true, atom: true, attrs: ["target": AttributeSpec(), "label": AttributeSpec(default: .null)], leafText: { $0.attrs["label"]?.stringValue ?? $0.attrs["target"]?.stringValue ?? "" })),
        ("mention", NodeSpec(group: "inline", inline: true, atom: true, attrs: ["id": AttributeSpec(), "label": AttributeSpec(default: .null)], leafText: { "@" + ($0.attrs["label"]?.stringValue ?? $0.attrs["id"]?.stringValue ?? "") })),
        ("bulletList", NodeSpec(content: "listItem+", group: "block")),
        ("orderedList", NodeSpec(content: "listItem+", group: "block", attrs: ["order": AttributeSpec(default: .int(1))])),
        ("listItem", NodeSpec(content: "paragraph block*", defining: true)),
        ("taskList", NodeSpec(content: "taskItem+", group: "block")),
        ("taskItem", NodeSpec(content: "paragraph block*", attrs: ["checked": AttributeSpec(default: .bool(false))], defining: true)),
        ("table", NodeSpec(content: "tableRow+", group: "block", isolating: true)),
        ("tableRow", NodeSpec(content: "(tableCell | tableHeader)+")),
        ("tableCell", NodeSpec(content: "block+", attrs: cellAttrs, isolating: true)),
        ("tableHeader", NodeSpec(content: "block+", attrs: cellAttrs, isolating: true)),
    ]
    let marks: [(String, MarkSpec)] = [
        ("bold", MarkSpec()), ("italic", MarkSpec()), ("strike", MarkSpec()), ("highlight", MarkSpec()),
        ("underline", MarkSpec()),
        ("subscript", MarkSpec(excludes: "subscript superscript")),
        ("superscript", MarkSpec(excludes: "subscript superscript")),
        ("textColor", MarkSpec(attrs: ["color": AttributeSpec(default: .null)])),
        ("backgroundColor", MarkSpec(attrs: ["color": AttributeSpec(default: .null)])),
        ("code", MarkSpec(excludes: "_")),
        ("link", MarkSpec(attrs: ["href": AttributeSpec(), "title": AttributeSpec(default: .null)], inclusive: false)),
    ]
    return try! Schema(nodes: nodes, marks: marks, topNode: "doc")
}()

func node(_ type: String, _ attrs: Attrs = [:], _ content: [Node] = []) -> Node {
    try! schema.node(type, attrs, content: Fragment.from(content))
}
func doc(_ c: Node...) -> Node { node("doc", [:], c) }
func p(_ c: Node...) -> Node { node("paragraph", [:], c) }
func p(_ s: String) -> Node { node("paragraph", [:], s.isEmpty ? [] : [t(s)]) }
func h(_ l: Int, _ s: String) -> Node { node("heading", ["level": .int(l)], [t(s)]) }
func t(_ s: String) -> Node { schema.text(s) }
func strong(_ s: String) -> Node { schema.text(s, [schema.mark("bold")]) }
func em(_ s: String) -> Node { schema.text(s, [schema.mark("italic")]) }

// MARK: - JSON

test("JSON round-trip") {
    let d = doc(h(2, "Title"), p(t("Hello "), strong("world")), node("bulletList", [:], [node("listItem", [:], [p("item")])]))
    let json = try DocumentJSON.string(d)
    let back = try DocumentJSON.decode(schema, json)
    try expectEqual(d, back)
}

test("JSON is valid parseable JSON") {
    let d = doc(p("hi"))
    let data = try DocumentJSON.encode(d)
    let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    try expectNotNil(obj)
    try expectEqual(obj?["type"] as? String, "doc")
}

// MARK: - HTML

test("HTML serialize basic doc") {
    let d = doc(h(1, "Hi"), p(t("a "), strong("b"), t(" "), em("c")))
    let html = HTMLSerializer.serialize(d)
    try expectEqual(html, "<h1>Hi</h1><p>a <strong>b</strong> <em>c</em></p>")
}

test("HTML round-trip (headings, marks, lists)") {
    let d = doc(
        h(2, "Title"),
        p(t("plain "), strong("bold"), t(" "), em("italic")),
        node("bulletList", [:], [
            node("listItem", [:], [p("one")]),
            node("listItem", [:], [p("two")]),
        ]))
    let html = HTMLSerializer.serialize(d)
    let back = try HTMLParser.parse(html, schema: schema)
    try expectEqual(back, d)
}

test("HTML round-trip with image + blockquote") {
    let d = doc(
        node("blockquote", [:], [p("quoted")]),
        p(t("see "), node("image", ["src": .string("c.png"), "alt": .string("cat")])))
    let html = HTMLSerializer.serialize(d)
    let back = try HTMLParser.parse(html, schema: schema)
    try expectEqual(back, d)
}

test("HTML highlight round-trip (<mark>)") {
    let d = doc(p(t("plain "), schema.text("lit", [schema.mark("highlight")]), t(" end")))
    let html = HTMLSerializer.serialize(d)
    try expect(html.contains("<mark>lit</mark>"), "expected <mark> tag, got: \(html)")
    let back = try HTMLParser.parse(html, schema: schema)
    try expectEqual(back, d)
}

test("HTML underline round-trip (<u>)") {
    let d = doc(p(t("a "), schema.text("u", [schema.mark("underline")])))
    let html = HTMLSerializer.serialize(d)
    try expect(html.contains("<u>u</u>"), "got: \(html)")
    try expectEqual(try HTMLParser.parse(html, schema: schema), d)
}

test("HTML subscript/superscript round-trip (<sub>/<sup>)") {
    let d = doc(p(t("H"), schema.text("2", [schema.mark("subscript")]), t("O, e=mc"),
                  schema.text("2", [schema.mark("superscript")])))
    let html = HTMLSerializer.serialize(d)
    try expect(html.contains("<sub>2</sub>"), "got: \(html)")
    try expect(html.contains("<sup>2</sup>"), "got: \(html)")
    try expectEqual(try HTMLParser.parse(html, schema: schema), d)
}

test("HTML textColor round-trip (span style color)") {
    let d = doc(p(t("a "), schema.text("red", [schema.mark("textColor", ["color": .string("#ff0000")])])))
    let html = HTMLSerializer.serialize(d)
    try expect(html.contains("style=\"color:#ff0000\""), "got: \(html)")
    try expectEqual(try HTMLParser.parse(html, schema: schema), d)
}

test("HTML backgroundColor round-trip (span style background-color)") {
    let d = doc(p(schema.text("hi", [schema.mark("backgroundColor", ["color": .string("yellow")])])))
    let html = HTMLSerializer.serialize(d)
    try expect(html.contains("style=\"background-color:yellow\""), "got: \(html)")
    try expectEqual(try HTMLParser.parse(html, schema: schema), d)
}

test("HTML crossed close tag doesn't corrupt color marks") {
    // The stray </strong> must be ignored, not pop the textColor scope.
    let d = try HTMLParser.parse("<p><span style=\"color:red\">a</strong>b</span>c</p>", schema: schema)
    try expectEqual(d.textContent, "abc")
    let tc = schema.marks["textColor"]!
    try expect(d.rangeHasMark(1, 3, tc), "a and b stay colored despite the stray </strong>")
    try expect(!d.rangeHasMark(3, 4, tc), "c is not colored")
}

test("HTML stray close tag is ignored") {
    let d = try HTMLParser.parse("<p>x</em>y</p>", schema: schema)
    try expectEqual(d.textContent, "xy")
    try expect(!d.rangeHasMark(1, 3, schema.marks["italic"]!), "no italic from a stray </em>")
}

test("HTML crossed bold/italic tags degrade without corruption") {
    let d = try HTMLParser.parse("<p><strong><em>a</strong>b</em></p>", schema: schema)
    try expectEqual(d.textContent, "ab")
    let bold = schema.marks["bold"]!, italic = schema.marks["italic"]!
    try expect(d.rangeHasMark(1, 2, bold) && d.rangeHasMark(1, 2, italic), "a is bold+italic")
    try expect(d.rangeHasMark(2, 3, italic), "b keeps italic (em outlives the crossed </strong>)")
    try expect(!d.rangeHasMark(2, 3, bold), "b is not bold")
}

test("HTML mismatched close tag leaves the scope open (browser-like)") {
    // </strong> doesn't match the <b> scope, so bold continues across the block.
    let d = try HTMLParser.parse("<p><b>a</strong>b</p>", schema: schema)
    try expectEqual(d.textContent, "ab")
    try expect(d.rangeHasMark(1, 3, schema.marks["bold"]!), "bold spans a and b")
}

test("HTML well-nested marks still round-trip after the refactor") {
    let d = doc(p(t("a"), schema.text("b", [schema.mark("bold"), schema.mark("italic")]), t("c")))
    try expectEqual(try HTMLParser.parse(HTMLSerializer.serialize(d), schema: schema), d)
}

test("HTML color: 'color' style does not match 'background-color'") {
    // Parsing a background-color span must NOT also apply a textColor mark.
    let back = try HTMLParser.parse("<p><span style=\"background-color: blue\">x</span></p>", schema: schema)
    let expected = doc(p(schema.text("x", [schema.mark("backgroundColor", ["color": .string("blue")])])))
    try expectEqual(back, expected)
}

test("HTML mention round-trip (span data-mention)") {
    let m = node("mention", ["id": .string("jose"), "label": .string("José")])
    let d = doc(p(t("hi "), m))
    let html = HTMLSerializer.serialize(d)
    try expect(html.contains("data-mention=\"jose\""), "got: \(html)")
    try expectEqual(try HTMLParser.parse(html, schema: schema), d)
}

test("HTML wikiLink round-trip") {
    let wl = node("wikiLink", ["target": .string("Home"), "label": .string("Start")])
    let d = doc(p(t("go "), wl))
    let html = HTMLSerializer.serialize(d)
    let back = try HTMLParser.parse(html, schema: schema)
    try expectEqual(back, d)
}

// MARK: - HTML paste from Apple Notes (clipboard interchange)

// Apple Notes (and most apps) put `<table><tbody><tr><td>` with colspan/rowspan,
// `<ul>/<ol>/<li>` (incl. nesting), and checklists as `<li>`s with checkboxes on
// the pasteboard's public.html. These parse into our table/list/task nodes.

// ul/ol/li live in PMMarkdown.swift, shared with these tests.
func tdN(_ attrs: Attrs, _ c: Node...) -> Node { node("tableCell", attrs, c) }
func thN(_ attrs: Attrs, _ c: Node...) -> Node { node("tableHeader", attrs, c) }
func trN(_ c: Node...) -> Node { node("tableRow", [:], c) }
func tableN(_ c: Node...) -> Node { node("table", [:], c) }
func taskListN(_ c: Node...) -> Node { node("taskList", [:], c) }
func taskItemN(_ checked: Bool, _ c: Node...) -> Node { node("taskItem", ["checked": .bool(checked)], c) }

test("HTML paste: Apple Notes table (tbody unwrapped)") {
    let html = "<table><tbody><tr><td>a</td><td>b</td></tr><tr><td>c</td><td>d</td></tr></tbody></table>"
    let back = try HTMLParser.parse(html, schema: schema)
    let want = doc(tableN(trN(tdN([:], p("a")), tdN([:], p("b"))), trN(tdN([:], p("c")), tdN([:], p("d")))))
    try expectEqual(back, want)
}

test("HTML paste: table with colspan/rowspan + th") {
    let html = "<table><tbody><tr><th colspan=\"2\">H</th></tr><tr><td>a</td><td>b</td></tr></tbody></table>"
    let back = try HTMLParser.parse(html, schema: schema)
    let want = doc(tableN(trN(thN(["colspan": .int(2)], p("H"))), trN(tdN([:], p("a")), tdN([:], p("b")))))
    try expectEqual(back, want)
}

test("HTML paste: bullet + ordered lists") {
    try expectEqual(try HTMLParser.parse("<ul><li>a</li><li>b</li></ul>", schema: schema),
                    doc(ul(li(p("a")), li(p("b")))))
    try expectEqual(try HTMLParser.parse("<ol><li>x</li></ol>", schema: schema),
                    doc(ol(li(p("x")))))
}

test("HTML paste: nested bullet list") {
    let html = "<ul><li>a<ul><li>b</li></ul></li></ul>"
    let back = try HTMLParser.parse(html, schema: schema)
    try expectEqual(back, doc(ul(li(p("a"), ul(li(p("b")))))))
}

test("HTML paste: Apple Notes checklist (input checkboxes) → task list") {
    let html = "<ul><li><input type=\"checkbox\" checked> done</li><li><input type=\"checkbox\"> todo</li></ul>"
    let back = try HTMLParser.parse(html, schema: schema)
    let want = doc(taskListN(taskItemN(true, p("done")), taskItemN(false, p("todo"))))
    try expectEqual(back, want)
}

test("HTML task list round-trip (data-type + data-checked)") {
    let d = doc(taskListN(taskItemN(true, p("a")), taskItemN(false, p("b"))))
    let html = HTMLSerializer.serialize(d)
    try expect(html.contains("data-type=\"taskList\"") && html.contains("type=\"checkbox\""), "got: \(html)")
    try expectEqual(try HTMLParser.parse(html, schema: schema), d)
}

test("HTML table round-trip with spans") {
    let d = doc(tableN(trN(tdN(["colspan": .int(2)], p("a"))), trN(tdN([:], p("b")), tdN(["rowspan": .int(2)], p("c")))))
    let html = HTMLSerializer.serialize(d)
    try expectEqual(try HTMLParser.parse(html, schema: schema), d)
}

test("HTML paste: full document (html/head/style/body wrapper)") {
    // WebKit apps like Apple Notes put a full HTML document on the pasteboard.
    let html = "<html><head><meta charset=\"utf-8\"><style>td { width: 50px; }</style></head>"
        + "<body><table><tbody><tr><td>a</td><td>b</td></tr></tbody></table><ul><li>x</li></ul></body></html>"
    let back = try HTMLParser.parse(html, schema: schema)
    let want = doc(tableN(trN(tdN([:], p("a")), tdN([:], p("b")))), ul(li(p("x"))))
    try expectEqual(back, want)
}

test("HTML paste: <div> lines become paragraphs, marks preserved") {
    let back = try HTMLParser.parse("<div>plain <b>bold</b></div><div>second</div>", schema: schema)
    let want = doc(p(t("plain "), strong("bold")), p("second"))
    try expectEqual(back, want)
}

test("HTML paste: comment closed by --!> doesn't swallow the rest of the doc") {
    // The HTML spec treats '--!>' as (incorrectly) closing a comment; content
    // after it must survive.
    try expectEqual(try HTMLParser.parse("<!-- c --!><p>hi</p>", schema: schema), doc(p("hi")))
}

test("HTML paste: abruptly-closed empty comments don't swallow content") {
    // Per spec, <!--> and <!---> are complete (empty) comments.
    try expectEqual(try HTMLParser.parse("<p>a</p><!--><p>b</p>", schema: schema), doc(p("a"), p("b")))
    try expectEqual(try HTMLParser.parse("<p>a</p><!---><p>b</p>", schema: schema), doc(p("a"), p("b")))
}

test("HTML paste: CDATA section containing '>' is skipped whole") {
    let back = try HTMLParser.parse("<p>a</p><![CDATA[x > y]]><p>b</p>", schema: schema)
    try expectEqual(back, doc(p("a"), p("b")))
}

test("HTML entities: &nbsp; and numeric references decode") {
    let back = try HTMLParser.parse("<p>a&nbsp;b &#65;&#x42; &amp;lt;</p>", schema: schema)
    try expectEqual(back, doc(p("a\u{00A0}b AB &lt;")))
}

test("HTML entities: invalid references stay literal") {
    // Out-of-range, surrogate, unknown-name, and empty refs must pass through.
    let back = try HTMLParser.parse("<p>&#x110000; &#xD800; &bogus; &; & end&</p>", schema: schema)
    try expectEqual(back, doc(p("&#x110000; &#xD800; &bogus; &; & end&")))
}

test("HTML tokenizer: malformed fragments never crash") {
    // Robustness only — output shape is unspecified for these, crash-freedom isn't.
    let cases = [
        "<p", "<", "<>", "</", "</p", "<p attr=\"unterminated>x", "x > y",
        "&", "&;", "&#;", "&#x;", "a & b", "<b>x", "<!", "<?", "<![CDATA[",
        "<!-- unterminated", "<i><b></i></b>", "<p =\"v\">x</p>", "<p/ >x",
        String(repeating: "<div>", count: 200) + "x",
    ]
    for c in cases { _ = try? HTMLParser.parse(c, schema: schema) }
    // Regression for the trap this test originally caught: an unterminated open
    // tag as the final token must recover, keeping its content.
    try expectEqual(try HTMLParser.parse("<p>hi", schema: schema), doc(p("hi")))
}

test("HTML paste: Apple Notes via RTF→Cocoa HTML Writer (doctype + p/span/ul)") {
    // The exact shape NSAttributedString emits for Apple Notes' RTF: a <!DOCTYPE>,
    // a <head><style>, and <p class><span class> / <ul class><li class> bodies.
    let html = """
    <!DOCTYPE html PUBLIC "-//W3C//DTD HTML 4.01//EN" "http://www.w3.org/TR/html4/strict.dtd">
    <html><head><meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
    <style type="text/css">p.p1 {font: 13.0px} span.s1 {font-weight: normal}</style></head>
    <body>
    <p class="p1"><span class="s1">Horses</span></p>
    <ul class="ul1">
    <li class="li1"><span class="s1">A</span></li>
    <li class="li1"><span class="s1">B</span></li>
    </ul>
    </body></html>
    """
    let back = try HTMLParser.parse(html, schema: schema)
    try expectEqual(back, doc(p("Horses"), ul(li(p("A")), li(p("B")))))
}

// MARK: - Apple Notes private checklist proto

// A real `com.apple.notes.richtext` inner Note protobuf captured from Apple Notes:
// a checklist "Beta / Gamama / Alpha" with only "Alpha" checked.
let notesChecklistFixture = "EhIKQmV0YQpHYW1hbWEKQWxwaGEqGAgBEhQYAUoQ3/3oLyiCTQiDReBte/ldESowCAUSLAhnGAEqFAoQID0UFXDfTSS1v25CmdbMtxAAShDuBdNoRK1MOoVrDDtMB0jJKjAIBxIsCGcYASoUChDK0BmjJgdG87rTNqtA8ZCeEABKEDhfWYQeqEbmowRb/i6aKiMqLggFEioIZyoUChACZIfg7gFA5q/wsLTlnGAaEAFKEMo4QinjNkT7mlovqYQzlms="

test("Apple Notes proto: recovers checklist lines in order + checked state") {
    let data = Data(base64Encoded: notesChecklistFixture)!
    let r = AppleNotesPasteboard.parseNoteProto(data)
    try expectNotNil(r)
    try expectEqual(r?.map { $0.text }, ["Beta", "Gamama", "Alpha"])
    try expectEqual(r?.map { $0.checked }, [false, false, true])
}

test("Apple Notes proto: garbage / drift returns nil (graceful)") {
    try expect(AppleNotesPasteboard.parseNoteProto(Data([0xff, 0x00, 0x12, 0x99, 0x7f])) == nil)
    try expect(AppleNotesPasteboard.parseNoteProto(Data()) == nil)
    // Valid proto shape but no checklist style → nil (so caller falls back).
    try expect(AppleNotesPasteboard.parseNoteProto(Data([0x12, 0x03, 0x41, 0x42, 0x43])) == nil)
}

test("Apple Notes proto: matchingText guards checklist recovery (whole note vs selection)") {
    let data = Data(base64Encoded: notesChecklistFixture)!
    // A selection paste whose text doesn't match the whole note → no proto lines.
    try expect(AppleNotesPasteboard.parseNoteProto(data, matchingText: "only part of the note") == nil)
    // Matching text (modulo whitespace) keeps the recovery active.
    try expectEqual(AppleNotesPasteboard.parseNoteProto(data, matchingText: "Beta Gamama Alpha")?.count, 3)
}

test("Apple Notes proto: hostile varint lengths return nil, never trap") {
    // note_text (field 2, wire 2) claiming length 2^63 — exceeds Int.max.
    let huge = Data([0x12] + Array(repeating: 0x80, count: 9) + [0x01])
    try expect(AppleNotesPasteboard.parseNoteProto(huge) == nil)
    // Length exactly Int.max — would overflow `i + len` if added unchecked.
    let intMax = Data([0x12, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F])
    try expect(AppleNotesPasteboard.parseNoteProto(intMax) == nil)
    // AttributeRun (field 5) whose length field (field 1) is Int.max — would
    // overflow `pos + length` when laying runs over the text if unclamped.
    let runLen = Data([0x12, 0x02, 0x61, 0x0A,  // note_text "a\n"
                       0x2A, 0x0A, 0x08, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F])
    _ = AppleNotesPasteboard.parseNoteProto(runLen) // must not crash
}

// MARK: - Markdown

test("Markdown serialize") {
    let d = doc(h(2, "Title"), p(t("a "), strong("b")), node("bulletList", [:], [node("listItem", [:], [p("x")]), node("listItem", [:], [p("y")])]))
    let md = MarkdownSerializer.serialize(d)
    try expectEqual(md, "## Title\n\na **b**\n\n- x\n- y")
}

test("Node.toMarkdown() convenience matches the serializer") {
    let d = doc(h(2, "Title"), p(t("a "), strong("b")))
    try expectEqual(d.toMarkdown(), MarkdownSerializer.serialize(d))
    try expectEqual(d.toMarkdown(), "## Title\n\na **b**")
}

test("Node JSON string helpers round-trip") {
    let d = doc(h(1, "Title"), p(t("hello "), strong("world")))
    let json = try d.toJSONString()
    let back = try Node.fromJSON(json, schema: schema)
    try expectEqual(back, d)
}

test("Markdown round-trip (headings, bold, italic, code)") {
    let d = doc(
        h(1, "Doc"),
        p(t("some "), strong("bold"), t(" and "), em("italic"), t(" and "), schema.text("code", [schema.mark("code")])))
    let md = MarkdownSerializer.serialize(d)
    let back = try MarkdownParser.parse(md, schema: schema)
    try expectEqual(back, d)
}

test("Markdown highlight round-trip (==text==)") {
    let d = doc(p(t("plain "), schema.text("lit", [schema.mark("highlight")]), t(" end")))
    let md = MarkdownSerializer.serialize(d)
    try expectEqual(md, "plain ==lit== end")
    let back = try MarkdownParser.parse(md, schema: schema)
    try expectEqual(back, d)
}

test("Markdown round-trip (blockquote, list, hr)") {
    let d = doc(
        node("blockquote", [:], [p("quote")]),
        node("bulletList", [:], [node("listItem", [:], [p("a")]), node("listItem", [:], [p("b")])]),
        node("horizontalRule"))
    let md = MarkdownSerializer.serialize(d)
    let back = try MarkdownParser.parse(md, schema: schema)
    try expectEqual(back, d)
}

test("Markdown link + wikiLink round-trip") {
    let link = schema.text("PM", [schema.mark("link", ["href": .string("https://prosemirror.net")])])
    let wl = node("wikiLink", ["target": .string("Page")])
    let d = doc(p(t("see "), link, t(" and "), wl))
    let md = MarkdownSerializer.serialize(d)
    let back = try MarkdownParser.parse(md, schema: schema)
    try expectEqual(back, d)
}

test("Markdown code fence round-trip") {
    let d = doc(node("codeBlock", [:], [t("let x = 1\nprint(x)")]))
    let md = MarkdownSerializer.serialize(d)
    let back = try MarkdownParser.parse(md, schema: schema)
    try expectEqual(back, d)
}

test("property: random docs round-trip through HTML and JSON") {
    var rngState: UInt64 = 0xFEED_FACE
    func rnd(_ n: Int) -> Int {
        rngState ^= rngState << 13; rngState ^= rngState >> 7; rngState ^= rngState << 17
        return Int(rngState % UInt64(max(1, n)))
    }
    let words = ["one", "two&", "a<b", "x>y", "hé", "longer word"]
    func rndText() -> String {
        (0...rnd(2)).map { _ in words[rnd(words.count)] }.joined(separator: " ")
    }
    func rndMarks() -> [Mark] {
        // code excludes everything else; otherwise a random subset.
        if rnd(8) == 0 { return [schema.mark("code")] }
        var marks: [Mark] = []
        if rnd(3) == 0 { marks.append(schema.mark("bold")) }
        if rnd(3) == 0 { marks.append(schema.mark("italic")) }
        if rnd(4) == 0 { marks.append(schema.mark("strike")) }
        if rnd(4) == 0 { marks.append(schema.mark("underline")) }
        if rnd(4) == 0 { marks.append(schema.mark("highlight")) }
        if rnd(5) == 0 { marks.append(schema.mark("link", ["href": .string("https://x.dev/\(rnd(100))")])) }
        return marks
    }
    func rndInline() -> [Node] {
        var out: [Node] = []
        for _ in 0...rnd(2) {
            switch rnd(8) {
            case 0: out.append(node("image", ["src": .string("img\(rnd(9)).png"), "alt": .string("alt")]))
            case 1: out.append(node("wikiLink", ["target": .string("Page\(rnd(9))"), "label": .string("L\(rnd(9))")]))
            case 2: out.append(node("mention", ["id": .string("id\(rnd(9))"), "label": .string("M\(rnd(9))")]))
            case 3: out.append(node("hardBreak"))
            default: out.append(schema.text(rndText(), rndMarks()))
            }
        }
        return out
    }
    func rndPara() -> Node { node("paragraph", [:], rndInline()) }
    func rndBlock(_ depth: Int) -> Node {
        switch rnd(depth > 0 ? 8 : 6) {
        case 0: return node("heading", ["level": .int(1 + rnd(6))], [schema.text(rndText())])
        case 1: return node("codeBlock", [:], [schema.text(rndText())])
        case 2: return node("horizontalRule")
        case 3: return node("bulletList", [:], (0...rnd(2)).map { _ in
            node("listItem", [:], [rndPara()])
        })
        case 4: return node("taskList", [:], (0...rnd(2)).map { _ in
            node("taskItem", ["checked": .bool(rnd(2) == 0)], [rndPara()])
        })
        case 5: return rndPara()
        case 6: return node("blockquote", [:], (0...rnd(1)).map { _ in rndBlock(depth - 1) })
        default: return node("table", [:], (0...rnd(1)).map { _ in
            node("tableRow", [:], (0...1).map { _ in node("tableCell", [:], [rndPara()]) })
        })
        }
    }

    for round in 0..<60 {
        let d = node("doc", [:], (0...rnd(3)).map { _ in rndBlock(2) })
        // HTML round-trip.
        let html = HTMLSerializer.serialize(d)
        let viaHTML = try HTMLParser.parse(html, schema: schema)
        try expectEqual(viaHTML, d, "HTML round \(round): \(html)")
        // JSON round-trip.
        let json = try DocumentJSON.string(d)
        try expectEqual(try DocumentJSON.decode(schema, json), d, "JSON round \(round)")
    }
}

registerProseTests()

registerPMMarkdownTests()
registerAppleNotesDocTests()

TestSuite.main("EditorSerializationTests", collector.all)

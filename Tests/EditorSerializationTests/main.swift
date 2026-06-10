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
    for c in cases {
        try? c.write(toFile: "/tmp/html-fuzz-case.txt", atomically: true, encoding: .utf8)
        _ = try? HTMLParser.parse(c, schema: schema)
    }
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

registerProseTests()

registerPMMarkdownTests()
registerAppleNotesDocTests()

TestSuite.main("EditorSerializationTests", collector.all)

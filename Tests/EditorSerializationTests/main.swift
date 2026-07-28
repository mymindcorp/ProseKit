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
        ("image", NodeSpec(group: "inline", inline: true, atom: true, attrs: ["src": AttributeSpec(), "alt": AttributeSpec(default: .null), "title": AttributeSpec(default: .null), "width": AttributeSpec(default: .null), "height": AttributeSpec(default: .null)])),
        ("wikiLink", NodeSpec(group: "inline", inline: true, atom: true, attrs: ["target": AttributeSpec(), "label": AttributeSpec(default: .null)], leafText: { $0.attrs["label"]?.stringValue ?? $0.attrs["target"]?.stringValue ?? "" })),
        ("mention", NodeSpec(group: "inline", inline: true, atom: true, attrs: ["id": AttributeSpec(), "label": AttributeSpec(default: .null)], leafText: { "@" + ($0.attrs["label"]?.stringValue ?? $0.attrs["id"]?.stringValue ?? "") })),
        ("bulletList", NodeSpec(content: "listItem+", group: "block")),
        ("orderedList", NodeSpec(content: "listItem+", group: "block", attrs: ["order": AttributeSpec(default: .int(1))])),
        ("listItem", NodeSpec(content: "paragraph block*", defining: true)),
        ("taskList", NodeSpec(content: "taskItem+", group: "block")),
        ("taskItem", NodeSpec(content: "paragraph block*", attrs: ["checked": AttributeSpec(default: .bool(false))], defining: true)),
        ("details", NodeSpec(content: "detailsSummary detailsContent", group: "block", attrs: ["open": AttributeSpec(default: .bool(false))], defining: true, isolating: true)),
        ("detailsSummary", NodeSpec(content: "inline*", selectable: false, defining: true, isolating: true)),
        ("detailsContent", NodeSpec(content: "block+", selectable: false, defining: true)),
        ("inlineMath", NodeSpec(group: "inline", inline: true, atom: true, attrs: ["latex": AttributeSpec(default: .string(""))], leafText: { "$" + ($0.attrs["latex"]?.stringValue ?? "") + "$" })),
        ("blockMath", NodeSpec(group: "block", atom: true, attrs: ["latex": AttributeSpec(default: .string(""))], leafText: { "$$" + ($0.attrs["latex"]?.stringValue ?? "") + "$$" })),
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

test("HTML: an image's size model round-trips") {
    // `width`/`height` are the image's display size in points. Either can stand
    // alone — the renderer derives the other from the aspect ratio — so all four
    // combinations have to survive the trip.
    let sizes: [(Attrs, String)] = [
        ([:], ""),
        (["width": .int(320)], " width=\"320\""),
        (["height": .int(240)], " height=\"240\""),
        (["width": .int(320), "height": .int(240)], " width=\"320\" height=\"240\""),
    ]
    for (size, expected) in sizes {
        var attrs: Attrs = ["src": .string("a.png")]
        attrs.merge(size) { _, new in new }
        let d = doc(p(node("image", attrs)))
        let html = HTMLSerializer.serialize(d)
        try expectEqual(html, "<p><img src=\"a.png\"\(expected)></p>")
        try expectEqual(try HTMLParser.parse(html, schema: schema), d, "\(size) didn't come back")
    }
}

test("HTML: a non-numeric image size is ignored rather than stored") {
    // Real markup carries `width="50%"` and `width="auto"`; neither is a point
    // value, and storing one would make the renderer size from nonsense.
    for value in ["50%", "auto", "", "abc", "-10"] {
        let d = try HTMLParser.parse("<p><img src=\"a.png\" width=\"\(value)\"></p>", schema: schema)
        try d.check()
        let image = d.child(0).child(0)
        try expectEqual(image.type.name, "image")
        if value == "-10" {
            // Negative numbers do parse as ints; the renderer clamps them.
            try expectEqual(image.attrs["width"], .int(-10))
        } else {
            try expectEqual(image.attrs["width"], .null, "\(value) should not become a width")
        }
    }
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

// MARK: - Untrusted input

/// The href of the first link mark in a document, or nil if nothing is linked.
private func firstHref(_ d: Node) -> String? {
    var found: String?
    d.descendants { node, _, _, _ in
        if found == nil, let mark = node.marks.first(where: { $0.type.name == "link" }) {
            found = mark.attrs["href"]?.stringValue ?? ""
        }
        return found == nil
    }
    return found
}

/// Every node type name appearing in a document.
private func nodeNames(_ d: Node) -> Set<String> {
    var names: Set<String> = []
    d.descendants { node, _, _, _ in names.insert(node.type.name); return true }
    return names
}

test("HTML: script-bearing elements are dropped with their content") {
    for tag in ["script", "style", "iframe", "object", "embed", "applet", "svg", "noscript", "template"] {
        let html = "<p>before</p><\(tag)>alert(1)</\(tag)><p>after</p>"
        let d = try HTMLParser.parse(html, schema: schema)
        try expect(!d.textContent.contains("alert(1)"), "<\(tag)> content leaked: \(d.textContent)")
        try expectEqual(d.textContent, "beforeafter", "surrounding content survives")
    }
    // Case and whitespace in the tag must not evade the filter.
    let shouty = try HTMLParser.parse("<p>a</p><SCRIPT >alert(1)</SCRIPT><p>b</p>", schema: schema)
    try expect(!shouty.textContent.contains("alert(1)"), shouty.textContent)
}

test("HTML tokenizer: a quoted attribute may contain '>'") {
    // The tag ends at the first unquoted ">". Ending it at a quoted one splits
    // the attribute and spills the remainder into the document as text.
    let d = try HTMLParser.parse("<p><a href=\"https://x.test/a?b=1>2\" title=\"a>b\">link</a> tail</p>",
                                 schema: schema)
    try expectEqual(d.textContent, "link tail")
    try expectEqual(firstHref(d), "https://x.test/a?b=1>2")
    try expectEqual(try HTMLParser.parse("<p title=\"a>b\">x</p>", schema: schema), doc(p("x")))
}

test("HTML: script URLs never become links") {
    let hostile = [
        "javascript:alert(1)",
        "JaVaScRiPt:alert(1)",
        "  javascript:alert(1)",
        "java\tscript:alert(1)",       // browsers strip control chars before the scheme
        "java\nscript:alert(1)",
        "&#106;avascript:alert(1)",    // entity-encoded 'j', decoded by the tokenizer
        "vbscript:msgbox(1)",
        "data:text/html,<script>alert(1)</script>",
    ]
    for href in hostile {
        let d = try HTMLParser.parse("<p><a href=\"\(href)\">click</a></p>", schema: schema)
        try expectNil(firstHref(d))
        try expectEqual(d.textContent, "click", "the text survives, only the link is dropped")
    }
}

test("HTML: ordinary links are untouched") {
    for href in ["https://example.com/a?b=1&c=2", "http://x.test", "mailto:a@b.test",
                 "tel:+15551234", "/relative/path", "../up", "notes/a:b", "#anchor"] {
        let d = try HTMLParser.parse("<p><a href=\"\(href)\">t</a></p>", schema: schema)
        try expectEqual(firstHref(d), href, "\(href) should survive")
    }
}

test("HTML: script image sources are dropped, real ones kept") {
    for src in ["javascript:alert(1)", "data:text/html,<script>alert(1)</script>",
                "data:image/svg+xml,<svg onload=alert(1)>", "vbscript:x"] {
        let d = try HTMLParser.parse("<p>a<img src=\"\(src)\">b</p>", schema: schema)
        try expect(!nodeNames(d).contains("image"), "\(src) should not become an image")
    }
    for src in ["https://example.com/a.png", "cat.png", "file:///tmp/a.png",
                "data:image/png;base64,iVBORw0KGgo="] {
        let d = try HTMLParser.parse("<p><img src=\"\(src)\"></p>", schema: schema)
        try expect(nodeNames(d).contains("image"), "\(src) should survive")
    }
}

test("HTML: a wiki link with a script target degrades to plain text") {
    let d = try HTMLParser.parse(
        "<p><a href=\"javascript:alert(1)\" data-wikilink=\"javascript:alert(1)\">Page</a></p>", schema: schema)
    try expect(!nodeNames(d).contains("wikiLink"))
    try expectEqual(d.textContent, "Page")
}

test("HTML: style values that aren't colors are dropped") {
    // A color round-trips back into a `style` attribute, so anything else CSS
    // can express would ride along with it.
    for value in ["url(javascript:alert(1))", "expression(alert(1))", "red/*x*/"] {
        let d = try HTMLParser.parse("<p><span style=\"color:\(value)\">x</span></p>", schema: schema)
        var marks: Set<String> = []
        d.descendants { node, _, _, _ in
            for m in node.marks { marks.insert(m.type.name) }
            return true
        }
        try expect(!marks.contains("textColor"), "\(value) should not become a color")
        try expect(!HTMLSerializer.serialize(d).contains("javascript"), "and must not round-trip")
    }
    // A declaration the parser doesn't read is dropped with the rest of the
    // rule, so smuggling one in alongside a valid color doesn't carry it over.
    let smuggled = try HTMLParser.parse(
        "<p><span style=\"color:red;background:url(//evil.test)\">x</span></p>", schema: schema)
    let html = HTMLSerializer.serialize(smuggled)
    try expect(html.contains("color:red"), "the color itself survives: \(html)")
    try expect(!html.contains("evil.test") && !html.contains("url("), "nothing else does: \(html)")
    // Real colors still work.
    for value in ["#ff0000", "#f00", "red", "rgb(255, 0, 0)", "rgba(255,0,0,0.5)"] {
        let d = try HTMLParser.parse("<p><span style=\"color:\(value)\">x</span></p>", schema: schema)
        try expect(HTMLSerializer.serialize(d).contains("color:\(value)"), "\(value) should survive")
    }
}

test("Markdown: script URLs never become links or images") {
    let d = try MarkdownParser.parse("[click](javascript:alert(1)) and ![x](data:text/html,<script>)", schema: schema)
    try expectNil(firstHref(d))
    try expect(!nodeNames(d).contains("image"))
    try expect(d.textContent.contains("click"), "the link text survives")
    // Ordinary links are untouched.
    let ok = try MarkdownParser.parse("[a](https://example.com)", schema: schema)
    try expectEqual(firstHref(ok), "https://example.com")
}

test("HTML nesting: past the limit it throws instead of overflowing the stack") {
    // Parsing descends one stack frame per nested element, so this used to be a
    // hard crash somewhere past ~3,000 — uncatchable, and reachable from pasted
    // markup.
    let deep = String(repeating: "<div>", count: 300) + "x" + String(repeating: "</div>", count: 300)
    var thrown: HTMLParseError?
    do { _ = try HTMLParser.parse(deep, schema: schema) } catch let error as HTMLParseError { thrown = error }
    try expectEqual(thrown, .nestingTooDeep(depth: HTMLParser.maxNestingDepth + 1,
                                            limit: HTMLParser.maxNestingDepth))

    // Unclosed opens nest just as deep, and used to crash the same way.
    for count in [1_000, 100_000] {
        var threw = false
        do { _ = try HTMLParser.parse(String(repeating: "<div>", count: count) + "x", schema: schema) }
        catch is HTMLParseError { threw = true }
        try expect(threw, "\(count) unclosed <div>s should be rejected, not parsed")
    }
}

test("HTML nesting: ordinary documents are unaffected by the limit") {
    // Right up to the limit still parses — the guard rejects only the absurd.
    let atLimit = String(repeating: "<div>", count: HTMLParser.maxNestingDepth)
        + "x" + String(repeating: "</div>", count: HTMLParser.maxNestingDepth)
    try expectEqual(try HTMLParser.parse(atLimit, schema: schema).textContent, "x")

    // Depth is nesting, not element count: a flat document of thousands of
    // siblings — including void elements, which never close — is fine.
    let wide = String(repeating: "<p>x</p>", count: 2_000)
    try expectEqual(try HTMLParser.parse(wide, schema: schema).childCount, 2_000)
    let images = "<p>" + String(repeating: "<img src=\"a.png\">", count: 2_000) + "</p>"
    _ = try HTMLParser.parse(images, schema: schema)
    // Stray closing tags must not drive the counter negative and mask real depth.
    let strays = String(repeating: "</div>", count: 500) + String(repeating: "<div>", count: 10) + "x"
    _ = try HTMLParser.parse(strays, schema: schema)
}

test("HTML entities: the named long tail decodes, not just the markup five") {
    let d = try HTMLParser.parse("<p>Tom &amp; Jerry&#8217;s caf&#xe9; &mdash; done</p>", schema: schema)
    try expectEqual(d.textContent, "Tom & Jerry\u{2019}s café — done")

    // The names that actually show up in pasted prose.
    let cases: [(String, String)] = [
        ("&mdash;", "—"), ("&ndash;", "–"), ("&hellip;", "…"),
        ("&rsquo;", "\u{2019}"), ("&lsquo;", "\u{2018}"),
        ("&ldquo;", "\u{201C}"), ("&rdquo;", "\u{201D}"),
        ("&eacute;", "é"), ("&uuml;", "ü"), ("&ccedil;", "ç"), ("&ntilde;", "ñ"),
        ("&nbsp;", "\u{00A0}"), ("&copy;", "©"), ("&trade;", "™"), ("&euro;", "€"),
        ("&laquo;", "«"), ("&bull;", "•"), ("&deg;", "°"), ("&frac12;", "½"),
        ("&rarr;", "→"), ("&times;", "×"), ("&sect;", "§"),
    ]
    for (entity, expected) in cases {
        let parsed = try HTMLParser.parse("<p>\(entity)</p>", schema: schema)
        try expectEqual(parsed.textContent, expected, "\(entity) should decode")
    }
}

test("HTML entities: the mathematical and Greek set decodes") {
    // Formulas pasted as HTML are written with these, and the editor has a math
    // extension to receive them.
    let cases: [(String, String)] = [
        ("&sum;", "∑"), ("&prod;", "∏"), ("&int;", "∫"), ("&part;", "∂"),
        ("&nabla;", "∇"), ("&radic;", "√"), ("&sdot;", "⋅"), ("&equiv;", "≡"),
        ("&asymp;", "≈"), ("&prop;", "∝"), ("&perp;", "⊥"), ("&there4;", "∴"),
        ("&isin;", "∈"), ("&notin;", "∉"), ("&sub;", "⊂"), ("&sube;", "⊆"),
        ("&cap;", "∩"), ("&cup;", "∪"), ("&empty;", "∅"), ("&forall;", "∀"),
        ("&exist;", "∃"), ("&and;", "∧"), ("&or;", "∨"), ("&not;", "¬"),
        ("&alpha;", "α"), ("&pi;", "π"), ("&sigma;", "σ"), ("&omega;", "ω"),
        ("&Delta;", "Δ"), ("&Sigma;", "Σ"), ("&Omega;", "Ω"), ("&thetasym;", "ϑ"),
        ("&rArr;", "⇒"), ("&hArr;", "⇔"), ("&alefsym;", "ℵ"), ("&weierp;", "℘"),
        ("&lang;", "⟨"), ("&rang;", "⟩"), ("&lceil;", "⌈"), ("&rfloor;", "⌋"),
    ]
    for (entity, expected) in cases {
        try expectEqual(try HTMLParser.parse("<p>\(entity)</p>", schema: schema).textContent, expected,
                        "\(entity) should decode")
    }
    // A whole formula's worth at once.
    let d = try HTMLParser.parse("<p>&sum;<sub>n=1</sub> &alpha;&sup2; &isin; &Omega;</p>", schema: schema)
    try expectEqual(d.textContent, "∑n=1 α² ∈ Ω")
}

test("HTML entities: names that prefix each other resolve exactly") {
    // `sub`/`sube`, `sup`/`supe`/`sup2`, `not`/`notin` all share a prefix; the
    // scanner must match the whole name up to the semicolon, not the prefix.
    for (entity, expected) in [("&sub;", "⊂"), ("&sube;", "⊆"), ("&sup;", "⊃"),
                               ("&supe;", "⊇"), ("&sup2;", "²"), ("&not;", "¬"),
                               ("&notin;", "∉"), ("&pi;", "π"), ("&piv;", "ϖ"),
                               ("&sigma;", "σ"), ("&sigmaf;", "ς")] {
        try expectEqual(try HTMLParser.parse("<p>\(entity)</p>", schema: schema).textContent, expected,
                        "\(entity) should decode to exactly its own character")
    }
}

test("HTML entities: an unknown name stays literal") {
    for source in ["&notanentity;", "&fooooo;", "&;", "&mdash", "& amp;"] {
        let d = try HTMLParser.parse("<p>x\(source)y</p>", schema: schema)
        try expectEqual(d.textContent, "x\(source)y", "\(source) should pass through untouched")
    }
}

test("HTML entities: decoding is a single pass") {
    // `&amp;mdash;` is the *text* "&mdash;", not an em dash — decoding the
    // output of a decode would silently corrupt escaped source.
    try expectEqual(try HTMLParser.parse("<p>&amp;mdash;</p>", schema: schema).textContent, "&mdash;")
    try expectEqual(try HTMLParser.parse("<p>&amp;amp;</p>", schema: schema).textContent, "&amp;")
    try expectEqual(try HTMLParser.parse("<p>&amp;#8217;</p>", schema: schema).textContent, "&#8217;")
}

test("HTML entities: round-trip through the serializer stays stable") {
    // Serializing re-escapes only the markup characters, so a decoded em dash
    // survives as itself and a literal ampersand survives as `&amp;`.
    let d = doc(p("Tom & Jerry\u{2019}s café — done"))
    let back = try HTMLParser.parse(HTMLSerializer.serialize(d), schema: schema)
    try expectEqual(back, d)
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

// MARK: - Details (collapsible sections)

func details(_ summary: String, _ body: [Node], open: Bool = false) -> Node {
    node("details", ["open": .bool(open)], [
        node("detailsSummary", [:], summary.isEmpty ? [] : [t(summary)]),
        node("detailsContent", [:], body),
    ])
}

test("HTML serialize details") {
    let d = doc(details("More", [p("hidden")], open: true))
    try expectEqual(HTMLSerializer.serialize(d),
                    "<details open><summary>More</summary><div data-type=\"detailsContent\"><p>hidden</p></div></details>")
    let closed = doc(details("More", [p("hidden")]))
    try expect(!HTMLSerializer.serialize(closed).contains("<details open>"))
}

test("HTML details round-trip (open and closed)") {
    for open in [true, false] {
        let d = doc(details("Summary text", [p("one"), h(3, "two")], open: open))
        let back = try HTMLParser.parse(HTMLSerializer.serialize(d), schema: schema)
        try expectEqual(back, d)
    }
}

test("HTML parses hand-written <details> (no data-type div)") {
    let d = try HTMLParser.parse("<details><summary>Title</summary><p>body</p></details>", schema: schema)
    try expectEqual(d, doc(details("Title", [p("body")])))
}

test("HTML parses a <details> without a summary") {
    let d = try HTMLParser.parse("<details><p>body</p></details>", schema: schema)
    try expectEqual(d, doc(details("", [p("body")])))
}

test("HTML details keeps its content in a schema without details nodes") {
    // A schema whose only blocks are paragraphs: the section degrades to text.
    let plain = try Schema(nodes: [
        ("doc", NodeSpec(content: "block+")),
        ("paragraph", NodeSpec(content: "inline*", group: "block")),
        ("text", NodeSpec(group: "inline")),
    ], marks: [], topNode: "doc")
    let d = try HTMLParser.parse("<details><summary>Title</summary><p>body</p></details>", schema: plain)
    try expectEqual(d.childCount, 2)
    try expectEqual(d.child(0).textContent, "Title")
    try expectEqual(d.child(1).textContent, "body")
}

test("Markdown details round-trip") {
    let d = doc(p("before"), details("Summary", [p("one"), p("two")], open: true), p("after"))
    let md = MarkdownSerializer.serialize(d)
    try expect(md.contains("<details open>"), md)
    try expect(md.contains("<summary>Summary</summary>"), md)
    let back = try MarkdownParser.parse(md, schema: schema)
    try expectEqual(back, d)
}

test("Markdown details round-trip (closed, nested list)") {
    let d = doc(details("Items", [node("bulletList", [:], [
        node("listItem", [:], [p("a")]),
        node("listItem", [:], [p("b")]),
    ])]))
    let back = try MarkdownParser.parse(MarkdownSerializer.serialize(d), schema: schema)
    try expectEqual(back, d)
}

// MARK: - Mathematics

func inlineMath(_ latex: String) -> Node { node("inlineMath", ["latex": .string(latex)]) }
func blockMath(_ latex: String) -> Node { node("blockMath", ["latex": .string(latex)]) }

test("HTML serialize math carries the source in data-latex") {
    let d = doc(p(t("let "), inlineMath("x^2")), blockMath("E = mc^2"))
    try expectEqual(HTMLSerializer.serialize(d),
                    "<p>let <span data-type=\"inline-math\" data-latex=\"x^2\">$x^2$</span></p>"
                    + "<div data-type=\"block-math\" data-latex=\"E = mc^2\">$$E = mc^2$$</div>")
}

test("HTML math round-trip") {
    let d = doc(p(t("before "), inlineMath("\\frac{a}{b}"), t(" after")),
                blockMath("\\sum_{i=1}^{n} i"),
                p("tail"))
    try expectEqual(try HTMLParser.parse(HTMLSerializer.serialize(d), schema: schema), d)
}

test("HTML math escapes source with markup characters") {
    let d = doc(p(inlineMath("a < b & \"c\"")))
    let html = HTMLSerializer.serialize(d)
    try expect(html.contains("data-latex=\"a &lt; b &amp; &quot;c&quot;\""), html)
    try expectEqual(try HTMLParser.parse(html, schema: schema), d)
}

test("HTML math falls back to the $-fenced text when data-latex is absent") {
    // Hand-written or third-party markup that only carries the display text.
    let inline = try HTMLParser.parse("<p><span data-type=\"inline-math\">$x^2$</span></p>", schema: schema)
    try expectEqual(inline, doc(p(inlineMath("x^2"))))
    let block = try HTMLParser.parse("<div data-type=\"block-math\">$$a+b$$</div>", schema: schema)
    try expectEqual(block, doc(blockMath("a+b")))
}

test("HTML math keeps its source in a schema without math nodes") {
    let plain = try Schema(nodes: [
        ("doc", NodeSpec(content: "block+")),
        ("paragraph", NodeSpec(content: "inline*", group: "block")),
        ("text", NodeSpec(group: "inline")),
    ], marks: [], topNode: "doc")
    let d = try HTMLParser.parse(
        "<p>a <span data-type=\"inline-math\" data-latex=\"x^2\">$x^2$</span></p>"
        + "<div data-type=\"block-math\" data-latex=\"y\">$$y$$</div>", schema: plain)
    try expectEqual(d.childCount, 2)
    try expectEqual(d.child(0).textContent, "a $x^2$")
    try expectEqual(d.child(1).textContent, "$$y$$")
}

test("Markdown serialize math uses the $ and $$ conventions") {
    let d = doc(p(t("let "), inlineMath("x^2")), blockMath("E = mc^2"))
    try expectEqual(MarkdownSerializer.serialize(d), "let $x^2$\n\n$$\nE = mc^2\n$$")
}

test("Markdown math round-trip") {
    let d = doc(p(t("before "), inlineMath("x^2"), t(" after")),
                blockMath("\\frac{a}{b}"),
                p("tail"))
    try expectEqual(try MarkdownParser.parse(MarkdownSerializer.serialize(d), schema: schema), d)
}

test("Markdown parses a one-line $$…$$ fence") {
    try expectEqual(try MarkdownParser.parse("$$x^2$$", schema: schema), doc(blockMath("x^2")))
}

test("Markdown parses a multi-line $$ fence") {
    let d = try MarkdownParser.parse("$$\na + b\n$$", schema: schema)
    try expectEqual(d, doc(blockMath("a + b")))
}

test("Markdown ends a paragraph at a $$ fence") {
    let d = try MarkdownParser.parse("text\n$$x$$\nmore", schema: schema)
    try expectEqual(d, doc(p("text"), blockMath("x"), p("more")))
}

test("Markdown leaves a lone $ alone") {
    let d = try MarkdownParser.parse("costs $5 today", schema: schema)
    try expectEqual(d, doc(p("costs $5 today")))
}

test("Markdown math is inert in a schema without the nodes") {
    let plain = try Schema(nodes: [
        ("doc", NodeSpec(content: "block+")),
        ("paragraph", NodeSpec(content: "inline*", group: "block")),
        ("text", NodeSpec(group: "inline")),
    ], marks: [], topNode: "doc")
    let d = try MarkdownParser.parse("a $x^2$ b", schema: plain)
    try expectEqual(d.child(0).textContent, "a $x^2$ b")
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
        switch rnd(depth > 0 ? 9 : 6) {
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
        case 7: return node("details", ["open": .bool(rnd(2) == 0)], [
            node("detailsSummary", [:], rndInline()),
            node("detailsContent", [:], (0...rnd(1)).map { _ in rndBlock(depth - 1) }),
        ])
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

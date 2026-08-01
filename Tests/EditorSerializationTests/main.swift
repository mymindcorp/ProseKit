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

/// The attributes of a list written tight — no blank lines between its items,
/// which is how nearly every list in these tests is spelled.
let tightList: Attrs = ["tight": .bool(true)]

let schema: Schema = {
    let nodes: [(String, NodeSpec)] = [
        ("doc", NodeSpec(content: "block+")),
        ("paragraph", NodeSpec(content: "inline*", group: "block")),
        ("blockquote", NodeSpec(content: "block+", group: "block", defining: true)),
        ("heading", NodeSpec(content: "inline*", group: "block", attrs: ["level": AttributeSpec(default: .int(1))], defining: true)),
        ("codeBlock", NodeSpec(content: "text*", marks: "", group: "block",
                               attrs: ["language": AttributeSpec(default: .null)],
                               code: true, defining: true)),
        ("horizontalRule", NodeSpec(group: "block")),
        ("text", NodeSpec(group: "inline")),
        ("hardBreak", NodeSpec(group: "inline", inline: true)),
        ("image", NodeSpec(group: "inline", inline: true, atom: true, attrs: ["src": AttributeSpec(), "alt": AttributeSpec(default: .null), "title": AttributeSpec(default: .null), "width": AttributeSpec(default: .null), "height": AttributeSpec(default: .null), "model": AttributeSpec(default: .null)])),
        ("wikiLink", NodeSpec(group: "inline", inline: true, atom: true, attrs: ["target": AttributeSpec(), "label": AttributeSpec(default: .null)], leafText: { $0.attrs["label"]?.stringValue ?? $0.attrs["target"]?.stringValue ?? "" })),
        ("mention", NodeSpec(group: "inline", inline: true, atom: true, attrs: ["id": AttributeSpec(), "label": AttributeSpec(default: .null)], leafText: { "@" + ($0.attrs["label"]?.stringValue ?? $0.attrs["id"]?.stringValue ?? "") })),
        ("bulletList", NodeSpec(content: "listItem+", group: "block", attrs: ["tight": AttributeSpec(default: .bool(false))])),
        ("orderedList", NodeSpec(content: "listItem+", group: "block", attrs: ["order": AttributeSpec(default: .int(1)), "tight": AttributeSpec(default: .bool(false))])),
        ("listItem", NodeSpec(content: "paragraph block*", defining: true)),
        ("taskList", NodeSpec(content: "taskItem+", group: "block")),
        ("taskItem", NodeSpec(content: "paragraph block*", attrs: ["checked": AttributeSpec(default: .bool(false))], defining: true)),
        ("details", NodeSpec(content: "detailsSummary detailsContent", group: "block", attrs: ["open": AttributeSpec(default: .bool(false))], defining: true, isolating: true)),
        ("detailsSummary", NodeSpec(content: "inline*", selectable: false, defining: true, isolating: true)),
        ("detailsContent", NodeSpec(content: "block+", selectable: false, defining: true)),
        ("figure", NodeSpec(content: "block+ figcaption?", group: "block", defining: true, isolating: true)),
        ("figcaption", NodeSpec(content: "inline*", selectable: false, defining: true, isolating: true)),
        ("inlineMath", NodeSpec(group: "inline", inline: true, atom: true, attrs: ["latex": AttributeSpec(default: .string(""))], leafText: { "$" + ($0.attrs["latex"]?.stringValue ?? "") + "$" })),
        ("blockMath", NodeSpec(group: "block", atom: true, attrs: ["latex": AttributeSpec(default: .string(""))], leafText: { "$$" + ($0.attrs["latex"]?.stringValue ?? "") + "$$" })),
        ("table", NodeSpec(content: "tableRow+", group: "block", isolating: true)),
        ("tableRow", NodeSpec(content: "(tableCell | tableHeader)+")),
        ("tableCell", NodeSpec(content: "block+", attrs: cellAttrs, isolating: true)),
        ("tableHeader", NodeSpec(content: "block+", attrs: cellAttrs, isolating: true)),
    ]
    let marks: [(String, MarkSpec)] = [
        ("bold", MarkSpec()), ("italic", MarkSpec()), ("strike", MarkSpec()),
        ("highlight", MarkSpec(attrs: ["color": AttributeSpec(default: .null)])),
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
    let d = doc(h(2, "Title"), p(t("Hello "), strong("world")), node("bulletList", tightList, [node("listItem", [:], [p("item")])]))
    let json = try DocumentJSON.string(d)
    let back = try DocumentJSON.decode(schema, json)
    try expectEqual(d, back)
}

test("JSON decodes every attribute value type") {
    // The decoder identifies types from Foundation's parse rather than by trying
    // each case, so pin the discriminations that are easy to get wrong: bools
    // must not read as numbers, and whole numbers must stay ints.
    let value = try DocumentJSON.attributeValue(from: try JSONSerialization.jsonObject(
        with: Data(#"{"t":true,"f":false,"i":42,"neg":-7,"d":1.5,"s":"x","n":null,"a":[1,"two",false],"o":{"k":"v"}}"#.utf8)))
    guard case let .object(o) = value else {
        try expect(false, "expected an object")
        return
    }
    try expectEqual(o["t"], .bool(true))
    try expectEqual(o["f"], .bool(false))
    try expectEqual(o["i"], .int(42))
    try expectEqual(o["neg"], .int(-7))
    try expectEqual(o["d"], .double(1.5))
    try expectEqual(o["s"], .string("x"))
    try expectEqual(o["n"], .null)
    try expectEqual(o["a"], .array([.int(1), .string("two"), .bool(false)]))
    try expectEqual(o["o"], .object(["k": .string("v")]))
}

test("JSON round-trips escapes, unicode and attribute types") {
    let d = doc(
        h(2, "Quote \" backslash \\ newline \n tab \t"),
        p(t("emoji 👨‍👩‍👧 accents éü CJK 日本語 math ∑∫")),
        p(node("image", ["src": .string("https://example.test/a?b=1&c=2"), "alt": .null])))
    let back = try DocumentJSON.decode(schema, try DocumentJSON.string(d))
    try expectEqual(d, back)
}

test("JSON decode rejects malformed input") {
    try expectThrows { _ = try DocumentJSON.decode(schema, "{\"type\":") }
    try expectThrows { _ = try DocumentJSON.decode(schema, "[1,2]") }
    try expectThrows { _ = try DocumentJSON.decode(schema, "") }
}

test("JSON encoder matches JSONEncoder byte for byte") {
    // The writer replaced JSONEncoder, so hold it to that output on the shapes
    // it has to get right: escapes, control characters, empty containers, key
    // ordering, and each number type.
    let cases: [AttributeValue] = [
        .object(["b": .int(1), "a": .int(2), "C": .int(3), "": .int(4)]),
        .string(""), .string("quote \" backslash \\ slash /"),
        .string("newline \n tab \t return \r bell \u{07} nul \u{00} vt \u{0B}"),
        .string("emoji 👨‍👩‍👧 accents éü CJK 日本語 math ∑∫"),
        .int(0), .int(-1), .int(Int.max), .int(Int.min),
        .double(1.5), .double(-0.25), .double(1e100), .double(1e-7),
        .bool(true), .bool(false), .null,
        .object(["nested": .array([.object(["deep": .array([.int(1), .null])])])]),
    ]
    var mismatches: [String] = []
    for value in cases {
        for pretty in [false, true] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
            let expected = String(decoding: try encoder.encode(value), as: UTF8.self)
            let actual = String(decoding: try DocumentJSON.encode(value, pretty: pretty), as: UTF8.self)
            if actual != expected {
                mismatches.append("\(value) pretty=\(pretty): got \(actual), JSONEncoder \(expected)")
            }
        }
    }
    try expect(mismatches.isEmpty, "\(mismatches.count) mismatch(es):\n" + mismatches.joined(separator: "\n"))
}

test("JSON encoder writes empty containers compactly") {
    // The one place the writer deliberately differs from JSONEncoder, which
    // pretty-prints these as "{\n\n}" and "[\n\n]". Neither can occur in a
    // document — `attrs` and `content` are omitted when empty — so preferring
    // the tidier spelling costs nothing.
    for pretty in [false, true] {
        try expectEqual(String(decoding: try DocumentJSON.encode(.object([:]), pretty: pretty),
                               as: UTF8.self), "{}")
        try expectEqual(String(decoding: try DocumentJSON.encode(.array([]), pretty: pretty),
                               as: UTF8.self), "[]")
    }
}

test("JSON encoder keeps whole doubles distinguishable from ints") {
    // The second deliberate difference from JSONEncoder, which writes .double(2)
    // as "2" — that reparses as .int(2), so the value changes type on a round
    // trip. Writing "2.0" keeps it a double. Same rule covers -0.0, which
    // JSONEncoder writes as "-0".
    for (value, text) in [(AttributeValue.double(2), "2.0"), (.double(-0.0), "-0.0")] {
        let encoded = try DocumentJSON.encode(value)
        try expectEqual(String(decoding: encoded, as: UTF8.self), text)
        let reparsed = try DocumentJSON.attributeValue(
            from: try JSONSerialization.jsonObject(with: encoded, options: [.fragmentsAllowed]))
        try expectEqual(reparsed, value)
    }
}

test("JSON encoder rejects values JSON cannot spell") {
    for bad: AttributeValue in [.double(.infinity), .double(-.infinity), .double(.nan)] {
        try expectThrows { _ = try DocumentJSON.encode(bad) }
    }
}

test("JSON encodes documents identically to JSONEncoder") {
    let docs = [
        doc(p("hi")),
        doc(h(2, "Title"), p(t("Hello "), strong("world")), node("horizontalRule", [:], [])),
        doc(node("bulletList", tightList, [node("listItem", [:], [p("item")])])),
        doc(p(node("image", ["src": .string("a.png"), "alt": .null, "width": .int(3)]))),
        doc(p(t("marks \" and \n newlines"))),
    ]
    for d in docs {
        for pretty in [false, true] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
            let expected = try encoder.encode(AttributeValue.object(d.toJSON()))
            try expectEqual(try DocumentJSON.string(d, pretty: pretty),
                            String(decoding: expected, as: UTF8.self), "doc \(d)")
        }
    }
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
        node("bulletList", tightList, [
            node("listItem", [:], [p("one")]),
            node("listItem", [:], [p("two")]),
        ]))
    let html = HTMLSerializer.serialize(d)
    let back = try HTMLParser.parse(html, schema: schema)
    try expectEqual(back, d)
}

test("HTML: a mark spanning several nodes is written once around the run") {
    // It used to be applied per node, giving `<em>foo </em><em><a>bar</a></em>`.
    let d = try MarkdownParser.parse("*foo [bar](/url)*", schema: schema)
    try expectEqual(HTMLSerializer.serialize(d), "<p><em>foo <a href=\"/url\">bar</a></em></p>")
    try expectEqual(try HTMLParser.parse(HTMLSerializer.serialize(d), schema: schema), d)
}

test("HTML: a mark stays open across a node that can't carry it") {
    // `code` excludes every other mark, so the span itself isn't bold — but
    // `<strong>foo <code>code</code> bar</strong>` is what should be written,
    // and closing the strong around the span would be wrong.
    let d = try MarkdownParser.parse("**foo `code` bar**", schema: schema)
    try expectEqual(HTMLSerializer.serialize(d),
                    "<p><strong>foo <code>code</code> bar</strong></p>")
    try expectEqual(try HTMLParser.parse(HTMLSerializer.serialize(d), schema: schema), d)
}

test("HTML: nested and adjacent marks") {
    for (md, html) in [("**foo *bar* baz**", "<p><strong>foo <em>bar</em> baz</strong></p>"),
                       ("***both***", "<p><strong><em>both</em></strong></p>"),
                       ("*a* *b*", "<p><em>a</em> <em>b</em></p>")] {
        let d = try MarkdownParser.parse(md, schema: schema)
        try expectEqual(HTMLSerializer.serialize(d), html, "input: \(md)")
        try expectEqual(try HTMLParser.parse(HTMLSerializer.serialize(d), schema: schema), d,
                        "input: \(md)")
    }
}

test("HTML: bold code pastes instead of failing the whole document") {
    // The marks a page nests aren't always ones the schema can hold together —
    // `code` excludes everything — and combining them blindly produced a set the
    // document model rejects, so the entire paste threw.
    for html in ["<p><strong><code>x</code></strong></p>",
                 "<p><em><code>y</code></em></p>",
                 "<p><strong>a<code>b</code>c</strong></p>",
                 "<p><a href=\"/u\"><code>z</code></a></p>"] {
        let d = try HTMLParser.parse(html, schema: schema)
        try expect(!d.textContent.isEmpty, "lost the text: \(html)")
    }
    // The excluded mark is the one dropped; the code span survives.
    let d = try HTMLParser.parse("<p><strong><code>x</code></strong></p>", schema: schema)
    try expectEqual(d.child(0).child(0).marks.map(\.type.name), ["code"])
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

test("HTML: an image's original-image model round-trips") {
    // `src` and width/height are the presentation; `model` is what it was made
    // from, and has to survive independently of it.
    let model: AttributeValue = .object([
        "path": .string("originals/DSC_0001.raw"), "width": .int(4000), "height": .int(3000),
    ])
    let d = doc(p(node("image", ["src": .string("thumb.jpg"), "width": .int(300),
                                 "height": .int(225), "model": model])))
    let html = HTMLSerializer.serialize(d)
    try expect(html.contains("data-model-path=\"originals/DSC_0001.raw\""), html)
    try expect(html.contains("data-model-width=\"4000\"") && html.contains("data-model-height=\"3000\""), html)
    try expectEqual(try HTMLParser.parse(html, schema: schema), d)
}

test("HTML: an original-image model with only a path round-trips") {
    // The dimensions are optional; an absent one must not come back as a null
    // field, which wouldn't compare equal to the node that was written.
    let d = doc(p(node("image", ["src": .string("a.jpg"),
                                 "model": .object(["path": .string("orig.raw")])])))
    let html = HTMLSerializer.serialize(d)
    try expect(!html.contains("data-model-width"), html)
    try expectEqual(try HTMLParser.parse(html, schema: schema), d)
}

test("HTML: an image with no model stays without one") {
    let d = doc(p(node("image", ["src": .string("a.jpg")])))
    let html = HTMLSerializer.serialize(d)
    try expectEqual(html, "<p><img src=\"a.jpg\"></p>")
    try expectEqual(try HTMLParser.parse(html, schema: schema), d)
    try expectEqual(try HTMLParser.parse(html, schema: schema).child(0).child(0).attrs["model"], .null)
}

test("JSON: an image's model is a nested object, not encoded text") {
    let d = doc(p(node("image", ["src": .string("a.jpg"),
                                 "model": .object(["path": .string("o.raw"), "width": .int(10)])])))
    let json = try DocumentJSON.string(d)
    try expect(json.contains("\"model\""), json)
    try expect(json.contains("\"path\""), "the model nests as an object: \(json)")
    try expectEqual(try DocumentJSON.decode(schema, json), d)
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

test("HTML tokenizer: raw multi-byte text survives slicing") {
    // The tokenizer scans UTF-8 bytes and cuts text at "<". These characters are
    // two, three and four bytes wide, so a cut that landed mid-sequence would
    // corrupt them — and unlike the &eacute; cases, they arrive raw in the markup.
    let back = try HTMLParser.parse(
        "<p>emoji 👨‍👩‍👧 accents éü CJK 日本語 math ∑∫</p>", schema: schema)
    try expectEqual(back, doc(p("emoji 👨‍👩‍👧 accents éü CJK 日本語 math ∑∫")))
}

test("HTML tokenizer: multi-byte text abutting tag boundaries") {
    // Each cut is immediately before or after a multi-byte character.
    let back = try HTMLParser.parse("<p>日</p><p>本<strong>語</strong>👍</p>", schema: schema)
    try expectEqual(back, doc(p("日"), p(t("本"), strong("語"), t("👍"))))
}

test("HTML tokenizer: multi-byte inside attribute values") {
    let back = try HTMLParser.parse(
        "<p><img src=\"café.png\" alt=\"日本語 &gt; ∑\" title='a>b'></p>", schema: schema)
    let image = back.child(0).child(0)
    try expectEqual(image.type.name, "image")
    try expectEqual(image.attrs["src"], .string("café.png"))
    try expectEqual(image.attrs["alt"], .string("日本語 > ∑"))
}

test("HTML tokenizer: a combining mark after '>' does not hide the tag end") {
    // Tokenizing over bytes matches the spec, which works in code points. Reading
    // Characters used to fuse ">" with a following combining mark into a single
    // grapheme, so the ">" never compared equal and the tag looked unterminated.
    let back = try HTMLParser.parse("<p>a</p>\u{0301}<p>b</p>", schema: schema)
    try expectEqual(back.childCount, 3)
    try expectEqual(back.child(0), p("a"))
    try expectEqual(back.child(2), p("b"))
}

test("HTML entities: &nbsp; and numeric references decode") {
    let back = try HTMLParser.parse("<p>a&nbsp;b &#65;&#x42; &amp;lt;</p>", schema: schema)
    try expectEqual(back, doc(p("a\u{00A0}b AB &lt;")))
}

test("HTML entities: a reference to no character becomes the replacement one") {
    // A numeric reference that names zero, a surrogate, or a code point past the
    // last one is an error that both HTML and CommonMark resolve to U+FFFD.
    // (This used to pass them through unchanged, which matched neither.)
    let back = try HTMLParser.parse("<p>&#x110000; &#xD800; &#0;</p>", schema: schema)
    try expectEqual(back, doc(p("\u{FFFD} \u{FFFD} \u{FFFD}")))
}

test("HTML entities: text that isn't a reference stays literal") {
    // An unknown name, an empty reference, and a bare ampersand are not errors
    // to recover from — they are simply text.
    let back = try HTMLParser.parse("<p>&bogus; &; & end&</p>", schema: schema)
    try expectEqual(back, doc(p("&bogus; &; & end&")))
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

// MARK: - Per-node-type parse coverage

/// Every node type in a document, so a test can assert on its shape.
private func shape(_ d: Node) -> [String] {
    var names: [String] = []
    d.descendants { node, _, _, _ in
        if !node.isText { names.append(node.type.name) }
        return true
    }
    return names
}

/// An HTML form that must parse to each node type in the schema.
///
/// Driven by `schema.nodes` rather than a hand-kept list, so adding a node type
/// without a way to parse HTML into it fails here instead of being noticed when
/// a paste silently loses it.
private let htmlProducingNode: [String: String] = [
    "paragraph": "<p>x</p>",
    "heading": "<h2>x</h2>",
    "blockquote": "<blockquote><p>x</p></blockquote>",
    "codeBlock": "<pre><code>x</code></pre>",
    "horizontalRule": "<hr>",
    "hardBreak": "<p>a<br>b</p>",
    "image": "<p><img src=\"a.png\" alt=\"pic\"></p>",
    "wikiLink": "<p><a href=\"Page\" data-wikilink=\"Page\">Page</a></p>",
    "mention": "<p><span data-mention=\"u1\">@u1</span></p>",
    "bulletList": "<ul><li>x</li></ul>",
    "orderedList": "<ol><li>x</li></ol>",
    "listItem": "<ul><li>x</li></ul>",
    "taskList": "<ul data-type=\"taskList\"><li data-type=\"taskItem\" data-checked=\"true\">x</li></ul>",
    "taskItem": "<ul data-type=\"taskList\"><li data-type=\"taskItem\" data-checked=\"true\">x</li></ul>",
    "details": "<details open><summary>s</summary><p>b</p></details>",
    "detailsSummary": "<details><summary>s</summary><p>b</p></details>",
    "detailsContent": "<details><summary>s</summary><p>b</p></details>",
    "inlineMath": "<p><span data-type=\"inline-math\" data-latex=\"x^2\">$x^2$</span></p>",
    "blockMath": "<div data-type=\"block-math\" data-latex=\"x^2\">$$x^2$$</div>",
    "figure": "<figure><p>body</p><figcaption>A cat</figcaption></figure>",
    "figcaption": "<figure><p>body</p><figcaption>A cat</figcaption></figure>",
    "table": "<table><tr><td>x</td></tr></table>",
    "tableRow": "<table><tr><td>x</td></tr></table>",
    "tableCell": "<table><tr><td>x</td></tr></table>",
    "tableHeader": "<table><tr><th>x</th></tr></table>",
]

/// Node types with no HTML element of their own: the document itself, and text,
/// which is character data rather than a tag.
private let nodesWithoutTags: Set<String> = ["doc", "text"]

test("HTML: every node type in the schema can be parsed into") {
    var missing: [String] = []
    var notProduced: [String] = []
    for name in schema.nodes.keys.sorted() where !nodesWithoutTags.contains(name) {
        guard let html = htmlProducingNode[name] else { missing.append(name); continue }
        let d = try HTMLParser.parse(html, schema: schema)
        try d.check()
        if !shape(d).contains(name) { notProduced.append("\(name) — \(html) gave \(shape(d))") }
    }
    try expect(missing.isEmpty, "no HTML sample for: \(missing.joined(separator: ", "))")
    try expect(notProduced.isEmpty, "didn't parse into the node:\n  " + notProduced.joined(separator: "\n  "))
}

test("HTML: every mark type in the schema can be parsed into") {
    let htmlProducingMark: [String: String] = [
        "bold": "<p><strong>x</strong></p>",
        "italic": "<p><em>x</em></p>",
        "strike": "<p><s>x</s></p>",
        "underline": "<p><u>x</u></p>",
        "highlight": "<p><mark>x</mark></p>",
        "code": "<p><code>x</code></p>",
        "link": "<p><a href=\"https://x.test\">x</a></p>",
        "subscript": "<p><sub>x</sub></p>",
        "superscript": "<p><sup>x</sup></p>",
        "textColor": "<p><span style=\"color:#ff0000\">x</span></p>",
        "backgroundColor": "<p><span style=\"background-color:#ff0000\">x</span></p>",
    ]
    var problems: [String] = []
    for name in schema.marks.keys.sorted() {
        guard let html = htmlProducingMark[name] else { problems.append("no sample for \(name)"); continue }
        let d = try HTMLParser.parse(html, schema: schema)
        try d.check()
        var found = false
        d.descendants { node, _, _, _ in
            if node.marks.contains(where: { $0.type.name == name }) { found = true }
            return !found
        }
        if !found { problems.append("\(html) didn't produce a \(name) mark") }
    }
    try expect(problems.isEmpty, problems.joined(separator: "\n  "))
}

test("HTML: highlight colors survive a round-trip") {
    // The colour is a named style the theme resolves, and it used to be dropped
    // on the way out — every highlight came back as the default one.
    for color in ["yellow", "green", "blue", "pink", "orange", "purple"] {
        let d = doc(p(t("a "), schema.text("lit", [schema.mark("highlight", ["color": .string(color)])]), t(" b")))
        let html = HTMLSerializer.serialize(d)
        try expect(html.contains("data-color=\"\(color)\""), "\(color) wasn't serialized: \(html)")
        try expectEqual(try HTMLParser.parse(html, schema: schema), d, "\(color) didn't come back")
    }
    // A highlight with no colour stays plain, and doesn't gain an empty attribute.
    let plain = doc(p(schema.text("lit", [schema.mark("highlight")])))
    try expectEqual(HTMLSerializer.serialize(plain), "<p><mark>lit</mark></p>")
    try expectEqual(try HTMLParser.parse(HTMLSerializer.serialize(plain), schema: schema), plain)
}

test("HTML: a highlight color that is real CSS also carries a style") {
    // So the highlight is visible when pasted somewhere that doesn't know the
    // theme's names.
    let named = doc(p(schema.text("x", [schema.mark("highlight", ["color": .string("yellow")])])))
    try expect(HTMLSerializer.serialize(named).contains("style=\"background-color:yellow\""),
               HTMLSerializer.serialize(named))
    // A name that isn't a CSS colour gets `data-color` only — never a bogus
    // declaration. The value still round-trips: `data-color` is inert (a data
    // attribute, escaped, and only ever used as a key into the theme's colour
    // table), so the thing to keep out of the output is the *style*.
    for color in ["brand-accent-2", "url(javascript:alert(1))", "red;x:y"] {
        let d = doc(p(schema.text("x", [schema.mark("highlight", ["color": .string(color)])])))
        let html = HTMLSerializer.serialize(d)
        try expect(!html.contains("style="), "\(color) shouldn't produce a style: \(html)")
        try expectEqual(try HTMLParser.parse(html, schema: schema), d, "\(color) should still round-trip")
    }
    // …and reading such a mark back never produces a style either.
    let reparsed = try HTMLParser.parse(
        "<p><mark data-color=\"url(javascript:alert(1))\">x</mark></p>", schema: schema)
    try expect(!HTMLSerializer.serialize(reparsed).contains("style="),
               HTMLSerializer.serialize(reparsed))
}

test("HTML: a highlight from another editor is read from its style") {
    // Other editors write the colour as a style with no `data-color`.
    let d = try HTMLParser.parse("<p><mark style=\"background-color:#ffff00\">x</mark></p>", schema: schema)
    var color: String?
    d.descendants { node, _, _, _ in
        if let m = node.marks.first(where: { $0.type.name == "highlight" }) {
            color = m.attrs["color"]?.stringValue
        }
        return color == nil
    }
    try expectEqual(color, "#ffff00")
}

test("HTML: link titles survive a round-trip") {
    // Same class of bug as the highlight colour: an attribute the mark carries
    // that the serializer didn't write.
    let d = doc(p(schema.text("x", [schema.mark("link", ["href": .string("https://x.test"),
                                                         "title": .string("A title")])])))
    let html = HTMLSerializer.serialize(d)
    try expect(html.contains("title=\"A title\""), html)
    try expectEqual(try HTMLParser.parse(html, schema: schema), d)
    // A link with no title doesn't gain an empty one.
    let bare = doc(p(schema.text("x", [schema.mark("link", ["href": .string("https://x.test")])])))
    try expect(!HTMLSerializer.serialize(bare).contains("title="), HTMLSerializer.serialize(bare))
    try expectEqual(try HTMLParser.parse(HTMLSerializer.serialize(bare), schema: schema), bare)
}

test("HTML: every attribute a mark carries survives a round-trip") {
    // Driven by the schema, so a mark that gains an attribute without the
    // serializer learning about it fails here rather than losing data quietly.
    let sampleAttrs: [String: Attrs] = [
        "highlight": ["color": .string("green")],
        "link": ["href": .string("https://x.test"), "title": .string("T")],
        "textColor": ["color": .string("#ff0000")],
        "backgroundColor": ["color": .string("#00ff00")],
    ]
    var problems: [String] = []
    for (name, markType) in schema.marks.sorted(by: { $0.key < $1.key }) where !markType.attrs.isEmpty {
        guard let attrs = sampleAttrs[name] else {
            problems.append("\(name) has attributes but no sample here")
            continue
        }
        for declared in markType.attrs.keys where attrs[declared] == nil {
            problems.append("\(name).\(declared) isn't covered by the sample")
        }
        let d = doc(p(schema.text("x", [schema.mark(name, attrs)])))
        let back = try HTMLParser.parse(HTMLSerializer.serialize(d), schema: schema)
        if back != d { problems.append("\(name) lost attributes: \(HTMLSerializer.serialize(d))") }
    }
    try expect(problems.isEmpty, problems.joined(separator: "\n  "))
}

test("HTML: every node type survives a serialize/parse round-trip") {
    // Parsing into the node isn't enough — it has to come back out again and
    // read the same, which is what a copy/paste between documents relies on.
    for name in schema.nodes.keys.sorted() where !nodesWithoutTags.contains(name) {
        guard let html = htmlProducingNode[name] else { continue }
        let once = try HTMLParser.parse(html, schema: schema)
        let twice = try HTMLParser.parse(HTMLSerializer.serialize(once), schema: schema)
        try expectEqual(twice, once, "\(name) isn't stable across a round-trip")
    }
}

test("HTML: every node type is coerced into place when it arrives bare") {
    // The same elements again, but stripped of the ancestors that make them
    // legal — what a partial selection copy actually produces.
    let bare = [
        "<li>x</li>", "<td>x</td>", "<th>x</th>", "<tr><td>x</td></tr>",
        "<summary>s</summary>", "<div data-type=\"detailsContent\"><p>b</p></div>",
        "<li data-type=\"taskItem\" data-checked=\"true\">x</li>",
        "<img src=\"a.png\">", "<br>",
        "<span data-type=\"inline-math\" data-latex=\"x\">$x$</span>",
        "<span data-mention=\"u1\">@u1</span>",
        "<a href=\"Page\" data-wikilink=\"Page\">Page</a>",
    ]
    for html in bare {
        let d = try HTMLParser.parse(html, schema: schema)
        try d.check()
        try expect(d.childCount > 0, "\(html) produced an empty document")
    }
}

// MARK: - Structural coercion

test("HTML: a parsed document is always valid, whatever the fragment") {
    // Partial copies out of a page produce these: two cells, one bullet, a row
    // on its own. Parsed literally each puts a node somewhere no schema allows.
    let fragments = [
        "<li>item</li>",
        "<li>one</li><li>two</li>",
        "<td>cell</td>",
        "<td>a</td><td>b</td>",
        "<tr><td>a</td></tr>",
        "<tr><td>a</td></tr><tr><td>b</td></tr>",
        "<th>head</th>",
        "<summary>title</summary>",
        "<dt>term</dt><dd>definition</dd>",
        "bare text",
        "<span>inline only</span>",
        "<b>bold</b> and <i>italic</i>",
        "",
        "<div></div>",
        "<table><td>skipped row</td></table>",
        "<ul><p>not an item</p></ul>",
    ]
    for html in fragments {
        let d = try HTMLParser.parse(html, schema: schema)
        // The point of the whole pass: what comes back can be handed to the
        // editor without it having to defend itself.
        try d.check()
    }
}

test("HTML: a stray list item becomes a list") {
    try expectEqual(try HTMLParser.parse("<li>item</li>", schema: schema),
                    doc(node("bulletList", [:], [node("listItem", [:], [p("item")])])))
}

test("HTML: adjacent stray list items share one list") {
    let d = try HTMLParser.parse("<li>one</li><li>two</li>", schema: schema)
    try expectEqual(d, doc(node("bulletList", [:], [
        node("listItem", [:], [p("one")]),
        node("listItem", [:], [p("two")]),
    ])), "two loose items are one list of two, not two lists of one")
}

test("HTML: a stray table cell gets the table and row it needs") {
    let d = try HTMLParser.parse("<td>cell</td>", schema: schema)
    try expectEqual(shape(d), ["table", "tableRow", "tableCell", "paragraph"])
    try expectEqual(d.textContent, "cell")
}

test("HTML: adjacent stray cells share one row") {
    let d = try HTMLParser.parse("<td>a</td><td>b</td>", schema: schema)
    try expectEqual(shape(d), ["table", "tableRow", "tableCell", "paragraph", "tableCell", "paragraph"],
                    "one row of two cells")
}

test("HTML: a stray row gets its table") {
    let d = try HTMLParser.parse("<tr><td>a</td></tr><tr><td>b</td></tr>", schema: schema)
    try expectEqual(Array(shape(d)[0..<2]), ["table", "tableRow"])
    try expectEqual(shape(d).filter { $0 == "table" }.count, 1, "both rows in one table")
    try expectEqual(shape(d).filter { $0 == "tableRow" }.count, 2)
}

test("HTML: an element with no place here keeps its content") {
    // `detailsSummary` can't sit at the top level and can't be wrapped into one,
    // so the pass falls back to what was inside it.
    let d = try HTMLParser.parse("<summary>title</summary>", schema: schema)
    try d.check()
    try expectEqual(d.textContent, "title")
    // Same for elements the parser has no mapping for at all.
    try expectEqual(try HTMLParser.parse("<dt>term</dt><dd>definition</dd>", schema: schema).textContent,
                    "termdefinition")
}

test("HTML: coercion doesn't disturb markup that was already valid") {
    // The pass runs on every parse, so the ordinary shapes must come through
    // with exactly the structure they had — no wrapper the fitter added on the
    // way past, nothing reordered.
    let cases: [(String, [String])] = [
        ("<p>a</p>", ["paragraph"]),
        ("<h2>Title</h2><p>body</p>", ["heading", "paragraph"]),
        ("<ul><li>one</li><li>two</li></ul>",
         ["bulletList", "listItem", "paragraph", "listItem", "paragraph"]),
        ("<ol><li>one</li></ol>", ["orderedList", "listItem", "paragraph"]),
        ("<blockquote><p>quoted</p></blockquote>", ["blockquote", "paragraph"]),
        ("<table><tr><td>a</td><td>b</td></tr></table>",
         ["table", "tableRow", "tableCell", "paragraph", "tableCell", "paragraph"]),
        ("<pre><code>code</code></pre>", ["codeBlock"]),
        ("<hr>", ["horizontalRule"]),
    ]
    for (html, expected) in cases {
        let d = try HTMLParser.parse(html, schema: schema)
        try d.check()
        try expectEqual(shape(d), expected, "\(html) came back restructured")
        // And the result is a fixed point: serializing and re-parsing it changes
        // nothing. (The serialized form isn't always byte-identical to the
        // input — `<li>one</li>` is shorthand for a list item holding a
        // paragraph — but the document it describes is.)
        try expectEqual(try HTMLParser.parse(HTMLSerializer.serialize(d), schema: schema), d,
                        "\(html) isn't stable across a round-trip")
    }
}

test("HTML: a mis-nested list item is fitted rather than dropped") {
    // A `<p>` directly inside a `<ul>` isn't legal content for a list.
    let d = try HTMLParser.parse("<ul><p>loose</p><li>item</li></ul>", schema: schema)
    try d.check()
    try expect(d.textContent.contains("loose"), "the paragraph's text survives: \(d.textContent)")
    try expect(d.textContent.contains("item"))
}

test("HTML: an empty document still parses to something valid") {
    for html in ["", "   ", "<div></div>", "<!-- just a comment -->"] {
        let d = try HTMLParser.parse(html, schema: schema)
        try d.check()
        try expect(d.childCount >= 1, "a document is never empty: \(html)")
    }
}

test("HTML: a schema with no place for the content still yields a valid document") {
    // Paragraphs only — tables, lists and images have nowhere to go.
    let plain = try Schema(nodes: [
        ("doc", NodeSpec(content: "block+")),
        ("paragraph", NodeSpec(content: "inline*", group: "block")),
        ("text", NodeSpec(group: "inline")),
    ], marks: [], topNode: "doc")
    for html in ["<td>cell</td>", "<li>item</li>", "<table><tr><td>x</td></tr></table>",
                 "<ul><li>a</li><li>b</li></ul>", "<img src=\"a.png\">"] {
        let d = try HTMLParser.parse(html, schema: plain)
        try d.check()
    }
    // And the text is kept, not dropped on the floor.
    try expect(try HTMLParser.parse("<td>cell</td>", schema: plain).textContent.contains("cell"))
}

test("HTML: fragments round-trip once coerced") {
    // Having been fitted, the result is ordinary markup — parsing it again is
    // a no-op rather than another round of restructuring.
    for html in ["<li>item</li>", "<td>a</td><td>b</td>", "<tr><td>x</td></tr>", "bare text"] {
        let once = try HTMLParser.parse(html, schema: schema)
        let twice = try HTMLParser.parse(HTMLSerializer.serialize(once), schema: schema)
        try expectEqual(twice, once, "\(html) should be stable on a second pass")
    }
}

// MARK: - Inline content inside containers

test("HTML: inline markup inside a list item keeps its marks") {
    // `<li>` content was parsed as blocks, so each inline element became its own
    // unformatted paragraph — pasting a bulleted list from a page lost every
    // bold, link and italic in it.
    let d = try HTMLParser.parse("<ul><li>a <strong>bold</strong> c</li></ul>", schema: schema)
    try d.check()
    try expectEqual(d, doc(node("bulletList", tightList, [
        node("listItem", [:], [p(t("a "), strong("bold"), t(" c"))]),
    ])))
}

test("HTML: inline markup keeps its marks in every container") {
    let cases: [(String, [String], String)] = [
        ("<ul><li>a <strong>b</strong> c</li></ul>",
         ["bulletList", "listItem", "paragraph"], "bold"),
        ("<ol><li>a <em>b</em></li></ol>", ["orderedList", "listItem", "paragraph"], "italic"),
        ("<blockquote>a <em>b</em> c</blockquote>", ["blockquote", "paragraph"], "italic"),
        ("<table><tr><td>a <strong>b</strong></td></tr></table>",
         ["table", "tableRow", "tableCell", "paragraph"], "bold"),
        ("<table><tr><th>a <code>b</code></th></tr></table>",
         ["table", "tableRow", "tableHeader", "paragraph"], "code"),
    ]
    for (html, expectedShape, expectedMark) in cases {
        let d = try HTMLParser.parse(html, schema: schema)
        try d.check()
        try expectEqual(shape(d), expectedShape, "\(html) came back fragmented")
        var marks: Set<String> = []
        d.descendants { node, _, _, _ in
            for mark in node.marks { marks.insert(mark.type.name) }
            return true
        }
        try expect(marks.contains(expectedMark), "\(html) lost its \(expectedMark)")
    }
}

test("HTML: a bare inline fragment is one paragraph, not one per element") {
    // What a partial-selection copy out of a page produces.
    let d = try HTMLParser.parse("<strong>bold</strong> and <em>italic</em>", schema: schema)
    try d.check()
    try expectEqual(d, doc(p(strong("bold"), t(" and "), em("italic"))))
}

test("HTML: a link inside a list item survives with its href") {
    let d = try HTMLParser.parse(
        "<ul><li>see <a href=\"https://x.test\">this</a></li></ul>", schema: schema)
    try d.check()
    try expectEqual(firstHref(d), "https://x.test")
    try expectEqual(shape(d), ["bulletList", "listItem", "paragraph"])
}

test("HTML: an inline formula inside a list item stays in its paragraph") {
    let d = try HTMLParser.parse(
        "<ul><li>when <span data-type=\"inline-math\" data-latex=\"x^2\">$x^2$</span> holds</li></ul>",
        schema: schema)
    try d.check()
    try expectEqual(shape(d), ["bulletList", "listItem", "paragraph", "inlineMath"])
    try expectEqual(d.textContent, "when $x^2$ holds")
}

test("HTML: whitespace between blocks doesn't become a paragraph") {
    // Inline runs are now gathered up, so the newline between two blocks must
    // not be mistaken for content.
    for html in ["<p>a</p>\n<p>b</p>", "<p>a</p>   <p>b</p>", "<ul><li>a</li>\n<li>b</li></ul>"] {
        let d = try HTMLParser.parse(html, schema: schema)
        try d.check()
        try expect(!d.textContent.contains("\n"), "\(html) kept the separator as text")
        for i in 0..<d.childCount where d.child(i).type.name == "paragraph" {
            try expect(d.child(i).content.size > 0, "\(html) produced an empty paragraph")
        }
    }
    try expectEqual(shape(try HTMLParser.parse("<p>a</p>\n<p>b</p>", schema: schema)),
                    ["paragraph", "paragraph"])
}

test("HTML: block children of a container still parse as blocks") {
    // The grouping must not swallow real block structure.
    let d = try HTMLParser.parse("<ul><li><p>one</p><p>two</p></li></ul>", schema: schema)
    try d.check()
    try expectEqual(shape(d), ["bulletList", "listItem", "paragraph", "paragraph"])
}

test("HTML: mixed inline and block content in one container keeps both") {
    let d = try HTMLParser.parse("<blockquote>lead <strong>in</strong><p>then a block</p></blockquote>",
                                 schema: schema)
    try d.check()
    try expectEqual(shape(d), ["blockquote", "paragraph", "paragraph"])
    try expect(d.textContent.contains("lead in"), d.textContent)
    try expect(d.textContent.contains("then a block"), d.textContent)
    var marks: Set<String> = []
    d.descendants { node, _, _, _ in
        for mark in node.marks { marks.insert(mark.type.name) }
        return true
    }
    try expect(marks.contains("bold"), "the inline run keeps its mark")
}

test("HTML: an unknown container is still treated as one") {
    // Only known inline elements join a run; anything else keeps the old
    // treatment, so an unfamiliar wrapper can't be read as a line of text.
    let d = try HTMLParser.parse("<section><p>a</p><p>b</p></section>", schema: schema)
    try d.check()
    try expectEqual(shape(d), ["paragraph", "paragraph"])
}

test("HTML: a block image inside a list item is lifted, not dropped") {
    let d = try HTMLParser.parse("<ul><li>text <img src=\"a.png\"></li></ul>", schema: schema)
    try d.check()
    try expect(shape(d).contains("image"), "\(shape(d))")
    try expect(d.textContent.contains("text"), d.textContent)
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
    let d = doc(h(2, "Title"), p(t("a "), strong("b")), node("bulletList", tightList, [node("listItem", [:], [p("x")]), node("listItem", [:], [p("y")])]))
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
        node("bulletList", tightList, [node("listItem", [:], [p("a")]), node("listItem", [:], [p("b")])]),
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
    let d = doc(details("Items", [node("bulletList", tightList, [
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

test("HTML math decodes its source exactly once") {
    // The tokenizer already entity-decodes attribute values; decoding again
    // would turn an escaped `&lt;` in a formula into a real `<`.
    let d = try HTMLParser.parse(
        "<p><span data-type=\"inline-math\" data-latex=\"a &amp;lt; b\">$x$</span></p>", schema: schema)
    try expectEqual(d.child(0).child(0).attrs["latex"], .string("a &lt; b"))
    // And a single escape still round-trips through the serializer.
    let source = doc(p(inlineMath("a < b & \"c\"")))
    try expectEqual(try HTMLParser.parse(HTMLSerializer.serialize(source), schema: schema), source)
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

// Round-tripping math is the point of the $-conventions, so these cover the
// shapes that broke it: prose that merely contains dollars, formulas that
// contain a delimiter, empty formulas, and math nested in a list.

// Text that happens to contain Markdown's delimiters used to come back as
// markup — or, when a delimiter pair was consumed as an empty mark, as nothing.

test("Markdown round-trip: prose containing inline delimiters") {
    for text in ["snake_case_name", "2 * 3 * 4", "a_b_c", "5 * 5 = 25",
                 "use `a`b` here", "====", "~~~", "see [1] and [2]",
                 "a [link](not) here", "x = y == z", "back\\slash", "*", "_", "`",
                 "**not bold**", "__not italic__", "==not marked==", "~~not struck~~"] {
        let d = doc(p(text))
        let md = MarkdownSerializer.serialize(d)
        try expectEqual(try MarkdownParser.parse(md, schema: schema), d, "text: \(text)")
    }
}

test("Markdown round-trip: delimiters inside marked text") {
    // A mark's content is lifted out as a raw substring, so it needs escapes
    // resolved the same way the top-level scanner resolves them — and a closing
    // delimiter has to skip an escaped one.
    let d = doc(p(t("a "), strong("bold * with _ marks"), t(" and "), em("it * al"),
                  t(" and "), schema.text("k", [schema.mark("link", ["href": .string("u")])])))
    try expectEqual(try MarkdownParser.parse(MarkdownSerializer.serialize(d), schema: schema), d)
}

test("Markdown: a code span keeps its content literal") {
    // CommonMark doesn't resolve escapes inside code spans, so we don't escape
    // on the way out either.
    let d = doc(p(schema.text("a_b * c", [schema.mark("code")])))
    try expectEqual(MarkdownSerializer.serialize(d), "`a_b * c`")
    try expectEqual(try MarkdownParser.parse(MarkdownSerializer.serialize(d), schema: schema), d)
}

test("Markdown: a lone = or ~ is not escaped") {
    // They only mean anything doubled, so ordinary prose stays readable.
    try expectEqual(MarkdownSerializer.serialize(doc(p("x = y ~ z"))), "x = y ~ z")
    try expectEqual(MarkdownSerializer.serialize(doc(p("a == b"))), "a \\=\\= b")
}

test("Markdown: an empty delimiter pair is text, not an empty mark") {
    // "====" used to become two empty highlights and lose the text entirely.
    // ("****" and "~~~~" are a thematic break and a fence — covered separately.)
    for (md, text) in [("====", "===="), ("``", "``"), ("__", "__")] {
        let d = try MarkdownParser.parse(md, schema: schema)
        try expectEqual(d.child(0).textContent, text, "input: \(md)")
        try expect(d.child(0).child(0).marks.isEmpty, "input \(md) produced a mark")
    }
}

// MARK: - CommonMark constructs

// A batch of small corrections, each independent of the others.

test("Markdown: an indented line continues a paragraph rather than interrupting it") {
    // Four columns in would be code, and code can't interrupt a paragraph — so
    // the indented line is a lazy continuation whatever it would otherwise be.
    try expectEqual(try MarkdownParser.parse("Foo\n    ***", schema: schema), doc(p("Foo ***")))
    try expectEqual(try MarkdownParser.parse("foo\n    # bar", schema: schema), doc(p("foo # bar")))
    try expectEqual(try MarkdownParser.parse("Foo\n    ---", schema: schema), doc(p("Foo ---")))
    // With a blank line between, it is a block of its own again.
    try expectEqual(try MarkdownParser.parse("Foo\n\n    ***", schema: schema),
                    doc(p("Foo"), node("codeBlock", [:], [t("***")])))
}

test("Markdown: indented content in a quote leaves no paragraph to continue") {
    // "> foo" leaves one open, so the next line continues it...
    try expectEqual(try MarkdownParser.parse("> foo\n    - bar", schema: schema),
                    doc(node("blockquote", [:], [p("foo - bar")])))
    // ...but ">     foo" is code inside the quote, so it doesn't.
    let d = try MarkdownParser.parse(">     foo\n    bar", schema: schema)
    try expectEqual(d.childCount, 2)
    try expectEqual(d.child(0).type.name, "blockquote")
    try expectEqual(d.child(1).type.name, "codeBlock")
}

test("Markdown: a definition has to begin a block") {
    // Otherwise an ordinary paragraph containing brackets would vanish into one.
    let d = try MarkdownParser.parse("Foo\n[bar]: /baz\n\n[bar]", schema: schema)
    try expectNil(firstLink(d))
    try expect(d.child(0).textContent.contains("[bar]: /baz"), "the line vanished")
}

test("Markdown: a definition's line must hold nothing else") {
    for md in ["[foo]: /url \"title\" ok\n\n[foo]", "[foo]: /url junk here\n\n[foo]"] {
        let d = try MarkdownParser.parse(md, schema: schema)
        try expect(firstLink(d) == nil, "parsed as a definition: \(md)")
    }
}

test("Markdown resolves backslash escapes in destinations, titles and info strings") {
    let d = try MarkdownParser.parse("[foo](/bar\\* \"ti\\*tle\")", schema: schema)
    try expectEqual(firstLink(d)?.attrs["href"], .string("/bar*"))
    try expectEqual(firstLink(d)?.attrs["title"], .string("ti*tle"))
    let ref = try MarkdownParser.parse("[foo]\n\n[foo]: /bar\\* \"ti\\*tle\"", schema: schema)
    try expectEqual(firstLink(ref)?.attrs["href"], .string("/bar*"))
    try expectEqual(try MarkdownParser.parse("``` foo\\+bar\nx\n```", schema: schema)
                        .child(0).attrs["language"], .string("foo+bar"))
}

test("Markdown round-trip: a destination or title containing a backslash") {
    // The reader takes escapes off, so the writer has to put them on.
    let d = doc(p(schema.text("x", [schema.mark("link", [
        "href": .string("/a\\b"), "title": .string("t\\u")])])))
    try expectEqual(try MarkdownParser.parse(MarkdownSerializer.serialize(d), schema: schema), d)
}

test("Markdown: a whitespace-only line inside indented code keeps its content") {
    let d = try MarkdownParser.parse("    chunk1\n      \n      chunk2", schema: schema)
    try expectEqual(d.child(0).type.name, "codeBlock")
    try expectEqual(d.child(0).textContent, "chunk1\n  \n  chunk2")
}

test("Markdown: a definition inside a quote belongs to the document") {
    let d = try MarkdownParser.parse("[foo]\n\n> [foo]: /url", schema: schema)
    try expectEqual(firstLink(d)?.attrs["href"], .string("/url"))
}

test("Markdown reads a definition whose label runs across lines") {
    let d = try MarkdownParser.parse("[\nfoo\n]: /url\n\n[foo]", schema: schema)
    try expectEqual(firstLink(d)?.attrs["href"], .string("/url"))
    // An unclosed label isn't a definition at all.
    let open = try MarkdownParser.parse("[foo\nbar\n\n[foo]", schema: schema)
    try expectNil(firstLink(open))
}

test("Markdown parses thematic breaks in every spelling") {
    for md in ["---", "***", "___", "* * *", "- - -", "_____", " ***", "-----"] {
        let d = try MarkdownParser.parse(md, schema: schema)
        try expectEqual(d.childCount, 1, "input: \(md)")
        try expectEqual(d.child(0).type.name, "horizontalRule", "input: \(md)")
    }
    // Two isn't enough, and a mixed run isn't a break.
    try expectEqual(try MarkdownParser.parse("--", schema: schema).child(0).type.name, "paragraph")
    try expectEqual(try MarkdownParser.parse("-*-", schema: schema).child(0).type.name, "paragraph")
}

test("Markdown: a closing fence must be at least as long as the opening one") {
    // Which is how a block can contain a shorter run of its own character.
    try expectEqual(try MarkdownParser.parse("````\naaa\n```\n``````", schema: schema),
                    doc(node("codeBlock", [:], [t("aaa\n```")])))
    try expectEqual(try MarkdownParser.parse("~~~~\naaa\n~~~\n~~~~", schema: schema),
                    doc(node("codeBlock", [:], [t("aaa\n~~~")])))
}

test("Markdown: a closing fence carries nothing but its own character") {
    // "```ruby" opens a block; it can't also close one.
    let d = try MarkdownParser.parse("```\naaa\n```ruby\nbbb\n```", schema: schema)
    try expectEqual(d.childCount, 1)
    try expectEqual(d.child(0).textContent, "aaa\n```ruby\nbbb")
}

test("Markdown: an unclosed fence runs to the end") {
    try expectEqual(try MarkdownParser.parse("```\naaa\nbbb", schema: schema),
                    doc(node("codeBlock", [:], [t("aaa\nbbb")])))
}

test("Markdown: an indented fence takes that indentation off its content") {
    // Up to three columns opens a fence; the content keeps whatever it has
    // beyond the fence's own indentation.
    try expectEqual(try MarkdownParser.parse("  ```\n  aaa\n    bbb\n  ```", schema: schema),
                    doc(node("codeBlock", [:], [t("aaa\n  bbb")])))
}

test("Markdown round-trip: a fence's info string names the language") {
    let d = try MarkdownParser.parse("```swift\nlet x = 1\n```", schema: schema)
    try expectEqual(d.child(0).attrs["language"], .string("swift"))
    try expectEqual(MarkdownSerializer.serialize(d), "```swift\nlet x = 1\n```")
    try expectEqual(try MarkdownParser.parse(MarkdownSerializer.serialize(d), schema: schema), d)
    // Only the first word is the language, and references in it are resolved.
    try expectEqual(try MarkdownParser.parse("``` swift extra\nx\n```", schema: schema)
                        .child(0).attrs["language"], .string("swift"))
    try expectEqual(try MarkdownParser.parse("``` f&ouml;&ouml;\nx\n```", schema: schema)
                        .child(0).attrs["language"], .string("föö"))
}

test("HTML round-trip: a code block's language") {
    let d = try MarkdownParser.parse("```swift\nlet x = 1\n```", schema: schema)
    let html = HTMLSerializer.serialize(d)
    try expect(html.contains("<code class=\"language-swift\">"), "got: \(html)")
    try expectEqual(try HTMLParser.parse(html, schema: schema), d)
    // A block with no language doesn't grow an empty class.
    let plain = try MarkdownParser.parse("```\nx\n```", schema: schema)
    try expect(!HTMLSerializer.serialize(plain).contains("class="),
               "got: \(HTMLSerializer.serialize(plain))")
}

test("Markdown parses a ~~~ fence, including one holding backticks") {
    try expectEqual(try MarkdownParser.parse("~~~\na + b\n~~~", schema: schema),
                    doc(node("codeBlock", [:], [t("a + b")])))
    // A fence closes on its own character, so each can contain the other.
    try expectEqual(try MarkdownParser.parse("~~~\n```\n~~~", schema: schema),
                    doc(node("codeBlock", [:], [t("```")])))
    try expectEqual(try MarkdownParser.parse("```\n~~~\n```", schema: schema),
                    doc(node("codeBlock", [:], [t("~~~")])))
}

test("Markdown strips an ATX heading's closing run and spacing") {
    try expectEqual(try MarkdownParser.parse("## foo ##", schema: schema), doc(h(2, "foo")))
    try expectEqual(try MarkdownParser.parse("#      foo      ", schema: schema), doc(h(1, "foo")))
    try expectEqual(try MarkdownParser.parse("# foo #################", schema: schema), doc(h(1, "foo")))
    // A hash that isn't a trailing run is part of the text.
    try expectEqual(try MarkdownParser.parse("# foo #bar", schema: schema), doc(h(1, "foo #bar")))
}

test("Markdown parses a hard break from two trailing spaces") {
    let d = try MarkdownParser.parse("foo  \nbaz", schema: schema)
    try expectEqual(d, doc(p(t("foo"), node("hardBreak", [:], []), t("baz"))))
    // More than two also counts; exactly one is a soft wrap.
    try expectEqual(try MarkdownParser.parse("foo     \nbaz", schema: schema), d)
    try expectEqual(try MarkdownParser.parse("foo \nbaz", schema: schema), doc(p("foo baz")))
}

test("Markdown parses autolinks") {
    for url in ["http://foo.bar.baz", "https://foo.bar/test?q=1", "mailto:a@b.test"] {
        let d = try MarkdownParser.parse("<\(url)>", schema: schema)
        let text = d.child(0).child(0)
        try expectEqual(text.text, url, "input: \(url)")
        try expectEqual(text.marks.first?.attrs["href"], .string(url), "input: \(url)")
    }
    // Not autolinks: no scheme, a space inside, or ordinary comparison text.
    for md in ["<foo.bar>", "<http://foo bar>", "a < b and c > d"] {
        let d = try MarkdownParser.parse(md, schema: schema)
        try expect(d.child(0).child(0).marks.isEmpty, "input \(md) became a link")
    }
    // A scheme the URL sanitizer rejects stays text — Markdown arrives from the
    // same untrusted places HTML does.
    for md in ["<javascript:alert(1)>", "<irc://foo.bar/baz>"] {
        let d = try MarkdownParser.parse(md, schema: schema)
        try expect(d.child(0).child(0).marks.isEmpty, "input \(md) became a link")
    }
}

test("Markdown round-trip: a link and image title") {
    let link = doc(p(schema.text("x", [schema.mark("link", ["href": .string("/uri"),
                                                            "title": .string("the title")])])))
    try expectEqual(MarkdownSerializer.serialize(link), "[x](/uri \"the title\")")
    try expectEqual(try MarkdownParser.parse(MarkdownSerializer.serialize(link), schema: schema), link)

    let parsed = try MarkdownParser.parse("[x](/uri \"t\")", schema: schema)
    try expectEqual(parsed.child(0).child(0).marks.first?.attrs["href"], .string("/uri"))
    try expectEqual(parsed.child(0).child(0).marks.first?.attrs["title"], .string("t"))
    // Single quotes too. (The `(title)` spelling is not supported: the
    // destination scan ends at the first ")", so it would need balanced-paren
    // scanning for the rarest of the three forms.)
    for md in ["[x](/uri 't')"] {
        let d = try MarkdownParser.parse(md, schema: schema)
        try expectEqual(d.child(0).child(0).marks.first?.attrs["title"], .string("t"), "input: \(md)")
    }
}

test("Markdown parses an angle-bracketed link destination") {
    let d = try MarkdownParser.parse("[x](</my uri>)", schema: schema)
    // CommonMark percent-encodes the space; we keep destinations as written,
    // as the HTML parser does, so the space survives instead.
    try expectEqual(d.child(0).child(0).marks.first?.attrs["href"], .string("/my uri"))
}

test("Markdown decodes a long numeric reference") {
    // The search for the ";" is bounded so that '&'-dense text doesn't go
    // quadratic; a zero-padded reference is longer than a name and used to fall
    // outside that bound.
    try expectEqual(try MarkdownParser.parse("&#x0001F600;", schema: schema).child(0).textContent,
                    "\u{1F600}")
    try expectEqual(try MarkdownParser.parse("&#000035;", schema: schema).child(0).textContent, "#")
}

test("Markdown: a reference to no character becomes the replacement one") {
    for md in ["&#0;", "&#x110000;", "&#xD800;"] {
        try expectEqual(try MarkdownParser.parse(md, schema: schema).child(0).textContent,
                        "\u{FFFD}", "input: \(md)")
    }
}

test("Markdown decodes references in a link's destination and title") {
    let d = try MarkdownParser.parse("[foo](/f&ouml;&ouml; \"t&ouml;\")", schema: schema)
    let link = d.child(0).child(0).marks.first
    try expectEqual(link?.attrs["href"], .string("/föö"))
    try expectEqual(link?.attrs["title"], .string("tö"))
    // And in a definition, which shares the same splitting.
    let ref = try MarkdownParser.parse("[foo]\n\n[foo]: /b&auml;r \"t&auml;\"", schema: schema)
    try expectEqual(ref.child(0).child(0).marks.first?.attrs["href"], .string("/bär"))
    try expectEqual(ref.child(0).child(0).marks.first?.attrs["title"], .string("tä"))
}

test("Markdown: an entity can't stand in for a title's quotes") {
    // The reference is text, so this has no title — which leaves a destination
    // containing spaces, and that isn't a link at all.
    let d = try MarkdownParser.parse("[a](url &quot;tit&quot;)", schema: schema)
    try expectEqual(d.child(0).textContent, "[a](url \"tit\")")
    try expect(d.child(0).child(0).marks.isEmpty, "parsed as a link")
    // A destination with spaces needs angle brackets, which still work.
    try expectEqual(try MarkdownParser.parse("[a](<url with spaces>)", schema: schema)
                        .child(0).child(0).marks.first?.attrs["href"], .string("url with spaces"))
}

test("Markdown decodes character references") {
    let d = try MarkdownParser.parse("&amp; &copy; &#35; &#x22; &nbsp;", schema: schema)
    try expectEqual(d.child(0).textContent, "& © # \" \u{00A0}")
    // An unknown reference stays literal rather than being mangled.
    try expectEqual(try MarkdownParser.parse("&bogus; &", schema: schema).child(0).textContent,
                    "&bogus; &")
}

test("Markdown round-trip: text that looks like a character reference") {
    // Decoding means "&amp;" is now markup, so the serializer escapes "&" to
    // keep literal text literal.
    for text in ["&amp; and &copy;", "a & b", "&#35;", "AT&T"] {
        let d = doc(p(text))
        try expectEqual(try MarkdownParser.parse(MarkdownSerializer.serialize(d), schema: schema), d,
                        "text: \(text)")
    }
}

test("Markdown round-trip: text that looks like an autolink") {
    for text in ["<https://example.test>", "a < b", "use <div> here"] {
        let d = doc(p(text))
        try expectEqual(try MarkdownParser.parse(MarkdownSerializer.serialize(d), schema: schema), d,
                        "text: \(text)")
    }
}

// Link reference definitions: a destination defined once and referred to by
// label. The definition itself is metadata and must not appear in the document.

func firstLink(_ d: Node) -> Mark? {
    var found: Mark?
    d.descendants { node, _, _, _ in
        if found == nil { found = node.marks.first { $0.type.name == "link" } }
        return found == nil
    }
    return found
}

test("Markdown resolves the three reference forms") {
    let definition = "\n\n[foo]: /url \"the title\""
    // Full, collapsed, and shortcut.
    for md in ["[text][foo]", "[foo][]", "[foo]"] {
        let d = try MarkdownParser.parse(md + definition, schema: schema)
        try expectEqual(firstLink(d)?.attrs["href"], .string("/url"), "input: \(md)")
        try expectEqual(firstLink(d)?.attrs["title"], .string("the title"), "input: \(md)")
    }
    // The displayed text is the first bracket's contents.
    try expectEqual(try MarkdownParser.parse("[text][foo]" + definition, schema: schema)
                        .child(0).textContent, "text")
    try expectEqual(try MarkdownParser.parse("[foo]" + definition, schema: schema)
                        .child(0).textContent, "foo")
}

test("Markdown removes a definition from the document") {
    let d = try MarkdownParser.parse("[foo]: /url\n\nSee [foo].", schema: schema)
    try expectEqual(d.childCount, 1, "the definition left a block behind")
    try expectEqual(d.child(0).textContent, "See foo.")
    try expect(!d.textContent.contains("/url"), "definition leaked: \(d.textContent)")
}

test("Markdown resolves a reference that appears before its definition") {
    // The reason definitions are collected in a pass of their own.
    let d = try MarkdownParser.parse("See [foo].\n\n[foo]: /url", schema: schema)
    try expectEqual(firstLink(d)?.attrs["href"], .string("/url"))
}

test("Markdown matches labels case-insensitively and ignoring whitespace") {
    for reference in ["[FOO]", "[Foo]", "[foo  bar]"] {
        let d = try MarkdownParser.parse(reference + "\n\n[Foo Bar]: /url\n[foo]: /url",
                                         schema: schema)
        try expect(firstLink(d) != nil, "no link for \(reference)")
    }
}

test("Markdown leaves an unmatched reference as text") {
    // Nothing defines [bar], so the brackets are ordinary characters.
    let d = try MarkdownParser.parse("see [bar] here", schema: schema)
    try expectEqual(d.child(0).textContent, "see [bar] here")
    try expectNil(firstLink(d))
}

test("Markdown reads a definition spread across lines") {
    // Label, destination and title may each sit on their own line, indented.
    let d = try MarkdownParser.parse(
        "   [foo]: \n      /url  \n           'the title'  \n\n[foo]", schema: schema)
    try expectEqual(d.childCount, 1, "the definition left blocks behind")
    let link = firstLink(d)
    try expectEqual(link?.attrs["href"], .string("/url"))
    try expectEqual(link?.attrs["title"], .string("the title"))
}

test("Markdown reads a definition's title across lines") {
    let d = try MarkdownParser.parse("[foo]: /url 'title\nline1\nline2'\n\n[foo]", schema: schema)
    try expectEqual(firstLink(d)?.attrs["title"], .string("title\nline1\nline2"))
    try expectEqual(firstLink(d)?.attrs["href"], .string("/url"))
}

test("Markdown: a blank line inside a title unmakes the definition") {
    // Not a definition with the title dropped — not a definition at all, since
    // the destination is followed on its line by something that isn't a title.
    // (This corrected an assertion of mine from #47; the spec's own example
    // keeps all three lines as paragraphs.)
    let d = try MarkdownParser.parse("[foo]: /url 'title\n\nwith blank line'\n\n[foo]",
                                     schema: schema)
    try expectNil(firstLink(d))
    try expect(d.textContent.contains("[foo]: /url 'title"), "lost the text: \(d.textContent)")
    try expect(d.textContent.contains("with blank line'"), "lost the text: \(d.textContent)")
}

test("Markdown: an angle-bracketed destination on its own line") {
    let d = try MarkdownParser.parse("[foo]:\n<my uri>\n\n[foo]", schema: schema)
    try expectEqual(firstLink(d)?.attrs["href"], .string("my uri"))
}

test("Markdown: text after the title unmakes the definition") {
    // Everything after the destination has to be a title and nothing else, so
    // this is an ordinary paragraph that happens to contain brackets.
    let d = try MarkdownParser.parse("[foo]: /url \"title\" not a title\n\n[foo]", schema: schema)
    try expectNil(firstLink(d))
    try expect(d.textContent.contains("[foo]: /url \"title\" not a title"),
               "lost the text: \(d.textContent)")
}

test("Markdown reads a definition's title from the following line") {
    let d = try MarkdownParser.parse("[foo]: /url\n\"the title\"\n\nSee [foo].", schema: schema)
    try expectEqual(firstLink(d)?.attrs["title"], .string("the title"))
}

test("Markdown takes the first definition of a label") {
    let d = try MarkdownParser.parse("[foo]: /first\n[foo]: /second\n\n[foo]", schema: schema)
    try expectEqual(firstLink(d)?.attrs["href"], .string("/first"))
}

test("Markdown: a definition inside code is content, not a definition") {
    // Both fenced and indented — the reference then has nothing to resolve to.
    for md in ["```\n[foo]: /url\n```\n\n[foo]", "    [foo]: /url\n\n[foo]"] {
        let d = try MarkdownParser.parse(md, schema: schema)
        try expect(firstLink(d) == nil, "resolved a link it shouldn't have: \(md)")
        try expect(d.textContent.contains("[foo]: /url"), "definition vanished: \(md)")
    }
}

test("Markdown resolves an image by reference") {
    let d = try MarkdownParser.parse("![alt][foo]\n\n[foo]: /img.png \"t\"", schema: schema)
    var image: Node?
    d.descendants { node, _, _, _ in
        if node.type.name == "image" { image = node }
        return image == nil
    }
    try expect(image != nil, "no image")
    try expectEqual(image?.attrs["src"], .string("/img.png"))
    try expectEqual(image?.attrs["alt"], .string("alt"))
    try expectEqual(image?.attrs["title"], .string("t"))
}

test("Markdown resolves a reference inside a blockquote") {
    // A nested parse inherits the definitions collected outside it.
    let d = try MarkdownParser.parse("> See [foo].\n\n[foo]: /url", schema: schema)
    try expectEqual(d.child(0).type.name, "blockquote")
    try expectEqual(firstLink(d)?.attrs["href"], .string("/url"))
}

test("Markdown round-trip: references are written as inline links") {
    // We have no reason to emit definitions, so both spellings converge.
    let d = try MarkdownParser.parse("[text][foo]\n\n[foo]: /url \"t\"", schema: schema)
    try expectEqual(MarkdownSerializer.serialize(d), "[text](/url \"t\")")
    try expectEqual(try MarkdownParser.parse(MarkdownSerializer.serialize(d), schema: schema), d)
}

test("Markdown round-trip: a bang directly before a link") {
    // "!" then a link reads back as an image unless the bang is escaped.
    let d = doc(p(t("wow!"), schema.text("x", [schema.mark("link", ["href": .string("/u")])])))
    try expectEqual(try MarkdownParser.parse(MarkdownSerializer.serialize(d), schema: schema), d)
}

test("Markdown round-trip: parentheses in a destination and title") {
    // The link's closing ")" is found past an angle destination and a quoted
    // title, both of which may contain one.
    let d = doc(p(schema.text("x", [schema.mark("link", [
        "href": .string("my_(url)"), "title": .string("title (with parens)")])])))
    try expectEqual(try MarkdownParser.parse(MarkdownSerializer.serialize(d), schema: schema), d)
    try expectEqual(try MarkdownParser.parse("[x](/uri (title))", schema: schema)
                        .child(0).child(0).marks.first?.attrs["title"], .string("title"))
}

test("Markdown continues a blockquote's paragraph without the marker") {
    // CommonMark's lazy continuation: the second line has no ">" but continues
    // the paragraph inside the quote.
    try expectEqual(try MarkdownParser.parse("> bar\nbaz", schema: schema),
                    doc(node("blockquote", [:], [p("bar baz")])))
    try expectEqual(try MarkdownParser.parse("> bar\nbaz\n> foo", schema: schema),
                    doc(node("blockquote", [:], [p("bar baz foo")])))
    // A heading inside the quote still ends at its own line.
    try expectEqual(try MarkdownParser.parse("> # Foo\n> bar\nbaz", schema: schema),
                    doc(node("blockquote", [:], [h(1, "Foo"), p("bar baz")])))
}

test("Markdown: a lazy line can't start a block inside a quote") {
    // Only a paragraph continues lazily; anything that begins a block ends the
    // quote instead.
    try expectEqual(try MarkdownParser.parse("> bar\n- baz", schema: schema),
                    doc(node("blockquote", [:], [p("bar")]),
                        node("bulletList", tightList, [node("listItem", [:], [p("baz")])])))
    try expectEqual(try MarkdownParser.parse("> foo\n---", schema: schema),
                    doc(node("blockquote", [:], [p("foo")]),
                        node("horizontalRule", [:], [])))
    try expectEqual(try MarkdownParser.parse("> foo\n# bar", schema: schema),
                    doc(node("blockquote", [:], [p("foo")]), h(1, "bar")))
    // A blank line ends the quote outright.
    try expectEqual(try MarkdownParser.parse("> bar\n\nbaz", schema: schema),
                    doc(node("blockquote", [:], [p("bar")]), p("baz")))
    // A list inside the quote isn't continued by an unprefixed marker either.
    try expectEqual(try MarkdownParser.parse("> - foo\n- bar", schema: schema),
                    doc(node("blockquote", [:], [
                            node("bulletList", tightList, [node("listItem", [:], [p("foo")])])]),
                        node("bulletList", tightList, [node("listItem", [:], [p("bar")])])))
}

test("Markdown round-trip: a quote written with lazy continuation") {
    // We always write the marker on every line, so both spellings converge.
    let d = try MarkdownParser.parse("> bar\nbaz", schema: schema)
    try expectEqual(MarkdownSerializer.serialize(d), "> bar baz")
    try expectEqual(try MarkdownParser.parse(MarkdownSerializer.serialize(d), schema: schema), d)
}

test("Markdown parses setext headings") {
    try expectEqual(try MarkdownParser.parse("Foo\n===", schema: schema), doc(h(1, "Foo")))
    try expectEqual(try MarkdownParser.parse("Foo\n---", schema: schema), doc(h(2, "Foo")))
    // Any length of underline, and up to three columns of indentation.
    try expectEqual(try MarkdownParser.parse("Foo\n=", schema: schema), doc(h(1, "Foo")))
    try expectEqual(try MarkdownParser.parse("Foo\n--", schema: schema), doc(h(2, "Foo")))
    try expectEqual(try MarkdownParser.parse("Foo\n   ---", schema: schema), doc(h(2, "Foo")))
    // A multi-line paragraph becomes one heading.
    try expectEqual(try MarkdownParser.parse("Foo\nbar\n===", schema: schema), doc(h(1, "Foo bar")))
    // Inline markup in the heading survives.
    try expectEqual(try MarkdownParser.parse("Foo *bar*\n===", schema: schema),
                    doc(node("heading", ["level": .int(1)], [t("Foo "), em("bar")])))
}

test("Markdown: a dashed line is a heading under a paragraph and a break elsewhere") {
    // The ambiguity CommonMark resolves in setext's favour.
    try expectEqual(try MarkdownParser.parse("Foo\n---", schema: schema), doc(h(2, "Foo")))
    // With a blank line it starts its own block, so it's a thematic break.
    try expectEqual(try MarkdownParser.parse("Foo\n\n---", schema: schema),
                    doc(p("Foo"), node("horizontalRule", [:], [])))
    // And on its own it's still a break.
    try expectEqual(try MarkdownParser.parse("---", schema: schema),
                    doc(node("horizontalRule", [:], [])))
    // An underline can't turn a list or a quote into a heading.
    try expectEqual(try MarkdownParser.parse("- foo\n---", schema: schema).child(1).type.name,
                    "horizontalRule")
}

test("Markdown: an underline only follows a paragraph") {
    // Four columns of indentation is code, not an underline.
    try expectEqual(try MarkdownParser.parse("Foo\n\n    ===", schema: schema),
                    doc(p("Foo"), node("codeBlock", [:], [t("===")])))
    // A run of mixed characters isn't an underline.
    try expectEqual(try MarkdownParser.parse("Foo\n=-=", schema: schema), doc(p("Foo =-=")))
}

test("Markdown round-trip: setext headings serialize as ATX") {
    // Both spellings mean the same node, and we write the ATX one.
    for md in ["Foo\n===", "Foo\n---", "Foo *bar*\n==="] {
        let d = try MarkdownParser.parse(md, schema: schema)
        try expectEqual(try MarkdownParser.parse(MarkdownSerializer.serialize(d), schema: schema), d,
                        "input: \(md)")
    }
}

test("Markdown measures a list item's content column from its marker") {
    // "1.  x" puts content at column 4, not 3. Assuming one space left every
    // continuation line a space too deep, which showed up as indented code
    // inside an item gaining a stray leading space.
    let d = try MarkdownParser.parse("1.  A paragraph\n\n        indented code", schema: schema)
    let item = d.child(0).child(0)
    try expectEqual(item.child(item.childCount - 1).type.name, "codeBlock")
    try expectEqual(item.child(item.childCount - 1).textContent, "indented code")

    // Same for a bullet with extra spaces: content column 4, so a continuation
    // line indented four stays in the item.
    let bullet = try MarkdownParser.parse("-   foo\n\n    bar", schema: schema)
    try expectEqual(bullet.child(0).child(0).childCount, 2)
    try expectEqual(bullet.child(0).child(0).textContent, "foobar")
}

test("Markdown: a marker followed by many spaces starts indented code") {
    // Five or more spaces would make the content itself indented code, so the
    // content column is one past the marker rather than where the text begins.
    let d = try MarkdownParser.parse("-      foo", schema: schema)
    let item = d.child(0).child(0)
    // A `listItem` has to begin with a paragraph, so an item whose content is
    // only code carries an empty one in front of it.
    let last = item.child(item.childCount - 1)
    try expectEqual(last.type.name, "codeBlock", "got: \(last.type.name)")
    try expectEqual(last.textContent, " foo")
}

test("Markdown: an item's content column still includes its own indent") {
    // Two spaces of indent plus "- " is column 4.
    let d = try MarkdownParser.parse("  - foo\n\n    bar", schema: schema)
    try expectEqual(d.child(0).child(0).childCount, 2)
    try expectEqual(d.child(0).child(0).textContent, "foobar")
}

test("Markdown parses nested lists by indentation") {
    // An indented line that looks like a marker is the current item's content,
    // which is what makes it a nested list rather than a sibling.
    func shape(_ n: Node) -> [String] {
        var out = [n.type.name]
        for i in 0..<n.childCount where !n.child(i).isText { out += shape(n.child(i)) }
        return out
    }
    try expectEqual(shape(try MarkdownParser.parse("* foo\n\n  * bar", schema: schema)),
                    ["doc", "bulletList", "listItem", "paragraph", "bulletList", "listItem", "paragraph"])
    // Three levels, without blank lines between them.
    try expectEqual(shape(try MarkdownParser.parse("- a\n  - b\n    - c", schema: schema)),
                    ["doc", "bulletList", "listItem", "paragraph",
                     "bulletList", "listItem", "paragraph",
                     "bulletList", "listItem", "paragraph"])
    // An ordered list nests too, and a following unindented marker is a sibling.
    try expectEqual(shape(try MarkdownParser.parse("1. a\n   1. b", schema: schema)),
                    ["doc", "orderedList", "listItem", "paragraph",
                     "orderedList", "listItem", "paragraph"])
    try expectEqual(shape(try MarkdownParser.parse("- a\n- b", schema: schema)),
                    ["doc", "bulletList", "listItem", "paragraph", "listItem", "paragraph"])
}

test("Markdown round-trip: nested lists") {
    let d = doc(node("bulletList", tightList, [
        node("listItem", [:], [
            p("a"),
            node("bulletList", tightList, [node("listItem", [:], [p("b")])]),
        ]),
        node("listItem", [:], [p("c")]),
    ]))
    try expectEqual(try MarkdownParser.parse(MarkdownSerializer.serialize(d), schema: schema), d)

    let ordered = doc(node("orderedList", ["order": .int(1), "tight": .bool(true)], [
        node("listItem", [:], [
            p("a"),
            node("orderedList", ["order": .int(1), "tight": .bool(true)], [node("listItem", [:], [p("b")])]),
        ]),
    ]))
    try expectEqual(try MarkdownParser.parse(MarkdownSerializer.serialize(ordered), schema: schema),
                    ordered)
}

test("Markdown: an item's content column includes its own indent") {
    // " - foo" puts content at column 3, so "   - bar" nests inside it.
    let d = try MarkdownParser.parse(" - foo\n   - bar", schema: schema)
    try expectEqual(d.child(0).child(0).childCount, 2, "second level didn't nest")
    try expectEqual(d.child(0).child(0).child(1).type.name, "bulletList")
}

test("Markdown parses an indented code block") {
    try expectEqual(try MarkdownParser.parse("    foo", schema: schema),
                    doc(node("codeBlock", [:], [t("foo")])))
    try expectEqual(try MarkdownParser.parse("    a\n    b", schema: schema),
                    doc(node("codeBlock", [:], [t("a\nb")])))
    // Indentation beyond four columns is content.
    try expectEqual(try MarkdownParser.parse("        foo", schema: schema),
                    doc(node("codeBlock", [:], [t("    foo")])))
    // A tab reaches the fourth column just as four spaces do.
    try expectEqual(try MarkdownParser.parse("\tfoo", schema: schema),
                    doc(node("codeBlock", [:], [t("foo")])))
}

test("Markdown indentation wins over what the line would otherwise be") {
    for md in ["    ***", "    # not a heading", "    - not a list", "    > not a quote"] {
        let d = try MarkdownParser.parse(md, schema: schema)
        try expectEqual(d.child(0).type.name, "codeBlock", "input: \(md)")
        try expectEqual(d.child(0).textContent, String(md.dropFirst(4)), "input: \(md)")
    }
}

test("Markdown: an indented line cannot interrupt a paragraph") {
    // It's a lazy continuation of the paragraph, not a code block.
    try expectEqual(try MarkdownParser.parse("Foo\n    bar", schema: schema), doc(p("Foo bar")))
    // With a blank line between, it is a code block.
    try expectEqual(try MarkdownParser.parse("Foo\n\n    bar", schema: schema),
                    doc(p("Foo"), node("codeBlock", [:], [t("bar")])))
}

test("Markdown: blank lines inside an indented code block are kept, trailing ones aren't") {
    try expectEqual(try MarkdownParser.parse("    a\n\n    b", schema: schema),
                    doc(node("codeBlock", [:], [t("a\n\nb")])))
    try expectEqual(try MarkdownParser.parse("    a\n\n\nfoo", schema: schema),
                    doc(node("codeBlock", [:], [t("a")]), p("foo")))
}

test("Markdown: indented code inside a list item and a blockquote") {
    let list = try MarkdownParser.parse("- a\n\n      code", schema: schema)
    let item = list.child(0).child(0)
    try expectEqual(item.child(item.childCount - 1).type.name, "codeBlock")
    try expectEqual(item.child(item.childCount - 1).textContent, "code")

    let quote = try MarkdownParser.parse(">     foo", schema: schema)
    try expectEqual(quote.child(0).type.name, "blockquote")
    try expectEqual(quote.child(0).child(0).type.name, "codeBlock")
}

test("Markdown round-trip: a list item whose content is a code block") {
    // The schema makes a `listItem` start with a paragraph, so such an item
    // carries an empty one. Writing it out would put a blank line after the
    // marker and read back as something else.
    let d = doc(node("bulletList", tightList, [
        node("listItem", [:], [
            try schema.node("paragraph", [:]),
            node("codeBlock", [:], [t("x = 1")]),
        ]),
    ]))
    let md = MarkdownSerializer.serialize(d)
    try expect(!md.hasPrefix("- \n"), "blank line after the marker: \(md.debugDescription)")
    try expectEqual(try MarkdownParser.parse(md, schema: schema), d)
}

test("Markdown treats a tab as block structure where a space would be") {
    // CommonMark: "in contexts where spaces help define block structure, tabs
    // behave as if they were replaced by spaces with a tab stop of 4".
    try expectEqual(try MarkdownParser.parse("#\tFoo", schema: schema), doc(h(1, "Foo")))
    try expectEqual(try MarkdownParser.parse("-\tfoo", schema: schema),
                    doc(node("bulletList", tightList, [node("listItem", [:], [p("foo")])])))
    try expectEqual(try MarkdownParser.parse("1.\tfoo", schema: schema),
                    doc(node("orderedList", ["order": .int(1), "tight": .bool(true)], [
                        node("listItem", [:], [p("foo")])])))
    try expectEqual(try MarkdownParser.parse(">\tfoo", schema: schema),
                    doc(node("blockquote", [:], [p("foo")])))
    try expectEqual(try MarkdownParser.parse("*\t*\t*", schema: schema).child(0).type.name,
                    "horizontalRule")
}

test("Markdown expands a leading tab to a four-column stop") {
    // A tab-indented continuation line reaches the item's content column, so it
    // stays inside the item instead of ending the list.
    let d = try MarkdownParser.parse("- foo\n\n\tbar", schema: schema)
    try expectEqual(d.childCount, 1)
    try expectEqual(d.child(0).type.name, "bulletList")
    try expectEqual(d.child(0).child(0).childCount, 2, "continuation line left the item")
    try expectEqual(d.child(0).child(0).textContent, "foobar")
    // Spaces then a tab reach the same stop, so these behave identically.
    for indent in ["\t", "  \t", "   \t", "    "] {
        let same = try MarkdownParser.parse("- foo\n\n\(indent)bar", schema: schema)
        try expectEqual(same, d, "indent: \(indent.debugDescription)")
    }
    // The exact column an expanded tab lands on only becomes observable once
    // indented code blocks are supported; until then it is exercised through
    // the indentation decisions above.
}

test("Markdown leaves a tab inside the text alone") {
    // Only the indentation run is expanded — a tab in content is the author's.
    try expectEqual(try MarkdownParser.parse("a\tb", schema: schema).child(0).textContent, "a\tb")
    let code = try MarkdownParser.parse("```\na\tb\n```", schema: schema)
    try expectEqual(code.child(0).textContent, "a\tb")
}

func marksOf(_ d: Node) -> [[String]] {
    var out: [[String]] = []
    d.descendants { node, _, _, _ in
        if node.isText { out.append(node.marks.map(\.type.name).sorted()) }
        return true
    }
    return out
}

test("Markdown nests emphasis inside strong") {
    // A run of three supplies both pairs; marks nest by set membership here
    // rather than by wrapping, so one text node carries both.
    try expectEqual(marksOf(try MarkdownParser.parse("***both***", schema: schema)),
                    [["bold", "italic"]])
    try expectEqual(try MarkdownParser.parse("***both***", schema: schema).child(0).textContent,
                    "both")
    // Inside a word too — the case that used not to round-trip.
    let d = try MarkdownParser.parse("foo***bar***baz", schema: schema)
    try expectEqual(d.child(0).textContent, "foobarbaz")
    try expectEqual(marksOf(d), [[], ["bold", "italic"], []])
}

test("Markdown matches nested emphasis pairs innermost first") {
    // Pair matching alone closed the outer run at the inner delimiter.
    try expectEqual(marksOf(try MarkdownParser.parse("*foo **bar** baz*", schema: schema)),
                    [["italic"], ["bold", "italic"], ["italic"]])
    try expectEqual(marksOf(try MarkdownParser.parse("**foo *bar* baz**", schema: schema)),
                    [["bold"], ["bold", "italic"], ["bold"]])
    try expectEqual(try MarkdownParser.parse("*foo **bar** baz*", schema: schema)
                        .child(0).textContent, "foo bar baz")
}

test("Markdown applies the rule of three") {
    // A run that can both open and close may not pair when the lengths sum to a
    // multiple of three, which keeps this from pairing across the middle.
    let d = try MarkdownParser.parse("*foo**bar**baz*", schema: schema)
    try expectEqual(d.child(0).textContent, "foobarbaz")
    try expect(marksOf(d).contains(["italic"]), "outer emphasis lost: \(marksOf(d))")
}

test("Markdown leaves unmatched delimiters as text") {
    for md in ["*foo", "foo*", "**foo", "a * b"] {
        let d = try MarkdownParser.parse(md, schema: schema)
        try expectEqual(d.child(0).textContent, md, "input: \(md)")
        try expect(marksOf(d).allSatisfy(\.isEmpty), "input \(md) grew a mark")
    }
}

test("Markdown round-trip: nested and spanning emphasis") {
    for md in ["***both***", "*foo **bar** baz*", "**foo *bar* baz**",
               "foo***bar***baz", "*foo**bar**baz*", "**[link](/x) is bold**"] {
        let d = try MarkdownParser.parse(md, schema: schema)
        try expectEqual(try MarkdownParser.parse(MarkdownSerializer.serialize(d), schema: schema), d,
                        "input: \(md)")
    }
}

test("Markdown: a mark spanning a link is written around the whole run") {
    // The bold covers the link and the text after it, so it wraps both rather
    // than being emitted twice with the link between.
    let d = try MarkdownParser.parse("**[link](/x) is bold**", schema: schema)
    try expectEqual(MarkdownSerializer.serialize(d), "**[link](/x) is bold**")
}

test("Markdown: emphasis spanning a code span stays open across it") {
    // `code` excludes every other mark, so the span itself can't be bold — but
    // closing and reopening the emphasis around it would emit delimiter runs
    // that don't parse back.
    let md = "This is **strong *emphasized text with `code` in* it**"
    let d = try MarkdownParser.parse(md, schema: schema)
    try expectEqual(MarkdownSerializer.serialize(d), md)
    try expectEqual(try MarkdownParser.parse(MarkdownSerializer.serialize(d), schema: schema), d)
}

test("Markdown emphasis follows the flanking rules") {
    // A delimiter only opens when it isn't followed by whitespace, and only
    // closes when it isn't preceded by whitespace.
    // (Not "* foo *": at the start of a line that's a bullet list item.)
    for md in ["a * foo bar*", "a *foo bar *", "x * foo * y", "a*\"foo\"*"] {
        let d = try MarkdownParser.parse(md, schema: schema)
        try expect(d.child(0).child(0).marks.isEmpty, "input \(md) became emphasis")
        try expectEqual(d.child(0).textContent, md, "input: \(md)")
    }
    // ...and still emphasizes the ordinary cases.
    try expectEqual(try MarkdownParser.parse("*foo bar*", schema: schema), doc(p(em("foo bar"))))
    try expectEqual(try MarkdownParser.parse("**foo bar**", schema: schema), doc(p(strong("foo bar"))))
    try expectEqual(try MarkdownParser.parse("a *foo* b", schema: schema),
                    doc(p(t("a "), em("foo"), t(" b"))))
}

test("Markdown: an underscore inside a word is not emphasis") {
    // The rule that keeps identifiers intact when the Markdown came from
    // somewhere else — our own output escapes them as well.
    for md in ["snake_case_name", "a_b_c", "foo_bar_baz"] {
        let d = try MarkdownParser.parse(md, schema: schema)
        try expectEqual(d.child(0).textContent, md, "input: \(md)")
        try expect(d.child(0).child(0).marks.isEmpty, "input \(md) became emphasis")
    }
    // An asterisk inside a word does emphasize, which is the spec's rule.
    try expectEqual(try MarkdownParser.parse("foo*bar*baz", schema: schema),
                    doc(p(t("foo"), em("bar"), t("baz"))))
    // ...and an underscore still emphasizes between words.
    try expectEqual(try MarkdownParser.parse("_foo bar_", schema: schema), doc(p(em("foo bar"))))
}

test("Markdown code spans use backtick runs") {
    // A run of N backticks closes on the next run of exactly N, so a span can
    // hold a backtick; one space of padding at each end is dropped.
    try expectEqual(try MarkdownParser.parse("`` foo ` bar ``", schema: schema),
                    doc(p(schema.text("foo ` bar", [schema.mark("code")]))))
    try expectEqual(try MarkdownParser.parse("` `` `", schema: schema),
                    doc(p(schema.text("``", [schema.mark("code")]))))
    try expectEqual(try MarkdownParser.parse("`a`", schema: schema),
                    doc(p(schema.text("a", [schema.mark("code")]))))
}

test("Markdown round-trip: code spans containing backticks") {
    for code in ["a`b", "``", "a ` b", "`lead", "trail`", "plain"] {
        let d = doc(p(schema.text(code, [schema.mark("code")])))
        try expectEqual(try MarkdownParser.parse(MarkdownSerializer.serialize(d), schema: schema), d,
                        "code: \(code)")
    }
}

test("Markdown: a backtick fence's info string may not contain a backtick") {
    // Otherwise a paragraph opening with a long code span — which is how a span
    // containing backticks is written — would be read as a code block.
    let d = try MarkdownParser.parse("``` `` ```", schema: schema)
    try expectEqual(d.child(0).type.name, "paragraph")
    try expectEqual(d.child(0).child(0).marks.map(\.type.name), ["code"])
    // A real fence, with and without an info string, still opens a block.
    try expectEqual(try MarkdownParser.parse("```\nx\n```", schema: schema).child(0).type.name,
                    "codeBlock")
    try expectEqual(try MarkdownParser.parse("```swift\nx\n```", schema: schema).child(0).type.name,
                    "codeBlock")
}

test("Markdown: a setext underline is not eaten by the highlight syntax") {
    // The "==" highlight syntax used to consume the run into empty <mark>
    // elements, losing the text; now the underline reads as a heading.
    let d = try MarkdownParser.parse("Foo\n=========", schema: schema)
    try expectEqual(d, doc(h(1, "Foo")))
    try expect(d.child(0).child(0).marks.isEmpty, "highlight mark leaked in")
}

test("Markdown round-trip: prose containing dollar signs is not math") {
    // Pandoc: "$20,000 and $30,000 won't parse as math" — the closing "$" needs
    // a non-space to its left and no digit to its right. We also escape dollars
    // on the way out, so our own output never depends on that rule alone.
    for text in ["costs $5 and $6 today", "$20,000 and $30,000", "a $ b $ c", "$"] {
        let d = doc(p(text))
        let md = MarkdownSerializer.serialize(d)
        try expectEqual(try MarkdownParser.parse(md, schema: schema), d, "text: \(text)")
    }
}

test("Markdown parses unescaped prose dollars as text, not math") {
    // Hand-written Markdown that never saw our escaping still has to read right.
    try expectEqual(try MarkdownParser.parse("costs $5 and $6 today", schema: schema),
                    doc(p("costs $5 and $6 today")))
    try expectEqual(try MarkdownParser.parse("$20,000 and $30,000", schema: schema),
                    doc(p("$20,000 and $30,000")))
    // A space after the opening delimiter also disqualifies it.
    try expectEqual(try MarkdownParser.parse("a $ x $ b", schema: schema),
                    doc(p("a $ x $ b")))
}

test("Markdown round-trip: a dollar inside a formula") {
    // "\$" is how TeX spells a dollar, and it survives as written. A bare "$"
    // isn't valid TeX and normalizes to the escaped form.
    let escaped = doc(p(inlineMath("\\$5")))
    try expectEqual(try MarkdownParser.parse(MarkdownSerializer.serialize(escaped), schema: schema),
                    escaped)
    let bare = doc(p(inlineMath("a$b")))
    try expectEqual(try MarkdownParser.parse(MarkdownSerializer.serialize(bare), schema: schema),
                    doc(p(inlineMath("a\\$b"))))
}

test("Markdown round-trip: empty formulas") {
    // Block math keeps its node; inline math has no spelling for empty, so it
    // drops rather than emitting a "$$" that would swallow what follows.
    let block = doc(blockMath(""))
    try expectEqual(MarkdownSerializer.serialize(block), "$$\n\n$$")
    try expectEqual(try MarkdownParser.parse(MarkdownSerializer.serialize(block), schema: schema),
                    block)
    let inline = doc(p(t("a "), inlineMath(""), t(" b")))
    try expectEqual(MarkdownSerializer.serialize(inline), "a  b")
    try expectEqual(try MarkdownParser.parse(MarkdownSerializer.serialize(inline), schema: schema),
                    doc(p("a  b")))
}

test("Markdown round-trip: math inside a list item") {
    // CommonMark keeps a block in the item only while every line is indented to
    // the content column, so the closing "$$" has to be indented too.
    let bullet = doc(node("bulletList", tightList, [
        node("listItem", [:], [p("a"), blockMath("x^2")]),
    ]))
    let md = MarkdownSerializer.serialize(bullet)
    try expect(md.contains("\n  $$"), "closing fence not indented into the item: \(md)")
    try expectEqual(try MarkdownParser.parse(md, schema: schema), bullet)

    let ordered = doc(node("orderedList", ["order": .int(1), "tight": .bool(true)], [
        node("listItem", [:], [p("a"), blockMath("y")]),
    ]))
    try expectEqual(try MarkdownParser.parse(MarkdownSerializer.serialize(ordered), schema: schema),
                    ordered)
}

test("Markdown round-trip: inline math in a list item") {
    let d = doc(node("bulletList", tightList, [
        node("listItem", [:], [p(t("let "), inlineMath("x^2"))]),
    ]))
    try expectEqual(try MarkdownParser.parse(MarkdownSerializer.serialize(d), schema: schema), d)
}

test("Markdown round-trip: formulas with awkward sources") {
    for latex in ["\\frac{a}{b}", "a_b^*c*", "\\alpha \\beta", "x < y > z", "a \\$ b"] {
        let d = doc(p(t("see "), inlineMath(latex), t(" ok")), blockMath(latex))
        try expectEqual(try MarkdownParser.parse(MarkdownSerializer.serialize(d), schema: schema), d,
                        "latex: \(latex)")
    }
}

test("Markdown round-trip: block math beside other blocks") {
    let d = doc(p("a"), blockMath("x"), p("b"), blockMath("y"), blockMath("z"),
                node("blockquote", [:], [blockMath("q")]))
    try expectEqual(try MarkdownParser.parse(MarkdownSerializer.serialize(d), schema: schema), d)
}

test("Markdown: a newline in inline math folds to a space") {
    // Inline math is single-line in every dialect; TeX reads a newline as
    // whitespace, so folding it preserves the formula and makes it stable.
    let d = doc(p(inlineMath("a\nb")))
    let once = try MarkdownParser.parse(MarkdownSerializer.serialize(d), schema: schema)
    try expectEqual(once, doc(p(inlineMath("a b"))))
    try expectEqual(try MarkdownParser.parse(MarkdownSerializer.serialize(once), schema: schema), once)
}

test("Markdown: surrounding whitespace in a display formula is trimmed") {
    // Pandoc allows the $$ delimiters to be separated from the formula by
    // whitespace, so it isn't part of the source. Normalizing once is stable.
    let d = doc(blockMath("  x^2  "))
    let once = try MarkdownParser.parse(MarkdownSerializer.serialize(d), schema: schema)
    try expectEqual(once, doc(blockMath("x^2")))
    try expectEqual(try MarkdownParser.parse(MarkdownSerializer.serialize(once), schema: schema), once)
}

test("Markdown round-trip: a fenced code block inside a list item") {
    // Same continuation-line machinery the formula case needs.
    let d = doc(node("bulletList", tightList, [
        node("listItem", [:], [p("a"), node("codeBlock", [:], [t("x = 1")])]),
    ]))
    try expectEqual(try MarkdownParser.parse(MarkdownSerializer.serialize(d), schema: schema), d)
}

test("Markdown round-trip: two paragraphs in one list item") {
    let d = doc(node("bulletList", [:], [
        node("listItem", [:], [p("foo"), p("bar")]),
        node("listItem", [:], [p("baz")]),
    ]))
    try expectEqual(try MarkdownParser.parse(MarkdownSerializer.serialize(d), schema: schema), d)
}

test("Markdown: a dollar in a code span stays literal") {
    let d = doc(p(t("cost "), schema.text("$5", [schema.mark("code")])))
    try expectEqual(try MarkdownParser.parse(MarkdownSerializer.serialize(d), schema: schema), d)
}

test("Markdown round-trip: math in a heading") {
    let d = doc(node("heading", ["level": .int(2)], [t("on "), inlineMath("x^2")]), p("after"))
    try expectEqual(try MarkdownParser.parse(MarkdownSerializer.serialize(d), schema: schema), d)
}

test("Markdown round-trip: math in a blockquote paragraph") {
    let d = doc(node("blockquote", [:], [p(t("see "), inlineMath("x^2")), blockMath("y")]))
    try expectEqual(try MarkdownParser.parse(MarkdownSerializer.serialize(d), schema: schema), d)
}

test("Markdown round-trip: math in a nested blockquote") {
    let d = doc(node("blockquote", [:], [node("blockquote", [:], [blockMath("x^2")])]))
    try expectEqual(try MarkdownParser.parse(MarkdownSerializer.serialize(d), schema: schema), d)
}

test("Markdown round-trip: math in a task list item") {
    let d = doc(node("taskList", [:], [
        node("taskItem", ["checked": .bool(true)], [p(t("done "), inlineMath("x^2"))]),
        node("taskItem", ["checked": .bool(false)], [p(t("todo "), inlineMath("y"))]),
    ]))
    try expectEqual(try MarkdownParser.parse(MarkdownSerializer.serialize(d), schema: schema), d)
}

test("Markdown round-trip: a plain task list") {
    let d = doc(node("taskList", [:], [
        node("taskItem", ["checked": .bool(false)], [p("todo")]),
        node("taskItem", ["checked": .bool(true)], [p("done")]),
    ]))
    try expectEqual(MarkdownSerializer.serialize(d), "- [ ] todo\n- [x] done")
    try expectEqual(try MarkdownParser.parse(MarkdownSerializer.serialize(d), schema: schema), d)
}

test("Markdown parses an upper-case [X] checkbox") {
    let d = try MarkdownParser.parse("- [X] done", schema: schema)
    try expectEqual(d.child(0).child(0).attrs["checked"], .bool(true))
}

test("Markdown keeps brackets literal when only some items are checkboxes") {
    // A half-checkbox list isn't a task list; the brackets stay text.
    let d = try MarkdownParser.parse("- [ ] a\n- b", schema: schema)
    try expectEqual(d.child(0).type.name, "bulletList")
    try expectEqual(d.child(0).child(0).textContent, "[ ] a")
}

test("Markdown task lists are inert in a schema without the nodes") {
    let plain = try Schema(nodes: [
        ("doc", NodeSpec(content: "block+")),
        ("paragraph", NodeSpec(content: "inline*", group: "block")),
        ("text", NodeSpec(group: "inline")),
        ("bulletList", NodeSpec(content: "listItem+", group: "block")),
        ("listItem", NodeSpec(content: "paragraph block*")),
    ], marks: [], topNode: "doc")
    let d = try MarkdownParser.parse("- [x] a", schema: plain)
    try expectEqual(d.child(0).type.name, "bulletList")
    try expectEqual(d.child(0).child(0).textContent, "[x] a")
}

test("Markdown round-trip: math in an ordered list that doesn't start at 1") {
    let d = doc(node("orderedList", ["order": .int(7), "tight": .bool(true)], [
        node("listItem", [:], [p("a"), blockMath("x^2")]),
        node("listItem", [:], [p(t("b "), inlineMath("y"))]),
    ]))
    try expectEqual(try MarkdownParser.parse(MarkdownSerializer.serialize(d), schema: schema), d)
}

test("Markdown round-trip: a display formula whose lines look like Markdown") {
    // Everything between the fences is formula source, so a line that reads as a
    // list item, heading, quote or rule must come back verbatim.
    let latex = "- a\n# b\n1. c\n> d\n---\n``` e"
    let d = doc(blockMath(latex))
    let back = try MarkdownParser.parse(MarkdownSerializer.serialize(d), schema: schema)
    try expectEqual(back, d)
    try expectEqual(back.child(0).attrs["latex"], .string(latex))
}

test("Markdown round-trip: a multi-line matrix formula") {
    let d = doc(blockMath("\\begin{matrix}\na & b \\\\\nc & d\n\\end{matrix}"))
    try expectEqual(try MarkdownParser.parse(MarkdownSerializer.serialize(d), schema: schema), d)
}

test("Markdown round-trip: formula source containing Markdown punctuation") {
    for latex in ["a `code` b", "[x](y)", "**b**", "a | b", "~~s~~", "<tag>", "50\\% \\& more"] {
        let d = doc(p(t("see "), inlineMath(latex)))
        try expectEqual(try MarkdownParser.parse(MarkdownSerializer.serialize(d), schema: schema), d,
                        "latex: \(latex)")
    }
}

test("Markdown round-trip: formula source with non-ASCII") {
    let d = doc(p(inlineMath("\\text{日本語} α β"), t(" and émoji 👍")),
                blockMath("∑_{i=1}^{n} x_i"))
    try expectEqual(try MarkdownParser.parse(MarkdownSerializer.serialize(d), schema: schema), d)
}

test("Markdown round-trip: several formulas and dollars in one paragraph") {
    let d = doc(p(t("costs $5, "), inlineMath("a"), t(" then $6 and "), inlineMath("b"), t(" for $7")))
    try expectEqual(try MarkdownParser.parse(MarkdownSerializer.serialize(d), schema: schema), d)
}

test("Markdown round-trip: literal $$ in prose is not a fence") {
    let d = doc(p("a $$ b"), p("$$"), p(t("x"), node("hardBreak", [:], []), t("$9")))
    try expectEqual(try MarkdownParser.parse(MarkdownSerializer.serialize(d), schema: schema), d)
}

test("Markdown round-trip: a formula at the very start and end of a document") {
    let d = doc(blockMath("first"), p(t("mid "), inlineMath("m")), blockMath("last"))
    try expectEqual(try MarkdownParser.parse(MarkdownSerializer.serialize(d), schema: schema), d)
}

test("Markdown round-trip: an empty formula beside a real one") {
    let d = doc(p(t("a "), inlineMath(""), inlineMath("x"), t(" b")), blockMath(""), blockMath("y"))
    let back = try MarkdownParser.parse(MarkdownSerializer.serialize(d), schema: schema)
    // The empty inline formula has no spelling and drops; everything else stands.
    try expectEqual(back, doc(p(t("a "), inlineMath("x"), t(" b")), blockMath(""), blockMath("y")))
}

test("Markdown parses math adjacent to text without spaces") {
    // Pandoc puts no constraint on what precedes the opening $ or follows the
    // closing one, beyond the closing $ not being followed by a digit.
    try expectEqual(try MarkdownParser.parse("a$b$c", schema: schema),
                    doc(p(t("a"), inlineMath("b"), t("c"))))
    // ...and a digit after the closing $ disqualifies it.
    try expectEqual(try MarkdownParser.parse("a$b$9", schema: schema), doc(p("a$b$9")))
}

test("Markdown parses escaped dollars as literal text, never math") {
    try expectEqual(try MarkdownParser.parse("\\$x\\$", schema: schema), doc(p("$x$")))
    try expectEqual(try MarkdownParser.parse("\\$5 and \\$6", schema: schema), doc(p("$5 and $6")))
}

test("Markdown serializing math twice produces the same text") {
    let d = doc(h(2, "Formulas"),
                p(t("inline "), inlineMath("x^2"), t(" and $5")),
                blockMath("E = mc^2"),
                node("bulletList", tightList, [node("listItem", [:], [p("a"), blockMath("y")])]))
    let once = MarkdownSerializer.serialize(d)
    let twice = MarkdownSerializer.serialize(try MarkdownParser.parse(once, schema: schema))
    try expectEqual(twice, once)
}

// MARK: - Figures

func figure(_ children: Node...) -> Node { node("figure", [:], children) }
func figcaption(_ s: String) -> Node { node("figcaption", [:], [t(s)]) }

/// The schema a host gets without opting into the figure extension.
let noFigureSchema: Schema = {
    try! Schema(nodes: [
        ("doc", NodeSpec(content: "block+")),
        ("paragraph", NodeSpec(content: "inline*", group: "block")),
        ("text", NodeSpec(group: "inline")),
        ("image", NodeSpec(group: "inline", inline: true, atom: true,
                           attrs: ["src": AttributeSpec(), "alt": AttributeSpec(default: .null),
                                   "title": AttributeSpec(default: .null)])),
    ], marks: [], topNode: "doc")
}()

test("HTML round-trip: a figure with a caption") {
    let d = doc(figure(p(node("image", ["src": .string("a.png"), "alt": .string("cat")])),
                       figcaption("A cat")))
    let html = HTMLSerializer.serialize(d)
    try expect(html.contains("<figure>"), "got: \(html)")
    try expect(html.contains("<figcaption>A cat</figcaption>"), "got: \(html)")
    try expectEqual(try HTMLParser.parse(html, schema: schema), d)
}

test("HTML round-trip: a figure without a caption") {
    let d = doc(figure(p(node("image", ["src": .string("a.png")]))))
    try expectEqual(try HTMLParser.parse(HTMLSerializer.serialize(d), schema: schema), d)
}

test("HTML: a figure's caption keeps its inline markup") {
    let d = doc(figure(p("body"), node("figcaption", [:], [t("see "), strong("this"), t(" one")])))
    try expectEqual(try HTMLParser.parse(HTMLSerializer.serialize(d), schema: schema), d)
}

test("HTML: pasted figure markup becomes a figure") {
    // The shape essentially every article on the web uses.
    let d = try HTMLParser.parse(
        "<figure><img src=\"a.png\" alt=\"cat\"><figcaption>A <em>cat</em></figcaption></figure>",
        schema: schema)
    try expectEqual(d.child(0).type.name, "figure")
    try expectEqual(d.child(0).lastChild?.type.name, "figcaption")
    try expectEqual(d.child(0).lastChild?.textContent, "A cat")
}

test("HTML: a figure degrades to its contents without the nodes") {
    // A host that hasn't opted in must keep the image and the caption's words
    // rather than losing them — the same "keep what was inside it" rule the
    // other unknown containers follow.
    let d = try HTMLParser.parse(
        "<p>before</p><figure><img src=\"a.png\"><figcaption>A cat</figcaption></figure>",
        schema: noFigureSchema)
    try expect(!d.textContent.contains("figure"), "leaked markup: \(d.textContent)")
    try expect(d.textContent.contains("A cat"), "caption lost: \(d.textContent)")
    let hasImage = (0..<d.childCount).contains { i in
        let block = d.child(i)
        return (0..<block.childCount).contains { block.child($0).type.name == "image" }
    }
    try expect(hasImage, "image lost")
}

test("Markdown round-trip: a figure with a caption") {
    let d = doc(figure(p("body text"), figcaption("A cat")))
    try expectEqual(MarkdownSerializer.serialize(d), "^^^\nbody text\n^^^ A cat")
    try expectEqual(try MarkdownParser.parse(MarkdownSerializer.serialize(d), schema: schema), d)
}

test("Markdown round-trip: a figure without a caption") {
    let d = doc(figure(p("body text")))
    try expectEqual(MarkdownSerializer.serialize(d), "^^^\nbody text\n^^^")
    try expectEqual(try MarkdownParser.parse(MarkdownSerializer.serialize(d), schema: schema), d)
}

test("Markdown round-trip: a figure holding several blocks") {
    let d = doc(figure(h(2, "Title"), p("one"), p("two"), figcaption("caption")))
    try expectEqual(try MarkdownParser.parse(MarkdownSerializer.serialize(d), schema: schema), d)
}

test("Markdown round-trip: a figure holding an image and a formula") {
    let d = doc(figure(p(node("image", ["src": .string("a.png"), "alt": .string("cat")])),
                       blockMath("E = mc^2"),
                       figcaption("mass–energy")))
    try expectEqual(try MarkdownParser.parse(MarkdownSerializer.serialize(d), schema: schema), d)
}

test("Markdown: a figure caption keeps its inline markup") {
    let d = doc(figure(p("body"), node("figcaption", [:], [t("a "), em("caption"), t(" here")])))
    try expectEqual(try MarkdownParser.parse(MarkdownSerializer.serialize(d), schema: schema), d)
}

test("Markdown parses Markdig's caption on the opening fence") {
    // Markdig accepts it on either fence; we write the closing one but read both.
    let d = try MarkdownParser.parse("^^^ A cat\nbody\n^^^", schema: schema)
    try expectEqual(d, doc(figure(p("body"), figcaption("A cat"))))
}

test("Markdown: an unterminated figure fence still yields a figure") {
    try expectEqual(try MarkdownParser.parse("^^^\nbody", schema: schema),
                    doc(figure(p("body"))))
}

test("Markdown: figures are inert in a schema without the nodes") {
    // "^^^" is a Markdig extension, not CommonMark, so it must stay literal for
    // a host that hasn't registered the nodes.
    let d = try MarkdownParser.parse("^^^\nbody\n^^^ A cat", schema: noFigureSchema)
    try expect(d.textContent.contains("^^^"), "fence was consumed: \(d.textContent)")
    try expect(d.textContent.contains("body"), "body lost: \(d.textContent)")
}

test("Markdown round-trip: prose that starts with a figure fence") {
    // With the nodes registered, a paragraph opening with "^^^" would be read
    // back as a fence, so it's escaped on the way out — "^" is ASCII
    // punctuation, so "\^" is a CommonMark escape like "\$".
    let d = doc(p("^^^ not a figure"), p("a ^^^ b"), p("^^^"))
    let md = MarkdownSerializer.serialize(d)
    try expect(md.hasPrefix("\\^^^"), "leading fence not escaped: \(md)")
    try expectEqual(try MarkdownParser.parse(md, schema: schema), d)
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
        case 3: return node("bulletList", tightList, (0...rnd(2)).map { _ in
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

// MARK: - CommonMark long tail, second batch

test("Markdown: an ordered list keeps the number it starts at") {
    let d = try MarkdownParser.parse("5. five\n6. six", schema: schema)
    try expectEqual(d.child(0).attrs["order"]?.intValue, 5)
    // The number survives a trip through HTML, which is how a paste carries it.
    let html = HTMLSerializer.serialize(d)
    try expect(html.contains("start=\"5\""), "no start attribute: \(html)")
    try expectEqual(try HTMLParser.parse(html, schema: schema), d)
    // A list starting at 1 needs no attribute.
    try expect(!HTMLSerializer.serialize(try MarkdownParser.parse("1. one", schema: schema))
        .contains("start="), "start written for a list beginning at 1")
}

test("Markdown: an ordered marker is at most nine digits") {
    try expectEqual(try MarkdownParser.parse("123456789. ok", schema: schema).child(0).type.name,
                    "orderedList")
    // Ten digits is a paragraph that happens to begin with a number.
    try expectEqual(try MarkdownParser.parse("1234567890. not ok", schema: schema),
                    doc(p("1234567890. not ok")))
}

test("Markdown: a marker alone is an empty list item") {
    try expectEqual(try MarkdownParser.parse("- foo\n-\n- bar", schema: schema),
                    doc(node("bulletList", tightList, [
                        node("listItem", [:], [p("foo")]),
                        node("listItem", [:], [node("paragraph", [:], [])]),
                        node("listItem", [:], [p("bar")])])))
    try expectEqual(try MarkdownParser.parse("1.\n2. two", schema: schema).child(0).childCount, 2)
}

test("Markdown: a paragraph inside a nested quote continues lazily") {
    // The line belongs to the innermost paragraph, however deep it sits.
    try expectEqual(try MarkdownParser.parse("> > > foo\nbar", schema: schema),
                    doc(node("blockquote", [:], [node("blockquote", [:], [
                        node("blockquote", [:], [p("foo bar")])])])))
}

test("Markdown: a run of = inside a quote is text, not an underline") {
    // "===" only ever underlines a heading, and it can't do that across the
    // quote's edge — so it continues the paragraph.
    try expectEqual(try MarkdownParser.parse("> foo\nbar\n===", schema: schema),
                    doc(node("blockquote", [:], [p("foo bar ===")])))
    // "---" is also a thematic break, which does end the quote.
    try expectEqual(try MarkdownParser.parse("> foo\n---", schema: schema),
                    doc(node("blockquote", [:], [p("foo")]), node("horizontalRule", [:], [])))
}

test("Markdown: a definition may follow a block that isn't a paragraph") {
    let d = try MarkdownParser.parse("# [Foo]\n[foo]: /url\n> bar", schema: schema)
    try expectEqual(d.child(0).type.name, "heading")
    try expectEqual(d.child(0).child(0).marks.first?.attrs["href"]?.stringValue, "/url")
    try expectEqual(d.child(1).type.name, "blockquote")
    // It still can't interrupt a paragraph.
    try expectEqual(try MarkdownParser.parse("foo\n[bar]: /url", schema: schema),
                    doc(p("foo [bar]: /url")))
}

test("Markdown: an ATX heading may be empty") {
    try expectEqual(try MarkdownParser.parse("## \n#\n### ###", schema: schema),
                    doc(node("heading", ["level": .int(2)], []),
                        node("heading", ["level": .int(1)], []),
                        node("heading", ["level": .int(3)], [])))
    // A hash run is still not a heading past level six, or without the space.
    try expectEqual(try MarkdownParser.parse("#######", schema: schema), doc(p("#######")))
    try expectEqual(try MarkdownParser.parse("#foo", schema: schema), doc(p("#foo")))
}

test("Markdown: a backslash escapes the quote inside a definition's title") {
    let d = try MarkdownParser.parse("[foo]: /url \"tit\\\"le\"\n\n[foo]", schema: schema)
    try expectEqual(d.childCount, 1)
    let link = d.child(0).child(0).marks.first
    try expectEqual(link?.attrs["href"]?.stringValue, "/url")
    try expectEqual(link?.attrs["title"]?.stringValue, "tit\"le")
}

test("Markdown: a thematic break beats the list marker it starts with") {
    try expectEqual(try MarkdownParser.parse("* Foo\n* * *\n* Bar", schema: schema),
                    doc(node("bulletList", tightList, [node("listItem", [:], [p("Foo")])]),
                        node("horizontalRule", [:], []),
                        node("bulletList", tightList, [node("listItem", [:], [p("Bar")])])))
}

test("Markdown: a link label's brackets nest") {
    // The classic linked badge — an image inside a link — used to lose both.
    let d = try MarkdownParser.parse("[![moon](moon.jpg)](/uri)", schema: schema)
    let image = d.child(0).child(0)
    try expectEqual(image.type.name, "image")
    try expectEqual(image.attrs["src"]?.stringValue, "moon.jpg")
    try expectEqual(image.marks.first?.attrs["href"]?.stringValue, "/uri")
    // Brackets inside the label are part of it.
    let nested = try MarkdownParser.parse("[link [foo [bar]]](/uri)", schema: schema)
    try expectEqual(nested.child(0).child(0).text, "link [foo [bar]]")
    try expectEqual(nested.child(0).child(0).marks.first?.attrs["href"]?.stringValue, "/uri")
}

test("Markdown: links don't nest, so the inner one wins") {
    // A label already holding a link can't become one, leaving the outer
    // brackets as text.
    let d = try MarkdownParser.parse("[foo [bar](/uri)](/uri)", schema: schema)
    let para = d.child(0)
    try expectEqual(para.child(0).text, "[foo ")
    try expectEqual(para.child(1).text, "bar")
    try expectEqual(para.child(1).marks.first?.attrs["href"]?.stringValue, "/uri")
    try expectEqual(para.child(2).text, "](/uri)")
}

test("Markdown round-trip: the second long-tail batch") {
    for md in ["5. five\n6. six", "- foo\n-\n- bar", "> > > foo\nbar", "> foo\nbar\n===",
               "# [Foo]\n\n[foo]: /url", "## \n#\n### ###", "[foo]: /url \"tit\\\"le\"\n\n[foo]",
               "* Foo\n* * *\n* Bar", "[![moon](moon.jpg)](/uri)", "[foo [bar](/uri)](/uri)"] {
        let d = try MarkdownParser.parse(md, schema: schema)
        try expectEqual(try MarkdownParser.parse(d.toMarkdown(), schema: schema), d,
                        "round-trip changed \(md.debugDescription); rewrote as:\n\(d.toMarkdown())")
    }
}

// MARK: - CommonMark long tail, third batch (links, code spans, alt text)

private func linkMark(_ d: Node, _ child: Int = 0) -> Mark? {
    d.child(0).child(child).marks.first { $0.type.name == "link" }
}

test("Markdown: a reference label's brackets nest") {
    let d = try MarkdownParser.parse("[link [foo [bar]]][ref]\n\n[ref]: /uri", schema: schema)
    try expectEqual(d.child(0).child(0).text, "link [foo [bar]]")
    try expectEqual(linkMark(d)?.attrs["href"]?.stringValue, "/uri")
    // An image inside a reference link survives too.
    let img = try MarkdownParser.parse("[![moon](moon.jpg)][ref]\n\n[ref]: /uri", schema: schema)
    try expectEqual(img.child(0).child(0).type.name, "image")
    try expectEqual(img.child(0).child(0).marks.first?.attrs["href"]?.stringValue, "/uri")
}

test("Markdown: a reference label already holding a link keeps its brackets") {
    let d = try MarkdownParser.parse("[foo [bar](/uri)][ref]\n\n[ref]: /uri", schema: schema)
    try expectEqual(d.child(0).child(0).text, "[foo ")
    try expectEqual(d.child(0).child(1).text, "bar")
}

test("Markdown: a code span binds more tightly than a link") {
    // The backtick run opens inside the label and closes past it, so the code
    // span wins and the brackets stay text.
    let d = try MarkdownParser.parse("[not a `link](/foo`)", schema: schema)
    try expectEqual(d.child(0).child(0).text, "[not a ")
    try expectEqual(d.child(0).child(1).text, "link](/foo")
    try expect(d.child(0).child(1).marks.contains { $0.type.name == "code" }, "not a code span")
    // The same for a reference link.
    let r = try MarkdownParser.parse("[foo`][ref]`\n\n[ref]: /uri", schema: schema)
    try expect(r.child(0).child(1).marks.contains { $0.type.name == "code" },
               "reference form: not a code span")
}

test("Markdown: a backtick run is atomic") {
    // Three ticks can't be closed by two, and the leftover ticks are text —
    // they don't pair off among themselves.
    try expectEqual(try MarkdownParser.parse("```foo``", schema: schema), doc(p("```foo``")))
    try expectEqual(try MarkdownParser.parse("`foo", schema: schema), doc(p("`foo")))
}

test("Markdown: a link destination stays on one line") {
    try expectEqual(try MarkdownParser.parse("[link](foo\nbar)", schema: schema),
                    doc(p("[link](foo bar)")))
    try expectEqual(try MarkdownParser.parse("[link](<foo\nbar>)", schema: schema),
                    doc(p("[link](<foo bar>)")))
}

test("Markdown: a link's destination and title may sit on separate lines") {
    let d = try MarkdownParser.parse("[link](   /uri\n  \"title\"  )", schema: schema)
    try expectEqual(linkMark(d)?.attrs["href"]?.stringValue, "/uri")
    try expectEqual(linkMark(d)?.attrs["title"]?.stringValue, "title")
}

test("Markdown: a backslash escapes the quote inside an inline link's title") {
    let d = try MarkdownParser.parse("[link](/url \"ti\\\"tle\")", schema: schema)
    try expectEqual(linkMark(d)?.attrs["href"]?.stringValue, "/url")
    try expectEqual(linkMark(d)?.attrs["title"]?.stringValue, "ti\"tle")
}

test("Markdown: a title has to be separated from the destination") {
    // Without the space this is neither a definition nor a link.
    try expectEqual(try MarkdownParser.parse("[foo]: <bar>(baz)\n\n[foo]", schema: schema),
                    doc(p("[foo]: <bar>(baz)"), p("[foo]")))
}

test("Markdown: text left over after the title unmakes the link") {
    try expectEqual(try MarkdownParser.parse("[link](/url \"title\" extra)", schema: schema),
                    doc(p("[link](/url \"title\" extra)")))
}

test("Markdown: an empty destination is still a link") {
    for md in ["[link]()", "[link](<>)"] {
        let d = try MarkdownParser.parse(md, schema: schema)
        try expectEqual(d.child(0).child(0).text, "link", "for \(md)")
        try expectEqual(linkMark(d)?.attrs["href"]?.stringValue, "", "for \(md)")
    }
}

test("Markdown: an image's alt text is what its label renders to") {
    // Markup inside the label counts as the words it produces, not its spelling.
    let d = try MarkdownParser.parse("![foo *bar*](/url)", schema: schema)
    try expectEqual(d.child(0).child(0).attrs["alt"]?.stringValue, "foo bar")
    // A nested image gives its own alt text.
    let nested = try MarkdownParser.parse("![foo ![bar](/url)](/url2)", schema: schema)
    try expectEqual(nested.child(0).child(0).attrs["alt"]?.stringValue, "foo bar")
    // The reference form agrees with the inline one.
    let ref = try MarkdownParser.parse("![*foo* bar]\n\n[*foo* bar]: /url \"t\"", schema: schema)
    try expectEqual(ref.child(0).child(0).attrs["alt"]?.stringValue, "foo bar")
}

test("Markdown: brackets in alt text are escaped when written") {
    // Otherwise the label would close at the first one on the way back in.
    let d = try MarkdownParser.parse("![a [b] c](/url)", schema: schema)
    let md = d.toMarkdown()
    try expect(md.contains("\\[b\\]"), "brackets not escaped: \(md)")
    try expectEqual(try MarkdownParser.parse(md, schema: schema), d)
}

test("Markdown round-trip: the third long-tail batch") {
    for md in ["[link [foo [bar]]][ref]\n\n[ref]: /uri", "[![moon](moon.jpg)][ref]\n\n[ref]: /uri",
               "[not a `link](/foo`)", "```foo``", "[link](foo\nbar)",
               "[link](   /uri\n  \"title\"  )", "[link](/url \"ti\\\"tle\")",
               "[foo]: <bar>(baz)\n\n[foo]", "[link]()", "![foo *bar*](/url)",
               "![foo ![bar](/url)](/url2)", "![a [b] c](/url)"] {
        let d = try MarkdownParser.parse(md, schema: schema)
        try expectEqual(try MarkdownParser.parse(d.toMarkdown(), schema: schema), d,
                        "round-trip changed \(md.debugDescription); rewrote as:\n\(d.toMarkdown())")
    }
}

// MARK: - Inline HTML in Markdown, and a fourth long-tail batch

test("Markdown: <br> is a hard break") {
    let d = try MarkdownParser.parse("a <br> b", schema: schema)
    try expectEqual(d.child(0).child(1).type.name, "hardBreak")
    try expectEqual(try MarkdownParser.parse("a <br/> b", schema: schema), d)
}

test("Markdown: <img> becomes an image") {
    let d = try MarkdownParser.parse("a <img src=\"x.png\" alt=\"c\" title=\"t\"> b", schema: schema)
    let img = d.child(0).child(1)
    try expectEqual(img.type.name, "image")
    try expectEqual(img.attrs["src"]?.stringValue, "x.png")
    try expectEqual(img.attrs["alt"]?.stringValue, "c")
    try expectEqual(img.attrs["title"]?.stringValue, "t")
}

test("Markdown: inline formatting tags become marks") {
    let cases: [(String, String)] = [
        ("<b>x</b>", "bold"), ("<strong>x</strong>", "bold"),
        ("<i>x</i>", "italic"), ("<em>x</em>", "italic"),
        ("<del>x</del>", "strike"), ("<s>x</s>", "strike"),
        ("<u>x</u>", "underline"), ("<ins>x</ins>", "underline"),
        ("<mark>x</mark>", "highlight"), ("<code>x</code>", "code"),
        ("<sub>x</sub>", "subscript"), ("<sup>x</sup>", "superscript"),
    ]
    for (md, markName) in cases {
        let d = try MarkdownParser.parse(md, schema: schema)
        try expect(d.child(0).child(0).marks.contains { $0.type.name == markName },
                   "\(md) did not produce a \(markName) mark")
    }
    // Tag names are matched case-insensitively, and markdown inside still parses.
    let mixed = try MarkdownParser.parse("<B>*x*</B>", schema: schema)
    try expectEqual(Set(mixed.child(0).child(0).marks.map { $0.type.name }), ["bold", "italic"])
}

test("Markdown: <a> becomes a link, and a bad scheme does not") {
    let d = try MarkdownParser.parse("<a href=\"/u\" title=\"t\">x</a>", schema: schema)
    let link = d.child(0).child(0).marks.first { $0.type.name == "link" }
    try expectEqual(link?.attrs["href"]?.stringValue, "/u")
    try expectEqual(link?.attrs["title"]?.stringValue, "t")
    // Markdown arrives from the same untrusted places HTML does.
    let bad = try MarkdownParser.parse("<a href=\"javascript:alert(1)\">x</a>", schema: schema)
    try expect(!bad.child(0).textContent.isEmpty, "the text was lost")
    try expect(bad.child(0).child(0).marks.isEmpty, "javascript: became a link")
}

test("Markdown: an unknown tag is kept as written") {
    // Dropping it would delete the author's text — including all of
    // `<javascript:alert(1)>`, which lands here once the sanitizer declines it.
    for md in ["<span class=\"x\">t</span>", "<kbd>Ctrl</kbd>", "<javascript:alert(1)>",
               "a <!-- c --> b", "a < b and c > d"] {
        let d = try MarkdownParser.parse(md, schema: schema)
        try expectEqual(d.child(0).textContent, md, "changed: \(md)")
    }
}

test("Markdown: a paired inline tag stays on one line") {
    // A tag spanning lines opens an HTML block, whose content isn't markdown,
    // so it is left alone rather than read as an inline mark.
    let d = try MarkdownParser.parse("<del>\nfoo\n</del>", schema: schema)
    try expect(d.child(0).child(0).marks.isEmpty, "a block-level tag became a mark")
}

test("Markdown: an ordered list may use a closing paren") {
    let d = try MarkdownParser.parse("1) one\n2) two", schema: schema)
    try expectEqual(d.child(0).type.name, "orderedList")
    try expectEqual(d.child(0).childCount, 2)
    let start = try MarkdownParser.parse("10) foo", schema: schema)
    try expectEqual(start.child(0).attrs["order"]?.intValue, 10)
    // A digit run with no delimiter is still a paragraph.
    try expectEqual(try MarkdownParser.parse("1 one", schema: schema), doc(p("1 one")))
}

test("Markdown: a definition label can't hold an unescaped bracket") {
    try expectEqual(try MarkdownParser.parse("[foo][ref[]\n\n[ref[]: /uri", schema: schema),
                    doc(p("[foo][ref[]"), p("[ref[]: /uri")))
}

test("Markdown: a trailing tab is not content") {
    // It used to survive into the document and then couldn't be written back.
    let d = try MarkdownParser.parse("Foo *bar*\t\n====", schema: schema)
    try expectEqual(d.child(0).type.name, "heading")
    try expectEqual(d.child(0).textContent, "Foo bar")
    try expectEqual(try MarkdownParser.parse(d.toMarkdown(), schema: schema), d)
}

test("HTML: <ins> is underlined text") {
    let editor = try HTMLParser.parse("<p><ins>x</ins></p>", schema: schema)
    try expect(editor.child(0).child(0).marks.contains { $0.type.name == "underline" },
               "<ins> did not become underline")
}

test("Markdown round-trip: the fourth long-tail batch") {
    for md in ["a <br> b", "a <img src=\"x.png\" alt=\"c\"> b", "<b>x</b>", "<del>x</del>",
               "<sub>2</sub>", "<a href=\"/u\">x</a>", "<span class=\"x\">t</span>",
               "<kbd>Ctrl</kbd>", "a <!-- c --> b", "1) one\n2) two", "10) foo",
               "[foo][ref[]\n\n[ref[]: /uri", "Foo *bar*\t\n===="] {
        let d = try MarkdownParser.parse(md, schema: schema)
        try expectEqual(try MarkdownParser.parse(d.toMarkdown(), schema: schema), d,
                        "round-trip changed \(md.debugDescription); rewrote as:\n\(d.toMarkdown())")
    }
}

// MARK: - Tight and loose lists

test("Markdown: a list with no blank lines between its items is tight") {
    let tight = try MarkdownParser.parse("- a\n- b", schema: schema)
    try expectEqual(tight.child(0).attrs["tight"]?.boolValue, true)
    let loose = try MarkdownParser.parse("- a\n\n- b", schema: schema)
    try expectEqual(loose.child(0).attrs["tight"]?.boolValue, false)
    // A blank line inside one item makes the whole list loose too.
    let inner = try MarkdownParser.parse("- a\n\n  b\n- c", schema: schema)
    try expectEqual(inner.child(0).attrs["tight"]?.boolValue, false)
}

test("HTML: a tight list renders without a paragraph in each item") {
    let tight = try MarkdownParser.parse("- a\n- b", schema: schema)
    try expectEqual(HTMLSerializer.serialize(tight), "<ul><li>a</li><li>b</li></ul>")
    let loose = try MarkdownParser.parse("- a\n\n- b", schema: schema)
    try expectEqual(HTMLSerializer.serialize(loose),
                    "<ul><li><p>a</p></li><li><p>b</p></li></ul>")
    // A block that isn't a paragraph is still written whole.
    let nested = try MarkdownParser.parse("- a\n  - b", schema: schema)
    try expectEqual(HTMLSerializer.serialize(nested), "<ul><li>a<ul><li>b</li></ul></li></ul>")
}

test("HTML: tightness survives a round trip through HTML") {
    for md in ["- a\n- b", "- a\n\n- b", "1. a\n2. b", "1. a\n\n2. b"] {
        let d = try MarkdownParser.parse(md, schema: schema)
        let back = try HTMLParser.parse(HTMLSerializer.serialize(d), schema: schema)
        try expectEqual(back.child(0).attrs["tight"], d.child(0).attrs["tight"],
                        "tightness lost for \(md.debugDescription)")
    }
    // A paragraph inside a nested list doesn't make the outer list loose.
    let outer = try HTMLParser.parse("<ul><li>a<ul><li><p>b</p></li></ul></li></ul>", schema: schema)
    try expectEqual(outer.child(0).attrs["tight"]?.boolValue, true)
}

test("Markdown: a loose list keeps the blank line that made it loose") {
    let loose = try MarkdownParser.parse("- a\n\n- b", schema: schema)
    try expectEqual(loose.toMarkdown(), "- a\n\n- b")
    let tight = try MarkdownParser.parse("- a\n- b", schema: schema)
    try expectEqual(tight.toMarkdown(), "- a\n- b")
}

test("Markdown: a loose list of one item puts its blank line after the marker") {
    // There is no gap between items to carry it, so the other spelling is used.
    let d = try MarkdownParser.parse("-\n\n  foo", schema: schema)
    try expectEqual(d.child(0).attrs["tight"]?.boolValue, false)
    try expectEqual(d.toMarkdown(), "-\n\n  foo")
    try expectEqual(try MarkdownParser.parse(d.toMarkdown(), schema: schema), d)
}

test("Markdown round-trip: tight and loose lists") {
    for md in ["- a\n- b", "- a\n\n- b", "- a\n  - b\n- c", "1. a\n2. b", "1. a\n\n2. b",
               "-\n\n  foo", "- a\n  > b\n  ```\n  c\n  ```\n- d", "* a\n  > b\n  >\n* c",
               "- a\n\n  b\n- c", "10) foo\n    - bar"] {
        let d = try MarkdownParser.parse(md, schema: schema)
        try expectEqual(try MarkdownParser.parse(d.toMarkdown(), schema: schema), d,
                        "round-trip changed \(md.debugDescription); rewrote as:\n\(d.toMarkdown())")
    }
}

test("A list made by the editor is loose, as documents written before this were") {
    // The attribute defaults to false so that a stored document, which has no
    // `tight` recorded at all, renders exactly as it did before.
    let list = try schema.node("bulletList", [:], content: Fragment.from([
        try schema.node("listItem", [:], content: Fragment.from([
            try schema.node("paragraph", [:], content: Fragment.from([schema.text("a")])),
        ])),
    ]))
    try expectEqual(list.attrs["tight"]?.boolValue, false)
    try expectEqual(HTMLSerializer.serialize(doc(list)), "<ul><li><p>a</p></li></ul>")
}

registerBench()
TestSuite.main("EditorSerializationTests", collector.all)

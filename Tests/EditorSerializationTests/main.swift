import Foundation
import DocumentModel
import EditorSerialization
import TestHarness

let collector = TestCollector()
func test(_ name: String, _ body: @escaping @Sendable () throws -> Void) { collector.test(name, body) }

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
        ("tableCell", NodeSpec(content: "block+", isolating: true)),
        ("tableHeader", NodeSpec(content: "block+", isolating: true)),
    ]
    let marks: [(String, MarkSpec)] = [
        ("bold", MarkSpec()), ("italic", MarkSpec()), ("strike", MarkSpec()),
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

test("HTML wikiLink round-trip") {
    let wl = node("wikiLink", ["target": .string("Home"), "label": .string("Start")])
    let d = doc(p(t("go "), wl))
    let html = HTMLSerializer.serialize(d)
    let back = try HTMLParser.parse(html, schema: schema)
    try expectEqual(back, d)
}

// MARK: - Markdown

test("Markdown serialize") {
    let d = doc(h(2, "Title"), p(t("a "), strong("b")), node("bulletList", [:], [node("listItem", [:], [p("x")]), node("listItem", [:], [p("y")])]))
    let md = MarkdownSerializer.serialize(d)
    try expectEqual(md, "## Title\n\na **b**\n\n- x\n- y")
}

test("Markdown round-trip (headings, bold, italic, code)") {
    let d = doc(
        h(1, "Doc"),
        p(t("some "), strong("bold"), t(" and "), em("italic"), t(" and "), schema.text("code", [schema.mark("code")])))
    let md = MarkdownSerializer.serialize(d)
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

TestSuite.main("EditorSerializationTests", collector.all)

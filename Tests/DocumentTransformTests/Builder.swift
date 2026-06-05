import DocumentModel

/// Tiptap-named schema + builder for transform tests (mirrors the model tests).
enum B {
    static let schema: Schema = {
        let nodes: [(String, NodeSpec)] = [
            ("doc", NodeSpec(content: "block+")),
            ("paragraph", NodeSpec(content: "inline*", group: "block")),
            ("blockquote", NodeSpec(content: "block+", group: "block", defining: true)),
            ("horizontalRule", NodeSpec(group: "block")),
            ("heading", NodeSpec(content: "inline*", group: "block", attrs: ["level": AttributeSpec(default: .int(1))], defining: true)),
            ("codeBlock", NodeSpec(content: "text*", marks: "", group: "block", code: true, defining: true)),
            ("text", NodeSpec(group: "inline")),
            ("image", NodeSpec(group: "inline", inline: true, attrs: ["src": AttributeSpec(), "alt": AttributeSpec(default: .null), "title": AttributeSpec(default: .null)])),
            ("hardBreak", NodeSpec(group: "inline", inline: true)),
            ("orderedList", NodeSpec(content: "listItem+", group: "block", attrs: ["order": AttributeSpec(default: .int(1))])),
            ("bulletList", NodeSpec(content: "listItem+", group: "block")),
            ("listItem", NodeSpec(content: "paragraph block*", defining: true)),
        ]
        let marks: [(String, MarkSpec)] = [
            ("link", MarkSpec(attrs: ["href": AttributeSpec(), "title": AttributeSpec(default: .null)], inclusive: false)),
            ("italic", MarkSpec()),
            ("bold", MarkSpec()),
            ("strike", MarkSpec()),
            ("code", MarkSpec(excludes: "_")),
        ]
        return try! Schema(nodes: nodes, marks: marks, topNode: "doc")
    }()

    static func node(_ type: String, _ attrs: Attrs = [:], _ content: [Node] = []) -> Node {
        try! schema.node(type, attrs, content: Fragment.from(content))
    }
    static func doc(_ content: Node...) -> Node { node("doc", [:], content) }
    static func p(_ content: Node...) -> Node { node("paragraph", [:], content) }
    static func p(_ text: String) -> Node { node("paragraph", [:], [t(text)]) }
    static func h(_ level: Int, _ content: Node...) -> Node { node("heading", ["level": .int(level)], content) }
    static func blockquote(_ content: Node...) -> Node { node("blockquote", [:], content) }
    static func ul(_ content: Node...) -> Node { node("bulletList", [:], content) }
    static func li(_ content: Node...) -> Node { node("listItem", [:], content) }
    static func t(_ text: String) -> Node { schema.text(text) }
    static func strong(_ text: String) -> Node { schema.text(text, [schema.mark("bold")]) }
    static func em(_ text: String) -> Node { schema.text(text, [schema.mark("italic")]) }

    static var bold: MarkType { schema.marks["bold"]! }
    static var italic: MarkType { schema.marks["italic"]! }
    static func type(_ name: String) -> NodeType { schema.nodes[name]! }
}

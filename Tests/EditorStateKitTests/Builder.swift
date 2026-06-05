import DocumentModel

enum B {
    static let schema: Schema = {
        let nodes: [(String, NodeSpec)] = [
            ("doc", NodeSpec(content: "block+")),
            ("paragraph", NodeSpec(content: "inline*", group: "block")),
            ("blockquote", NodeSpec(content: "block+", group: "block", defining: true)),
            ("heading", NodeSpec(content: "inline*", group: "block", attrs: ["level": AttributeSpec(default: .int(1))], defining: true)),
            ("horizontalRule", NodeSpec(group: "block")),
            ("text", NodeSpec(group: "inline")),
            ("image", NodeSpec(group: "inline", inline: true, attrs: ["src": AttributeSpec(), "alt": AttributeSpec(default: .null), "title": AttributeSpec(default: .null)])),
        ]
        let marks: [(String, MarkSpec)] = [
            ("bold", MarkSpec()),
            ("italic", MarkSpec()),
        ]
        return try! Schema(nodes: nodes, marks: marks, topNode: "doc")
    }()

    static func node(_ type: String, _ attrs: Attrs = [:], _ content: [Node] = []) -> Node {
        try! schema.node(type, attrs, content: Fragment.from(content))
    }
    static func doc(_ content: Node...) -> Node { node("doc", [:], content) }
    static func p(_ content: Node...) -> Node { node("paragraph", [:], content) }
    static func p(_ text: String) -> Node { node("paragraph", [:], [t(text)]) }
    static func hr() -> Node { node("horizontalRule") }
    static func img(_ src: String) -> Node { node("image", ["src": .string(src)]) }
    static func t(_ text: String) -> Node { schema.text(text) }
    static func strong(_ text: String) -> Node { schema.text(text, [schema.mark("bold")]) }
    static var bold: MarkType { schema.marks["bold"]! }
}

import DocumentModel
import EditorStateKit

enum B {
    static let schema: Schema = {
        let nodes: [(String, NodeSpec)] = [
            ("doc", NodeSpec(content: "block+")),
            ("paragraph", NodeSpec(content: "inline*", group: "block")),
            ("blockquote", NodeSpec(content: "block+", group: "block", defining: true)),
            ("heading", NodeSpec(content: "inline*", group: "block", attrs: ["level": AttributeSpec(default: .int(1))], defining: true)),
            ("codeBlock", NodeSpec(content: "text*", marks: "", group: "block", code: true, defining: true)),
            ("horizontalRule", NodeSpec(group: "block")),
            ("text", NodeSpec(group: "inline")),
            ("hardBreak", NodeSpec(group: "inline", inline: true)),
            ("orderedList", NodeSpec(content: "listItem+", group: "block", attrs: ["order": AttributeSpec(default: .int(1))])),
            ("bulletList", NodeSpec(content: "listItem+", group: "block")),
            ("listItem", NodeSpec(content: "paragraph block*", defining: true)),
        ]
        let marks: [(String, MarkSpec)] = [
            ("bold", MarkSpec()),
            ("italic", MarkSpec()),
            ("code", MarkSpec(excludes: "_", code: true)),
        ]
        return try! Schema(nodes: nodes, marks: marks, topNode: "doc")
    }()

    static func node(_ type: String, _ attrs: Attrs = [:], _ content: [Node] = []) -> Node {
        try! schema.node(type, attrs, content: Fragment.from(content))
    }
    static func doc(_ content: Node...) -> Node { node("doc", [:], content) }
    static func p(_ content: Node...) -> Node { node("paragraph", [:], content) }
    static func p(_ text: String) -> Node { node("paragraph", [:], text.isEmpty ? [] : [t(text)]) }
    static func h(_ level: Int, _ content: Node...) -> Node { node("heading", ["level": .int(level)], content) }
    static func blockquote(_ content: Node...) -> Node { node("blockquote", [:], content) }
    static func ul(_ content: Node...) -> Node { node("bulletList", [:], content) }
    static func li(_ content: Node...) -> Node { node("listItem", [:], content) }
    static func codeBlock(_ text: String) -> Node { node("codeBlock", [:], text.isEmpty ? [] : [t(text)]) }
    static func t(_ text: String) -> Node { schema.text(text) }
    static func strong(_ text: String) -> Node { schema.text(text, [schema.mark("bold")]) }
    static func code(_ text: String) -> Node { schema.text(text, [schema.mark("code")]) }

    static func state(_ doc: Node, anchor: Int? = nil, head: Int? = nil, plugins: [Plugin] = []) -> EditorState {
        var sel: Selection? = nil
        if let anchor { sel = TextSelection.create(doc, anchor, head) }
        return EditorState.create(EditorStateConfig(schema: schema, doc: doc, selection: sel, plugins: plugins))
    }

    static var bold: MarkType { schema.marks["bold"]! }
    static func type(_ name: String) -> NodeType { schema.nodes[name]! }
}

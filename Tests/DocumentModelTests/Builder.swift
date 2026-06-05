import DocumentModel

/// A lightweight document builder for tests, loosely modeled on
/// `prosemirror-test-builder`. Builds nodes from the `TestSchema`.
enum B {
    static let schema = TestSchema.schema

    static func node(_ type: String, _ attrs: Attrs = [:], _ content: [Node] = []) -> Node {
        try! schema.node(type, attrs, content: Fragment.from(content))
    }

    static func doc(_ content: Node...) -> Node { node("doc", [:], content) }
    static func p(_ content: Node...) -> Node { node("paragraph", [:], content) }
    static func p(_ text: String) -> Node { node("paragraph", [:], [t(text)]) }
    static func h(_ level: Int, _ content: Node...) -> Node { node("heading", ["level": .int(level)], content) }
    static func blockquote(_ content: Node...) -> Node { node("blockquote", [:], content) }
    static func ul(_ content: Node...) -> Node { node("bulletList", [:], content) }
    static func ol(_ content: Node...) -> Node { node("orderedList", [:], content) }
    static func li(_ content: Node...) -> Node { node("listItem", [:], content) }
    static func hr() -> Node { node("horizontalRule") }
    static func br() -> Node { node("hardBreak") }
    static func img(_ src: String) -> Node { node("image", ["src": .string(src)]) }

    static func t(_ text: String) -> Node { schema.text(text) }

    static func em(_ text: String) -> Node { schema.text(text, [schema.mark("italic")]) }
    static func strong(_ text: String) -> Node { schema.text(text, [schema.mark("bold")]) }
    static func code(_ text: String) -> Node { schema.text(text, [schema.mark("code")]) }
    static func link(_ text: String, _ href: String) -> Node {
        schema.text(text, [schema.mark("link", ["href": .string(href)])])
    }
}

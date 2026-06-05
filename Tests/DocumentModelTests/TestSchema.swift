import DocumentModel

/// A small schema mirroring Tiptap's StarterKit node/mark names (camelCase),
/// used across the model tests.
enum TestSchema {
    static let schema: Schema = {
        let nodes: [(String, NodeSpec)] = [
            ("doc", NodeSpec(content: "block+")),
            ("paragraph", NodeSpec(content: "inline*", group: "block")),
            ("blockquote", NodeSpec(content: "block+", group: "block", defining: true)),
            ("horizontalRule", NodeSpec(group: "block")),
            ("heading", NodeSpec(
                content: "inline*",
                group: "block",
                attrs: ["level": AttributeSpec(default: .int(1))],
                defining: true)),
            ("codeBlock", NodeSpec(content: "text*", marks: "", group: "block", code: true, defining: true)),
            ("text", NodeSpec(group: "inline")),
            ("image", NodeSpec(
                group: "inline",
                inline: true,
                attrs: [
                    "src": AttributeSpec(),
                    "alt": AttributeSpec(default: .null),
                    "title": AttributeSpec(default: .null),
                ])),
            ("hardBreak", NodeSpec(group: "inline", inline: true)),
            // Lists
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
}

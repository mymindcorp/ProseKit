import DocumentModel
import EditorStateKit
import EditorCommands

/// An inline image node (a leaf atom) with `src`, `alt`, and `title`.
public final class ImageExtension: NodeExtension {
    public let name = "image"
    public let inline: Bool
    public init(inline: Bool = true) { self.inline = inline }

    public var nodeSpec: NodeSpec {
        NodeSpec(
            group: inline ? "inline" : "block",
            inline: inline,
            atom: true,
            attrs: [
                "src": AttributeSpec(),
                "alt": AttributeSpec(default: .null),
                "title": AttributeSpec(default: .null),
            ],
            draggable: true)
    }
    public var html: HTMLSpec { HTMLSpec(tag: "img") }
}

/// Insert an image at the current selection.
public func insertImage(_ type: NodeType, src: String, alt: String? = nil, title: String? = nil) -> Command {
    { state, dispatch, _ in
        var attrs: Attrs = ["src": .string(src)]
        if let alt { attrs["alt"] = .string(alt) }
        if let title { attrs["title"] = .string(title) }
        guard let node = try? type.create(attrs) else { return false }
        dispatch?(state.tr.replaceSelectionWith(node).scrollIntoView())
        return true
    }
}

public extension Editor {
    /// Insert an image with the given source at the current selection.
    @discardableResult
    func insertImage(src: String, alt: String? = nil, title: String? = nil) -> Bool {
        guard let type = schema.nodes["image"] else { return false }
        return run(SchemaKit.insertImage(type, src: src, alt: alt, title: title))
    }
}

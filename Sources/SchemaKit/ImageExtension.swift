import DocumentModel
import EditorStateKit
import EditorCommands

/// An image node (a leaf atom) with `src`, `alt`, and `title`.
///
/// Block by default — each image takes up its own row. Pass `inline: true` for a
/// schema whose documents place images within a line of text (the editor renders
/// either mode; the only difference is whether an image can sit inside a textblock).
public final class ImageExtension: NodeExtension {
    public let name = "image"
    public let inline: Bool
    public init(inline: Bool = false) { self.inline = inline }

    public var nodeSpec: NodeSpec {
        NodeSpec(
            group: inline ? "inline" : "block",
            inline: inline,
            atom: true,
            attrs: [
                "src": AttributeSpec(),
                "alt": AttributeSpec(default: .null),
                "title": AttributeSpec(default: .null),
                // Displayed width in points; null renders at the natural width
                // (capped to the content area). Set by drag-to-resize.
                "width": AttributeSpec(default: .null),
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

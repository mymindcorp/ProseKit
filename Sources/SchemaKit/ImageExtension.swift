import DocumentModel
import EditorStateKit
import EditorCommands

/// An image node (a leaf atom) with `src`, `alt`, `title`, and a display size.
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
                // Displayed size in points. Either may be null: the missing one
                // is derived from the image's own aspect ratio, and with both
                // null the image draws at its natural size. Width is set by
                // drag-to-resize; a host that knows the dimensions up front can
                // set both, and then the placeholder reserves the right box and
                // nothing reflows when the bytes arrive.
                "width": AttributeSpec(default: .null),
                "height": AttributeSpec(default: .null),
            ],
            draggable: true)
    }
    public var html: HTMLSpec { HTMLSpec(tag: "img") }
}

/// Insert an image at the current selection.
public func insertImage(_ type: NodeType, src: String, alt: String? = nil, title: String? = nil,
                        width: Int? = nil, height: Int? = nil) -> Command {
    { state, dispatch, _ in
        var attrs: Attrs = ["src": .string(src)]
        if let alt { attrs["alt"] = .string(alt) }
        if let title { attrs["title"] = .string(title) }
        if let width { attrs["width"] = .int(width) }
        if let height { attrs["height"] = .int(height) }
        guard let node = try? type.create(attrs) else { return false }
        dispatch?(state.tr.replaceSelectionWith(node).scrollIntoView())
        return true
    }
}

/// Set an image's displayed size. A nil dimension is cleared, so the renderer
/// derives it from the other one and the image's aspect ratio; clearing both
/// returns the image to its natural size.
public func setImageSize(_ type: NodeType, width: Int?, height: Int?, pos: Int? = nil) -> Command {
    { state, dispatch, _ in
        guard let target = pos ?? imageNodePos(state, type),
              let node = state.doc.nodeAt(target), node.type === type else { return false }
        if let dispatch {
            let tr = state.tr
            _ = try? tr.setNodeAttribute(target, "width", width.map { .int($0) } ?? .null)
            _ = try? tr.setNodeAttribute(target, "height", height.map { .int($0) } ?? .null)
            dispatch(tr.scrollIntoView())
        }
        return true
    }
}

/// The position of the image the selection addresses: the node a
/// `NodeSelection` covers, else the one immediately after or before the cursor.
private func imageNodePos(_ state: EditorState, _ type: NodeType) -> Int? {
    if let sel = state.selection as? NodeSelection, sel.node.type === type { return sel.from }
    let from = state.selection.resolvedFrom
    if let after = from.nodeAfter, after.type === type { return from.pos }
    if let before = from.nodeBefore, before.type === type { return from.pos - before.nodeSize }
    return nil
}

public extension Editor {
    /// Insert an image with the given source at the current selection.
    ///
    /// Passing the size when it's known lets the renderer reserve the right box
    /// straight away, so the document doesn't reflow once the bytes load.
    @discardableResult
    func insertImage(src: String, alt: String? = nil, title: String? = nil,
                     width: Int? = nil, height: Int? = nil) -> Bool {
        guard let type = schema.nodes["image"] else { return false }
        return run(SchemaKit.insertImage(type, src: src, alt: alt, title: title,
                                         width: width, height: height))
    }

    /// Set the displayed size of the addressed image. A nil dimension is
    /// derived from the other and the image's aspect ratio; nil for both
    /// restores its natural size.
    @discardableResult
    func setImageSize(width: Int?, height: Int?, at pos: Int? = nil) -> Bool {
        guard let type = schema.nodes["image"] else { return false }
        return run(SchemaKit.setImageSize(type, width: width, height: height, pos: pos))
    }
}

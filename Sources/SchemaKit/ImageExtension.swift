public import DocumentModel
import EditorStateKit
public import EditorCommands
import DocumentTransform

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
                // The original image behind the presentation: `{ path, width,
                // height }`. `src` is what gets drawn — often a derived,
                // downscaled rendition — while this records what it was made
                // from, so the original can be exported, re-derived at another
                // size, or reasoned about without loading it. See `ImageModel`.
                "model": AttributeSpec(default: .null),
            ],
            draggable: true)
    }
    public var html: HTMLSpec { HTMLSpec(tag: "img") }
}

/// The original image behind an `image` node's presentation.
///
/// `src` and the display `width`/`height` describe what the reader sees; this
/// describes what it came from. Keeping both means a downscaled rendition can
/// be drawn without losing track of the original — its intrinsic size is also
/// what lets the renderer reserve a correctly-proportioned box before any bytes
/// have loaded.
///
/// Stored as an object attribute, so it round-trips through ProseMirror JSON as
/// a nested object rather than as encoded text.
public struct ImageModel: Hashable, Sendable {
    /// Where the original lives — whatever the host's resolver understands.
    public let path: String
    /// The original's intrinsic size in pixels, when known.
    public let width: Int?
    public let height: Int?

    public init(path: String, width: Int? = nil, height: Int? = nil) {
        self.path = path
        self.width = width
        self.height = height
    }

    /// Read a model back out of an attribute value. Nil when absent, or when
    /// it isn't an object with a `path` — a document from elsewhere can put
    /// anything here.
    public init?(_ value: AttributeValue?) {
        guard case let .object(fields)? = value,
              case let .string(path)? = fields["path"] else { return nil }
        self.path = path
        self.width = fields["width"]?.intValue
        self.height = fields["height"]?.intValue
    }

    /// The attribute value to store on the node. Absent dimensions are omitted
    /// rather than written as null, so the attribute stays the shape it reads as.
    public var attributeValue: AttributeValue {
        var fields: [String: AttributeValue] = ["path": .string(path)]
        if let width { fields["width"] = .int(width) }
        if let height { fields["height"] = .int(height) }
        return .object(fields)
    }
}

public extension Node {
    /// The original image behind this `image` node, if it records one.
    var imageModel: ImageModel? { ImageModel(attrs["model"]) }
}

/// Insert an image at the current selection.
public func insertImage(_ type: NodeType, src: String, alt: String? = nil, title: String? = nil,
                        width: Int? = nil, height: Int? = nil, model: ImageModel? = nil) -> Command {
    { state, dispatch, _ in
        var attrs: Attrs = ["src": .string(src)]
        if let alt { attrs["alt"] = .string(alt) }
        if let title { attrs["title"] = .string(title) }
        if let width { attrs["width"] = .int(width) }
        if let height { attrs["height"] = .int(height) }
        if let model { attrs["model"] = model.attributeValue }
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

/// Set (or, with nil, clear) the original-image model on an image node.
public func setImageModel(_ type: NodeType, _ model: ImageModel?, pos: Int? = nil) -> Command {
    { state, dispatch, _ in
        guard let target = pos ?? imageNodePos(state, type),
              let node = state.doc.nodeAt(target), node.type === type else { return false }
        if let dispatch,
           let tr = try? state.tr.setNodeAttribute(target, "model", model?.attributeValue ?? .null) {
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
                     width: Int? = nil, height: Int? = nil, model: ImageModel? = nil) -> Bool {
        guard let type = schema.nodes["image"] else { return false }
        return run(SchemaKit.insertImage(type, src: src, alt: alt, title: title,
                                         width: width, height: height, model: model))
    }

    /// Record (or clear) the original image behind the addressed image node.
    @discardableResult
    func setImageModel(_ model: ImageModel?, at pos: Int? = nil) -> Bool {
        guard let type = schema.nodes["image"] else { return false }
        return run(SchemaKit.setImageModel(type, model, pos: pos))
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

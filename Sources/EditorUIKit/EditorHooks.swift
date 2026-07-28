#if canImport(UIKit)
import UIKit
import DocumentModel

// Named types for the closures a host wires into the editor/document views.
// Using these (instead of inline closure types) keeps the view APIs readable
// and gives each hook one documented home.

/// Supplies raw image data for an image node — a host asset/database lookup.
/// Return nil to show a placeholder (a `src` URL is then loaded asynchronously).
public typealias ImageDataProvider = (_ node: Node) -> Data?

/// Called when the document's rendered height changes, so the host can size its
/// scroll view's content.
public typealias DocumentHeightHandler = (_ height: CGFloat) -> Void

/// Activates a link (Cmd-click / menu). Defaults to opening the URL with the
/// system when unset.
public typealias LinkActivationHandler = (_ url: URL) -> Void

/// Returns a badge label for a code block (e.g. its detected/explicit language)
/// given the block's text and `language` attribute; nil draws no badge.
public typealias CodeLanguageLabelProvider = (_ code: String, _ language: String?) -> String?

/// Supplies a fresh view for a task-item checkbox; the editor positions and
/// recycles the returned views.
public typealias CheckboxViewProvider = () -> any TaskCheckboxView

/// Handles a tap on a rendered formula — Tiptap's `onClick` for the math nodes.
/// The host typically opens an editor for the node's `latex` attribute and
/// writes the result back with `updateInlineMath` / `updateBlockMath`.
///
/// `node` is the `inlineMath` or `blockMath` node and `pos` its document
/// position, so the handler can address it without re-deriving either.
public typealias MathActivationHandler = (_ node: Node, _ pos: Int) -> Void

/// An image that arrived by drop or paste, with its raw bytes and (when known)
/// its uniform type identifier and a suggested file name.
public struct DroppedImage: Sendable {
    public let data: Data
    /// The source's UTI (e.g. "public.png", "public.jpeg"), if reported.
    public let typeIdentifier: String?
    /// A suggested file name from the source, if any.
    public let suggestedName: String?
    public init(data: Data, typeIdentifier: String?, suggestedName: String?) {
        self.data = data
        self.typeIdentifier = typeIdentifier
        self.suggestedName = suggestedName
    }
}

/// Handles an image dropped or pasted into the editor. Return the attributes for
/// the `image` node to insert — typically `["src": <a path/URL/asset id you
/// persisted the bytes to>]`, plus optional `alt`/`title`. Return nil to fall
/// back to the built-in behavior (embed the bytes as a `data:` URL).
public typealias ImageDropHandler = (_ image: DroppedImage) -> Attrs?

/// Resolves an image node to a URL the renderer can load — e.g. mapping a
/// relative path or a custom `asset://` id to a file URL. Receives the whole
/// node, so it can decide from any attribute (`src`, `width`, custom ids), not
/// just `src`. Return nil to let the built-in resolver handle `data:`, http(s),
/// `file:`, and absolute filesystem paths (from the node's `src`).
public typealias ImageURLResolver = (_ image: Node) -> URL?
#endif

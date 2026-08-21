#if canImport(UIKit)
public import UIKit
public import DocumentModel

// Named types for the closures a host wires into the editor/document views.
// Using these (instead of inline closure types) keeps the view APIs readable
// and gives each hook one documented home.

/// Supplies raw image data for an image node — a host asset/database lookup.
/// Return nil to show a placeholder (a `src` URL is then loaded asynchronously).
public typealias ImageDataProvider = (_ node: Node) -> Data?

/// Called when the document's rendered height changes, so the host can size its
/// scroll view's content.
public typealias DocumentHeightHandler = (_ height: CGFloat) -> Void

/// A link the reader activated: the node it lives on, and what that node
/// carries.
///
/// `node` is the inline node under the click — a text node for a `link` mark, or
/// the atom itself for a link-like atom (`wikiLink`, `mention`). A mark run can
/// cover several text nodes (adjacent children sharing an href are one link, but
/// stay separate nodes if their other marks differ), so `from`/`to` give the
/// whole run; re-slice the document from those when the one node isn't enough.
public struct LinkClick: Sendable {
    /// The inline node under the click.
    public let node: Node
    /// The link mark's attributes (`href`, `title`) — or, for a link-like atom,
    /// the node's own.
    public let attrs: Attrs
    /// Start of the whole link run, in document positions.
    public let from: Int
    /// End of the whole link run, in document positions.
    public let to: Int
    /// Whether the pointer was holding Cmd. A plain click and a Cmd-click both
    /// arrive here; branch on this if you want them to differ.
    public let commandHeld: Bool

    /// The `href` attribute, if the node has one. A `mention` typically won't.
    public var href: String? { attrs["href"]?.stringValue }
    /// The `title` attribute, if set.
    public var title: String? { attrs["title"]?.stringValue }
    /// `href` parsed as a URL, when it parses. Nothing is validated beyond
    /// that — decide for yourself whether a scheme is one you want to follow.
    public var url: URL? { href.flatMap(URL.init(string:)) }

    public init(node: Node, attrs: Attrs, from: Int, to: Int, commandHeld: Bool) {
        self.node = node
        self.attrs = attrs
        self.from = from
        self.to = to
        self.commandHeld = commandHeld
    }
}

/// Called when a click or tap activates a link. Setting it is what makes links
/// clickable at all: unset, a click just places the caret, the same as any other
/// text. Nothing is opened for you — follow the URL, refuse a scheme, resolve a
/// wiki-link in-app, whatever the host wants.
public typealias LinkClickHandler = (_ link: LinkClick) -> Void

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

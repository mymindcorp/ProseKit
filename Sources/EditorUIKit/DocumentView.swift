#if canImport(UIKit)
public import UIKit
public import DocumentModel
import EditorSerialization

/// A lightweight, **read-only** view that renders a document with the shared
/// layout engine and **only draws the visible window**.
///
/// Pin it to a scroll view's viewport and feed `contentOffsetY` to virtualize an
/// arbitrarily tall document (the same technique the editable `EditorTextView`
/// uses), or drop it in at its full `documentHeight` for short documents. Either
/// way, `draw(_:)` only paints the slice `[contentOffsetY, contentOffsetY +
/// bounds.height]`, so cost is independent of document length.
public final class DocumentView: UIView {
    /// The document to render. Setting it rebuilds the layout (incrementally,
    /// reusing unchanged blocks from the previous layout).
    public var document: Node? { didSet { invalidateLayout() } }
    /// Visual styling (fonts, colors, spacing).
    public var theme: DocumentTheme { didSet { invalidateLayout() } }
    /// The enclosing viewport's vertical scroll offset. Only the slice
    /// `[contentOffsetY, contentOffsetY + bounds.height]` is drawn.
    public var contentOffsetY: CGFloat = 0 { didSet { if oldValue != contentOffsetY { setNeedsDisplay() } } }
    /// Reports the rendered document height when it changes (size the scroll content from this).
    public var onDocumentHeightChange: DocumentHeightHandler?
    /// Supplies raw image bytes for an image node; nil draws a placeholder.
    public var imageData: ImageDataProvider?
    /// Resolves an image node to a loadable URL (relative paths, custom `asset://`
    /// ids — it sees all the node's attrs). nil falls back to the node's `src` as
    /// data:/http(s)/file/absolute path.
    public var imageURLResolver: ImageURLResolver?

    /// Optional hook to typeset `inlineMath` / `blockMath` nodes — assign
    /// `EditorMath.makeMathRenderer()`. Nil (the default) draws each formula's
    /// LaTeX source as monospaced text, which is what a read-only view showing
    /// a document full of maths would otherwise be stuck with.
    ///
    /// Setting it drops the typeset-block cache: an inline formula is laid out
    /// into its paragraph's cached block, so the cache would otherwise keep
    /// serving the un-rendered version.
    public var mathRenderer: MathRenderer? {
        didSet { blockCache.clear(); invalidateLayout() }
    }

    /// Optional hook to syntax-highlight code blocks — assign
    /// `EditorSyntax.makeSyntaxHighlighter()`. Nil (the default) renders code as
    /// plain monospaced text.
    ///
    /// Like the math renderer, setting it drops the typeset-block cache: a code
    /// block's colours are baked into its cached block, so the cache would
    /// otherwise keep serving the un-highlighted version.
    public var syntaxHighlighter: SyntaxHighlighter? {
        didSet { blockCache.clear(); invalidateLayout() }
    }

    /// Optional hook returning a badge label for a code block (e.g. its detected
    /// or explicit language) — assign `EditorSyntax.makeCodeLanguageLabel()`.
    /// Nil, or a nil return, draws no badge.
    public var codeLanguageLabel: CodeLanguageLabelProvider? {
        didSet { invalidateLayout() }
    }
    /// Supplies the view used for each task-item checkbox — the same hook as the
    /// editable `EditorTextView`. When nil, `DefaultTaskCheckboxView` is used.
    /// Checkboxes here are read-only: they render and reflect the document's
    /// `checked` state but don't respond to taps.
    public var checkboxViewProvider: CheckboxViewProvider? {
        didSet { checkboxOverlay.provider = checkboxViewProvider; checkboxOverlay.discard(); setNeedsDisplay() }
    }

    /// Manages the recycled checkbox views (positioning, pooling), shared with the
    /// editable editor. No `onToggle` handler → non-interactive.
    private lazy var checkboxOverlay: CheckboxOverlay = {
        let overlay = CheckboxOverlay(host: self)
        overlay.theme = theme
        overlay.provider = checkboxViewProvider
        return overlay
    }()

    private var layout: DocumentLayout?
    private var layoutWidth: CGFloat = 0
    private let blockCache = TextBlockLayoutCache()
    private var lastReportedHeight: CGFloat = -1
    private var hostImageCache: [Node: UIImage] = [:]
    private var imageCache: [String: UIImage] = [:]
    private var imageTasks: [String: Task<Void, Never>] = [:]

    /// Resolve an image node to a drawable image: the host data hook first
    /// (decoded + cached), then any image already loaded from its `src` URL.
    /// Returns nil to draw a placeholder (the layout records the node so
    /// `ensureLayout` kicks off an async load).
    private func resolveImage(_ node: Node) -> UIImage? {
        if let cached = hostImageCache[node] { return cached }
        if let data = imageData?(node), let image = UIImage(data: data) {
            hostImageCache[node] = image
            return image
        }
        return imageCache[node.attrs["src"]?.stringValue ?? ""]
    }

    /// Asynchronously load any images the layout couldn't resolve from a cache,
    /// then rebuild so they draw. Each node is resolved to a URL by the host
    /// (seeing all its attrs); the cache is keyed by `src`.
    private func loadPendingImages(_ nodes: [Node]) {
        for node in nodes {
            let src = node.attrs["src"]?.stringValue ?? ""
            let isInline = node.type.spec.inline
            guard !src.isEmpty, imageCache[src] == nil, imageTasks[src] == nil,
                  let url = resolveImageURL(node, resolver: imageURLResolver) else { continue }
            imageTasks[src] = Task { [weak self] in
                let image = await loadImage(from: url)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    self.imageTasks[src] = nil
                    if let image {
                        self.imageCache[src] = image
                        self.invalidateImageLayout(clearingTypesetBlocks: isInline)
                    }
                }
            }
        }
    }

    public init(document: Node? = nil, theme: DocumentTheme = DocumentTheme()) {
        self.document = document
        self.theme = theme
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Render a document parsed from a ProseMirror-JSON string.
    public convenience init(json: String, schema: Schema, theme: DocumentTheme = DocumentTheme()) throws {
        self.init(document: try Node.fromJSON(json, schema: schema), theme: theme)
    }

    /// Discard the cached layout and redraw.
    public func invalidateLayout() {
        layout = nil
        setNeedsDisplay()
    }

    /// Re-resolve every image and lay out again.
    ///
    /// Images are resolved *during* layout, so a host that didn't have the bytes
    /// yet got a placeholder, and nothing about the document changed when they
    /// arrived. Call this when `imageData` can answer for a node it previously
    /// couldn't, or when the bytes behind a node have changed.
    public func reloadImages() {
        hostImageCache.removeAll()
        invalidateImageLayout()
    }

    /// Drop every layout artifact with an image baked into it. An inline image
    /// is typeset into its paragraph's cached block, which is keyed by node and
    /// width — neither of which changed when the bytes arrived — so discarding
    /// the document layout alone leaves the placeholder in place.
    private func invalidateImageLayout(clearingTypesetBlocks: Bool = true) {
        // Only inline images live inside a typeset block; a block-level one is
        // resolved fresh each pass, so its arrival needn't cost a re-typeset of
        // every paragraph on screen.
        if clearingTypesetBlocks { blockCache.clear() }
        invalidateLayout()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        if layoutWidth != bounds.width { layout = nil; setNeedsDisplay() }
    }

    /// The cached layout for the current document + width, rebuilding if needed.
    @discardableResult
    func ensureLayout() -> DocumentLayout? {
        guard let document else { return nil }
        if let layout, layoutWidth == bounds.width { return layout }
        let l = DocumentLayout(doc: document, width: max(bounds.width, 1), theme: theme,
                               imageProvider: { [weak self] node in self?.resolveImage(node) },
                               blockCache: blockCache, previous: layout,
                               syntaxHighlighter: syntaxHighlighter,
                               codeLanguageLabel: codeLanguageLabel,
                               mathRenderer: mathRenderer)
        layout = l
        layoutWidth = bounds.width
        loadPendingImages(l.pendingImages)
        if l.height != lastReportedHeight {
            lastReportedHeight = l.height
            onDocumentHeightChange?(l.height)
        }
        return l
    }

    /// The full height of the rendered document (use it to size scroll content).
    public var documentHeight: CGFloat { ensureLayout()?.height ?? 0 }

    public override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: documentHeight)
    }

    public override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        render(into: ctx, height: bounds.height, offsetY: contentOffsetY)
        syncCheckboxes()
    }

    /// Position read-only checkbox views over the visible task items. Driven from
    /// `draw(_:)` — `contentOffsetY` and `invalidateLayout` both request a redraw,
    /// so this stays in step with scrolling, document, and theme changes.
    private func syncCheckboxes() {
        guard let l = ensureLayout() else { checkboxOverlay.discard(); return }
        checkboxOverlay.theme = theme
        checkboxOverlay.sync(l.checkboxes, offsetY: contentOffsetY,
                             viewportHeight: bounds.height, attached: window != nil)
    }

    /// Render this document's **visible window** into an arbitrary context —
    /// another view's `draw(_:)`, a bitmap, a PDF page. The slice starting at
    /// `offsetY` is translated to the top of the target and only blocks
    /// intersecting `[offsetY, offsetY + height]` are drawn (the rest is culled).
    public func render(into ctx: CGContext, height: CGFloat, offsetY: CGFloat) {
        guard let l = ensureLayout() else { return }
        ctx.saveGState()
        ctx.translateBy(x: 0, y: -offsetY)
        l.draw(in: ctx, clipY: offsetY ... (offsetY + max(height, 1)))
        ctx.restoreGState()
    }
}
#endif

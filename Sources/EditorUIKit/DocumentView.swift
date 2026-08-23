#if canImport(UIKit)
public import UIKit
public import DocumentModel
import EditorSerialization

/// A lightweight, **read-only** view that renders a document with the shared
/// layout engine and **only lays out and draws the visible window**.
///
/// Pin it to a scroll view's viewport and feed `contentOffsetY` to virtualize an
/// arbitrarily tall document (the same technique the editable `EditorTextView`
/// uses), or size it from `sizeThatFits` and drop it in at its full height.
///
/// `draw(_:)` only paints the slice `[contentOffsetY, contentOffsetY +
/// bounds.height]`. Typesetting is virtualized to match: past
/// `DocumentLayout.lazyThreshold` top-level children, only the blocks near the
/// viewport are laid out and the rest carry estimated heights until they are
/// scrolled near. So neither painting *nor* the layout behind it costs what the
/// whole document would — opening a long document does not typeset it.
///
/// The estimate is what `documentHeight` reports until the blocks behind it are
/// realized; `sizeThatFits` never estimates. See both for which to size from.
public final class DocumentView: UIView {
    /// The document to render. Setting it rebuilds the layout (incrementally,
    /// reusing unchanged blocks from the previous layout).
    public var document: Node? {
        didSet {
            // Bitmaps for images the new document doesn't hold are dead weight.
            if let document { imageStore.prune(keeping: document) } else { imageStore.purge() }
            invalidateLayout()
        }
    }
    /// Visual styling (fonts, colors, spacing).
    public var theme: DocumentTheme { didSet { invalidateLayout() } }
    /// The enclosing viewport's vertical scroll offset. Only the slice
    /// `[contentOffsetY, contentOffsetY + bounds.height]` is drawn.
    public var contentOffsetY: CGFloat = 0 {
        didSet {
            guard oldValue != contentOffsetY else { return }
            realizeVisibleIfNeeded()
            setNeedsDisplay()
        }
    }
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

    /// Optional hook supplying the leading glyph on a wiki-link chip — the
    /// host's own icon for whatever kind of object the node's `target` names.
    /// Nil (the default), or a nil return, draws the label alone.
    ///
    /// Only visible once the chip is styled: see `DocumentTheme.WikiLink`,
    /// which sets the glyph's size and the space it keeps from the label.
    /// Like the syntax highlighter, setting it drops the typeset-block cache —
    /// the glyph's box is reserved inside its paragraph's cached block, which
    /// would otherwise keep serving the version laid out without one.
    public var wikiLinkIcon: WikiLinkIconProvider? {
        didSet { blockCache.clear(); invalidateLayout() }
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
    /// In-flight image loads. Held separately from the store so `deinit` — which
    /// is not main-actor isolated — can cancel them.
    private let imageLoads = ImageLoadTasks()
    /// Decoded, display-sized images. See `DocumentImageStore`.
    private lazy var imageStore: DocumentImageStore = {
        let store = DocumentImageStore(loads: imageLoads)
        store.onLoaded = { [weak self] srcs, inline in self?.adoptLoadedImages(srcs, inline: inline) }
        return store
    }()

    /// Hand the image store the hooks and the geometry it decodes against — the
    /// content column, which is the widest box an image is ever drawn in.
    private func prepareImageStore() {
        imageStore.dataProvider = imageData
        imageStore.urlResolver = imageURLResolver
        imageStore.maxPointWidth = max(bounds.width - theme.pageInsets.left - theme.pageInsets.right, 1)
        let scale = traitCollection.displayScale
        imageStore.displayScale = scale > 0 ? scale : UIScreen.main.scale
    }

    /// Asynchronously load any images the layout couldn't resolve. The store
    /// calls back (coalesced) when they land.
    private func loadPendingImages(_ nodes: [Node]) {
        prepareImageStore()
        imageStore.load(nodes)
    }

    /// Adopt images that have just become drawable, re-laying only the blocks
    /// that show them rather than the whole document.
    private func adoptLoadedImages(_ srcs: Set<String>, inline: Bool) {
        guard let layout else { return }
        let arrived: (Node) -> Bool = { srcs.contains($0.attrs["src"]?.stringValue ?? "") }
        // An inline image is typeset into its paragraph's cached block, so that
        // block has to go before the relayout can pick it up — that block only.
        if inline {
            blockCache.evict { DocumentLayout.containsImage($0, matching: arrived) }
        }
        guard layout.relayoutImages(matching: arrived) else { return }
        setNeedsDisplay()
        guard layout.height != lastReportedHeight else { return }
        lastReportedHeight = layout.height
        onDocumentHeightChange?(layout.height)
    }

    /// Release decoded bitmaps and stop loading for a view nobody is looking at.
    /// What is laid out survives (a decoration holds its own reference), so this
    /// reclaims exactly the pictures that aren't being presented.
    private func releaseOffscreenImages() {
        imageStore.purge()
    }

    @objc private func handleMemoryWarning() {
        releaseOffscreenImages()
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { releaseOffscreenImages() }
    }

    deinit {
        imageLoads.cancelAll()
    }

    public init(document: Node? = nil, theme: DocumentTheme = DocumentTheme()) {
        self.document = document
        self.theme = theme
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        // The selector form deliberately: its registration is zeroing-weak, so
        // there is no token to unregister and nothing to leak.
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
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
        imageStore.reloadHostImages()
        invalidateImageLayout()
    }

    /// Drop every layout artifact with an image baked into it. An inline image
    /// is typeset into its paragraph's cached block, which is keyed by node and
    /// width — neither of which changed when the bytes arrived — so discarding
    /// the document layout alone leaves the placeholder in place.
    ///
    /// Wholesale, because `reloadImages()` says nothing about *which* images
    /// changed. Images that simply finish loading take the targeted path in
    /// `adoptLoadedImages` instead.
    private func invalidateImageLayout() {
        blockCache.clear()
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
        prepareImageStore()
        let l = DocumentLayout(doc: document, width: max(bounds.width, 1), theme: theme,
                               imageProvider: { [weak self] node in self?.imageStore.image(for: node) },
                               blockCache: blockCache, previous: layout,
                               realizeWindow: realizeWindow(),
                               syntaxHighlighter: syntaxHighlighter,
                               codeLanguageLabel: codeLanguageLabel,
                               mathRenderer: mathRenderer, wikiLinkIcon: wikiLinkIcon)
        layout = l
        layoutWidth = bounds.width
        loadPendingImages(l.pendingImages)
        if l.height != lastReportedHeight {
            lastReportedHeight = l.height
            onDocumentHeightChange?(l.height)
        }
        return l
    }

    /// The document y-window to typeset exactly: the visible slice plus a
    /// generous margin, so a block is laid out before it scrolls into view.
    /// On a document long enough for lazy layout, children outside it are
    /// height-estimated on the cold build and realized as they approach.
    private func realizeWindow() -> ClosedRange<CGFloat> {
        let margin = max(bounds.height * 2, 600)
        return (contentOffsetY - margin) ... (contentOffsetY + max(bounds.height, 1) + margin)
    }

    /// Typeset whatever is about to be painted, so an estimated block is never
    /// drawn blank.
    ///
    /// The window comes from the arguments rather than from `bounds`, because
    /// `render(into:height:offsetY:)` paints a slice that need not be this
    /// view's own viewport — a bitmap or a PDF page asks for its own band.
    ///
    /// Deliberately exactly the band being drawn, not the prefetch
    /// `realizeWindow()` asks for: the prefetch belongs on the scroll path, and
    /// the paint path should do the least that makes the frame in hand correct.
    private func realizeForPaint(_ layout: DocumentLayout, height: CGFloat, offsetY: CGFloat) {
        guard layout.hasEstimatedContent,
              layout.realize(window: offsetY ... (offsetY + max(height, 1)))
        else { return }
        loadPendingImages(layout.pendingImages)
        guard layout.height != lastReportedHeight else { return }
        lastReportedHeight = layout.height
        // Not synchronously: the host resizes its scroll content in response,
        // which re-enters our layout while this draw pass is reading it.
        let corrected = layout.height
        DispatchQueue.main.async { [weak self] in self?.onDocumentHeightChange?(corrected) }
    }

    /// Typeset any estimated blocks that have scrolled near the viewport, ahead
    /// of the frame that needs them.
    private func realizeVisibleIfNeeded() {
        guard let layout, layout.hasEstimatedContent,
              layout.realize(window: realizeWindow()) else { return }
        loadPendingImages(layout.pendingImages)
        setNeedsDisplay()
        guard layout.height != lastReportedHeight else { return }
        lastReportedHeight = layout.height
        onDocumentHeightChange?(layout.height)
    }

    /// The height of the rendered document (use it to size scroll content).
    ///
    /// On a document long enough to be laid out lazily this starts as an
    /// *estimate* of the parts not yet typeset. It converges as the reader
    /// scrolls, and every correction is reported to `onDocumentHeightChange` —
    /// so a virtualized host should size its scroll content from that handler
    /// rather than from a single read of this.
    public var documentHeight: CGFloat { ensureLayout()?.height ?? 0 }

    /// The exact size needed to show the whole document.
    ///
    /// Unlike `documentHeight` this never estimates. A host sizing a view from
    /// `sizeThatFits` is dropping it in at its full height and will never feed
    /// `contentOffsetY`, so no later scroll would correct an estimate — it pays
    /// for the whole document to be typeset, which is what asking for an exact
    /// answer costs.
    public override func sizeThatFits(_ size: CGSize) -> CGSize {
        guard let l = ensureLayout() else { return CGSize(width: size.width, height: 0) }
        if l.hasEstimatedContent, l.realize(window: 0 ... .greatestFiniteMagnitude) {
            loadPendingImages(l.pendingImages)
            lastReportedHeight = l.height
        }
        return CGSize(width: size.width, height: l.height)
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
        realizeForPaint(l, height: height, offsetY: offsetY)
        ctx.saveGState()
        ctx.translateBy(x: 0, y: -offsetY)
        l.draw(in: ctx, clipY: offsetY ... (offsetY + max(height, 1)))
        ctx.restoreGState()
    }
}
#endif

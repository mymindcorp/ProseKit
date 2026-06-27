#if canImport(UIKit)
import UIKit
import UniformTypeIdentifiers
import DocumentModel
import DocumentTransform
import EditorStateKit
import EditorCommands
import EditorKeymap
import SchemaKit
import EditorSerialization

/// One on-screen run of a highlight-mark background, passed to a custom
/// `EditorTextView.highlightRenderer`. `from`/`to` are the run's document range —
/// stable across scrolling, so a renderer can animate a given highlight over time
/// — and `rect` is its position in the draw context's (content) coordinates.
public struct HighlightRun {
    public let from: Int
    public let to: Int
    public let rect: CGRect
    public let color: UIColor
}

/// A UIKit view that renders an `Editor`'s document with CoreText and handles
/// text input, caret placement, key bindings, and selection. The shared engine
/// does all editing; this view only renders and translates input.
@MainActor
open class EditorTextView: UIView, UIKeyInput {
    public let editor: Editor
    public var theme: TextTheme { didSet { invalidateLayout() } }
    /// Text shown when the document is empty.
    public var placeholder: String? { didSet { setNeedsDisplay() } }
    /// Whether misspelled words are underlined.
    public var spellCheckingEnabled = true { didSet { spellCheckedVersion = -1; setNeedsDisplay() } }

    private var layout: DocumentLayout?
    private var lastLayoutWidth: CGFloat = 0
    private var caretLayer = CAShapeLayer()
    /// Insertion-point indicator shown while a drag session hovers the view.
    private var dropCursorLayer = CAShapeLayer()
    private var blinkTimer: Timer?
    /// Native selection UI (loupe, handles, edit menu, tap-to-place caret).
    private var textInteraction: UITextInteraction?
    private weak var columnResizeRecognizer: UIGestureRecognizer?
    private weak var linkTapRecognizer: UIGestureRecognizer?
    private weak var blockDragRecognizer: UIGestureRecognizer?
    private weak var imageResizeRecognizer: UIGestureRecognizer?

    /// When true, each top-level block shows a drag handle in the left gutter
    /// that reorders the block by dragging. Off by default.
    public var blockReorderingEnabled = false { didSet { setNeedsDisplay() } }
    /// In-progress block drag: source index and the current drop gap.
    private var blockDrag: (sourceIndex: Int, dropIndex: Int)?
    /// Desktop hover: the block under the pointer (handles reveal on hover);
    /// nil on touch, where all handles show. `usesPointer` flips true once a
    /// pointer is seen, switching from always-on to hover-reveal handles.
    private var hoveredBlockIndex: Int?
    private var usesPointer = false

    /// When false, the view is read-only: text input, the caret/keyboard, drag &
    /// resize handles, drops, and editing menu actions are all suppressed —
    /// selection, copy, select-all, and find still work. Defaults to true.
    public var isEditable: Bool = true {
        didSet { if oldValue != isEditable { installTextInteraction(); setNeedsDisplay() } }
    }

    /// When true (the default), each block image shows a resize handle at its
    /// bottom-right corner; dragging it sets the image's `width` attribute.
    public var imageResizingEnabled = true { didSet { setNeedsDisplay() } }
    /// In-progress image resize: the image's document position and the left edge
    /// of its drawn rect (captured at drag start; the left edge doesn't move as
    /// the width changes, since images are left-aligned).
    private var imageResize: (pos: Int, leftX: CGFloat)?
    /// Desktop hover: the block image under the pointer, whose resize handle is
    /// revealed. nil on touch, where every image's handle shows.
    private var hoveredImagePos: Int?
    /// Whether the active color picker targets background (vs foreground) color.
    private var colorPickerTargetsBackground = false

    /// Supplies the view used for each task-item checkbox. When nil, the editor
    /// uses `DefaultTaskCheckboxView` (circle + check, themed, animated). The
    /// editor positions and recycles the returned views as items scroll; your
    /// factory should return a fresh, unconfigured view each call.
    public var checkboxViewProvider: CheckboxViewProvider? {
        didSet { checkboxOverlay.provider = checkboxViewProvider; checkboxOverlay.discard(); setNeedsLayout() }
    }
    /// Manages the recycled checkbox views (positioning, pooling). Interactive
    /// here — a tap toggles the task item's `checked` attribute. The same overlay
    /// drives the read-only `DocumentView` (without a toggle handler).
    private lazy var checkboxOverlay: CheckboxOverlay = {
        let overlay = CheckboxOverlay(host: self)
        overlay.theme = theme
        overlay.provider = checkboxViewProvider
        overlay.onToggle = { [weak self] pos in self?.toggleCheckbox(at: pos) }
        return overlay
    }()

    /// Called when a link is activated (Cmd-click on macOS / iPad). Defaults to
    /// opening the URL with the system; set it to handle links yourself (e.g.
    /// follow a wiki-link in-app, or confirm before leaving).
    public var onOpenLink: LinkActivationHandler?
    /// The document range being dragged (set while a local drag we started is in
    /// flight), so a drop back into this document moves rather than copies.
    private var dragSourceRange: (from: Int, to: Int)?

    /// The image node (and its document range) being dragged, when the drag was
    /// started by grabbing an existing image. A drop back into this document
    /// moves that exact node; a drop elsewhere hands its bytes to another app.
    private var draggingImage: (node: Node, from: Int, to: Int)?

    // MARK: - Suggestion menus
    //
    // Fully generic: any extension that provides a `SuggestionSource` (slash `/`,
    // wiki `[[`, `@` mentions, …) gets a popup here. The view knows nothing about
    // specific triggers — it just asks the editor's sources which is active.

    private var activeEntries: [SuggestionEntry] = []
    private var suggestionPopup: SuggestionPopupView?

    public init(editor: Editor, theme: TextTheme = TextTheme(), frame: CGRect = .zero) {
        self.editor = editor
        self.theme = theme
        super.init(frame: frame)
        backgroundColor = .systemBackground
        isUserInteractionEnabled = true
        contentMode = .redraw
        caretLayer.fillColor = theme.caretColor.cgColor
        // The caret must jump instantly; suppress Core Animation's implicit
        // ~0.25s animation on geometry changes (opacity still animates to blink).
        caretLayer.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull(), "fillColor": NSNull()]
        layer.addSublayer(caretLayer)
        dropCursorLayer.fillColor = theme.caretColor.withAlphaComponent(0.8).cgColor
        dropCursorLayer.actions = caretLayer.actions
        layer.addSublayer(dropCursorLayer)

        // Native text interaction: caret placement, the loupe/magnifier,
        // selection handles, and the edit menu — all driven by our UITextInput
        // conformance. Editable vs read-only (.nonEditable: selection without a
        // caret/keyboard) is chosen by `installTextInteraction`.
        installTextInteraction()

        // Our own gestures handle only what UITextInteraction doesn't: toggling
        // task-list checkboxes and dragging table column borders. Each is gated
        // (via the gesture delegate) to begin only on its target, so ordinary
        // taps and selection drags fall through to UITextInteraction.
        let columnResize = UIPanGestureRecognizer(target: self, action: #selector(handleMouseDrag(_:)))
        let linkTap = UITapGestureRecognizer(target: self, action: #selector(handleLinkTap(_:)))
        let blockDrag = UIPanGestureRecognizer(target: self, action: #selector(handleBlockDrag(_:)))
        let imageResize = UIPanGestureRecognizer(target: self, action: #selector(handleImageResize(_:)))
        // Triple-tap selects the whole paragraph (UITextInteraction only does
        // caret/word) — matching Notes and other rich editors.
        let tripleTap = UITapGestureRecognizer(target: self, action: #selector(handleTripleTap(_:)))
        tripleTap.numberOfTapsRequired = 3
        columnResizeRecognizer = columnResize
        linkTapRecognizer = linkTap
        blockDragRecognizer = blockDrag
        imageResizeRecognizer = imageResize
        for recognizer in [columnResize, linkTap, blockDrag, imageResize, tripleTap] as [UIGestureRecognizer] {
            recognizer.delegate = self
            recognizer.cancelsTouchesInView = false
            addGestureRecognizer(recognizer)
        }

        // Drag selected text/images out, and drop text/images in (move within the
        // document, or copy from another app).
        addInteraction(UIDragInteraction(delegate: self))
        addInteraction(UIDropInteraction(delegate: self))
        // Pointer cursors (macOS / iPad trackpad): I-beam over text, hover
        // shape over checkboxes, resize arrows over table column borders.
        addInteraction(UIPointerInteraction(delegate: self))
        // NOTE: a custom edit-menu interaction is installed lazily — only when the
        // host sets `editMenuItems` — so the system's native callout (with Writing
        // Tools / Rewrite) stays intact by default. See `editMenuItems`.

        editor.onTransaction = { [weak self] tr in self?.mapSpellCache(through: tr) }
        editor.onChange = { [weak self] _ in self?.setNeedsRebuild(); self?.fireSelectionChange() }
        // Let async suggestion sources (e.g. a DB-backed `[[`) repaint the popup
        // when their results arrive, by re-pulling the active source.
        for source in editor.suggestionSources {
            source.onChange = { [weak self] in self?.updateSuggestionPopup() }
        }
        registerForDynamicTypeChanges()
    }

    /// The editor's document revision — bumped only when the document actually
    /// changes (not on selection moves), so caret moves / clicks / scrolling
    /// never invalidate the layout. O(1) cache key.
    private var docVersion: Int { editor.docRevision }
    private let blockCache = TextBlockLayoutCache()

    /// Optional hook to syntax-highlight code blocks. Nil (the default) renders
    /// code as plain monospaced text. Setting it re-typesets code blocks.
    public var syntaxHighlighter: SyntaxHighlighter? {
        didSet { blockCache.clear(); invalidateLayout() }
    }

    /// Optional hook returning a badge label for a code block (e.g. its detected
    /// or explicit language), given the block's text and `language` attribute.
    /// Nil (the default), or a nil return, draws no badge.
    public var codeLanguageLabel: CodeLanguageLabelProvider? {
        didSet { invalidateLayout() }
    }

    /// Vertical scroll offset; the host feeds the enclosing scroll view's offset
    /// so the view renders only the visible window (bounded layer + culling).
    public var contentOffsetY: CGFloat = 0 {
        // Scrolling only repositions the caret layer; it must NOT reveal the
        // caret (that would scroll back to the cursor and fight the user).
        didSet { if oldValue != contentOffsetY { realizeVisibleIfNeeded(); setNeedsDisplay(); positionCaretLayer(); syncCheckboxViews(); updateSuggestionPopup(); notifySelectionGeometryChanged(); fireSelectionChange() } }
    }
    /// The full document height; the host uses it as the scroll content height.
    public var documentHeight: CGFloat { ensureLayout().height }
    /// Called when the document height changes (so the host can resize the
    /// scroll content).
    public var onDocumentHeightChange: DocumentHeightHandler?
    private var lastReportedHeight: CGFloat = -1

    // MARK: - UITextInput state
    /// The system input delegate, notified when text/selection change outside
    /// of a UITextInput-initiated edit.
    weak var textInputDelegate: (any UITextInputDelegate)?
    /// The marked (composing/IME) range in document positions, if any.
    var markedRange: (Int, Int)?
    var markedTextStyleStore: [NSAttributedString.Key: Any]?
    /// Set while applying a UITextInput-initiated edit, so our `onChange` hook
    /// doesn't echo the change back to the input delegate (which would confuse
    /// autocorrect / marked-text state).
    var applyingTextInput = false
    lazy var inputTokenizer: any UITextInputTokenizer = UITextInputStringTokenizer(textInput: self)

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Layout lifecycle

    private func setNeedsRebuild() {
        // Tell the system input system about changes it didn't initiate (caret
        // moves, key edits) so autocorrect / marked text stay in sync.
        if !applyingTextInput { textInputDelegate?.selectionDidChange(self) }
        updateSuggestionPopup()
        // The layout is rebuilt lazily by `ensureLayout`, and only when the
        // document or width actually changes — selection/caret/scroll changes
        // reuse the existing layout (avoiding a full relayout per keystroke move).
        setNeedsDisplay()
        invalidateIntrinsicContentSize()
        updateCaret()
        // Checkbox views track the document; reposition/re-sync after the
        // deferred layout rebuild (keeps the per-keystroke layout lazy).
        setNeedsLayout()
    }

    /// Supplies raw image bytes for an image node (e.g. from the host's asset
    /// store). When it returns nil the renderer loads the node's `src` URL, and
    /// otherwise draws a placeholder. See `ImageDataProvider`.
    public var imageData: ImageDataProvider?

    /// Handles an image dropped/pasted into the editor — persist the bytes and
    /// return the `image` node attributes (e.g. `["src": ...]`). When nil (or it
    /// returns nil) the bytes are embedded as a `data:` URL. See `ImageDropHandler`.
    public var onImageDrop: ImageDropHandler?

    /// Resolves an image node's `src` to a loadable URL (relative paths, custom
    /// asset ids). When nil, `data:`/http(s)/`file:`/absolute paths are handled
    /// built-in. See `ImageURLResolver`.
    public var imageURLResolver: ImageURLResolver?

    private var imageCache: [String: UIImage] = [:]
    private var imageTasks: [String: Task<Void, Never>] = [:]
    /// Decoded host-provided images, keyed by the image node (avoids re-decoding).
    private var hostImageCache: [Node: UIImage] = [:]

    /// Resolve an image node to a drawable image: the host data hook first (decoded
    /// + cached), then any image already loaded from its `src` URL. Returns nil to
    /// draw a placeholder (and, for a non-empty `src`, kick off an async load).
    private func resolveImage(_ node: Node) -> UIImage? {
        if let cached = hostImageCache[node] { return cached }
        if let data = imageData?(node), let image = UIImage(data: data) {
            hostImageCache[node] = image
            return image
        }
        return imageCache[node.attrs["src"]?.stringValue ?? ""]
    }

    /// Force a full relayout on the next draw (for theme / Dynamic Type changes
    /// where the document is unchanged but fonts/sizing differ).
    private func invalidateLayout() {
        layout = nil
        layoutVersion = -1
        setNeedsRebuild()
    }

    // A flat text projection with exactly one character per document position
    // (real characters for text, a placeholder per node-boundary/atom token).
    // This keeps `text(in:).count == offset(from:to:)`, the invariant UIKit's
    // text input relies on — without it, character-index arithmetic across block
    // boundaries lands inserts on the wrong line.
    /// The flat projection of document positions `[from, to)` — exactly one
    /// character per position (text verbatim, `\u{fffc}` for leaf atoms, `\n` for
    /// node-boundary tokens). Computed over only the requested span (via
    /// `nodesBetween`), so `text(in:)` is O(range), not O(document).
    func projectedText(from: Int, to: Int) -> String {
        guard to > from else { return "" }
        var chars: [Character] = []
        chars.reserveCapacity(to - from)
        var cursor = from
        func fillGap(upTo end: Int) { while cursor < end { chars.append("\n"); cursor += 1 } }
        editor.doc.nodesBetween(from, to) { node, pos, _, _ in
            if node.isText {
                let s = Array(node.text ?? "")
                let lo = max(from, pos) - pos
                let hi = min(to, pos + s.count) - pos
                guard lo < hi else { return false }
                fillGap(upTo: pos + lo)
                chars.append(contentsOf: s[lo..<hi])
                cursor = pos + hi
                return false
            } else if node.isLeaf {
                guard pos >= from, pos < to else { return false }
                fillGap(upTo: pos)
                chars.append("\u{fffc}")
                cursor = pos + 1
                return false
            }
            return true // descend into containers; their tokens become gap "\n"
        }
        fillGap(upTo: to)
        return String(chars)
    }

    private var layoutVersion = -1

    func ensureLayout() -> DocumentLayout {
        if let layout, lastLayoutWidth == bounds.width, layoutVersion == docVersion { return layout }
        let l = DocumentLayout(doc: editor.doc, width: max(bounds.width, 1), theme: theme,
                               imageProvider: { [weak self] node in self?.resolveImage(node) },
                               blockCache: blockCache, previous: layout, realizeWindow: realizeWindow(),
                               syntaxHighlighter: syntaxHighlighter, codeLanguageLabel: codeLanguageLabel)
        layout = l
        lastLayoutWidth = bounds.width
        layoutVersion = docVersion
        loadPendingImages(l.pendingImages)
        if l.height != lastReportedHeight {
            lastReportedHeight = l.height
            onDocumentHeightChange?(l.height)
        }
        return l
    }

    /// The document y-window to lay out exactly (the viewport ± a generous
    /// margin). Children outside it are height-estimated on a cold build of a
    /// very large document, then realized here as they scroll near the viewport.
    private func realizeWindow() -> ClosedRange<CGFloat> {
        let margin = max(bounds.height * 2, 600)
        return (contentOffsetY - margin) ... (contentOffsetY + max(bounds.height, 1) + margin)
    }

    /// The system draws the selection highlight + handles AND its own caret from
    /// our `UITextInput` geometry, which is in view coordinates. Our virtualized
    /// scrolling changes that geometry without moving the view, so the system
    /// keeps a stale position — tell it to re-query. This must fire for a
    /// COLLAPSED caret too (an empty selection): otherwise UITextInteraction
    /// leaves its native caret stranded on scroll, appearing as a second,
    /// motionless cursor beside the one we draw.
    private func notifySelectionGeometryChanged() {
        guard !applyingTextInput else { return }
        textInputDelegate?.selectionWillChange(self)
        textInputDelegate?.selectionDidChange(self)
    }

    /// Report the selection's on-screen geometry to `onSelectionChange` (for a
    /// host-drawn bubble menu). Rects are in view coordinates.
    private func fireSelectionChange() {
        guard let onSelectionChange else { return }
        let sel = editor.state.selection
        guard !sel.empty else { onSelectionChange([], true); return }
        let rects = ensureLayout().selectionRects(from: sel.from, to: sel.to)
            .map { $0.offsetBy(dx: 0, dy: -contentOffsetY) }
        onSelectionChange(rects, false)
    }

    /// If the caret sits in a still-estimated (off-screen) block under lazy
    /// layout, realize the region around it so `caretRect`/`revealRect` can scroll
    /// to it (e.g. ⌘↓ to the end of a huge document, or a programmatic selection).
    private func realizeCaretRegionIfNeeded() {
        guard let layout, layout.hasEstimatedContent else { return }
        let head = editor.state.selection.head
        guard layout.isEstimated(pos: head),
              layout.realize(aroundPos: head, viewportHeight: bounds.height) else { return }
        loadPendingImages(layout.pendingImages)
        if layout.height != lastReportedHeight {
            lastReportedHeight = layout.height
            onDocumentHeightChange?(layout.height)
        }
        setNeedsDisplay()
    }

    /// Typeset any estimated blocks that have scrolled near the viewport.
    private func realizeVisibleIfNeeded() {
        guard let layout, layout.hasEstimatedContent, layout.realize(window: realizeWindow()) else { return }
        loadPendingImages(layout.pendingImages)
        if layout.height != lastReportedHeight {
            lastReportedHeight = layout.height
            onDocumentHeightChange?(layout.height)
        }
        setNeedsDisplay()
    }

    /// Asynchronously load any images the layout couldn't find in the cache,
    /// then rebuild so they draw at their intrinsic size. Each node is resolved
    /// to a URL by the host (seeing all its attrs); the cache is keyed by `src`.
    private func loadPendingImages(_ nodes: [Node]) {
        for node in nodes {
            let src = node.attrs["src"]?.stringValue ?? ""
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
                        self.setNeedsRebuild()
                    }
                }
            }
        }
    }

    /// Test hook: the resolved load URL for an image with the given `src`.
    func imageURLForTesting(_ src: String) -> URL? {
        guard let node = try? editor.schema.node("image", ["src": .string(src)]) else { return nil }
        return resolveImageURL(node, resolver: imageURLResolver)
    }

    open override func layoutSubviews() {
        super.layoutSubviews()
        if lastLayoutWidth != bounds.width { setNeedsRebuild() }
        syncCheckboxViews()
    }

    /// Re-lay-out when Dynamic Type changes, via the modern trait-change API.
    private func registerForDynamicTypeChanges() {
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: EditorTextView, _) in
            view.invalidateLayout()
        }
    }

    open override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: ensureLayout().height)
    }

    open override func sizeThatFits(_ size: CGSize) -> CGSize {
        // Use the cached layout — never a fresh full typeset, which would re-lay
        // out the entire document on every layout pass.
        CGSize(width: size.width, height: ensureLayout().height)
    }

    // MARK: - Drawing

    open override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let l = ensureLayout()
        // Everything is laid out in document coordinates; shift by the scroll
        // offset so we render only the visible window into a viewport-sized layer.
        ctx.saveGState()
        ctx.translateBy(x: 0, y: -contentOffsetY)
        let visibleY = contentOffsetY ... (contentOffsetY + max(bounds.height, 1))
        func onScreen(_ r: CGRect) -> Bool { r.maxY >= visibleY.lowerBound && r.minY <= visibleY.upperBound }

        // Placeholder when the document is empty.
        if let placeholder, !placeholder.isEmpty, isDocumentEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: theme.bodyFont, .foregroundColor: theme.codeColor]
            NSAttributedString(string: placeholder, attributes: attrs).draw(at: CGPoint(x: theme.pageInsets.left, y: theme.pageInsets.top))
        }
        // Plugin (e.g. search highlight) backgrounds.
        let decorations = gatherDecorations()
        for deco in decorations where deco.kind == .inline || deco.kind == .node {
            // Suggested insertions are tinted by their author; otherwise an
            // explicit background attribute, else a known decoration class (the
            // ported search/table plugins emit upstream's class names only).
            let color: UIColor?
            if deco.attributes["class"] == "insertion" {
                color = Self.authorColor(deco.attributes["data-author"]).withAlphaComponent(0.20)
            } else {
                color = deco.attributes["background"].flatMap { UIColor(hex: $0) }
                    ?? Self.decorationClassColor(deco.attributes["class"])
            }
            guard let color else { continue }
            ctx.setFillColor(color.cgColor)
            if deco.kind == .node {
                // Fill the decorated node's full block frames, not just text.
                for b in l.blocks where b.contentStart >= deco.from && b.contentEnd <= deco.to {
                    let r = b.frame.insetBy(dx: -2, dy: -1)
                    if onScreen(r) { ctx.fill(r) }
                }
            } else {
                for r in l.selectionRects(from: deco.from, to: deco.to) where onScreen(r) { ctx.fill(r) }
            }
        }
        // Suggested deletions (track changes): the removed text floats just
        // above the deletion point, struck through in red.
        for deco in decorations where deco.kind == .widget && deco.attributes["class"] == "deletion" {
            guard var text = deco.attributes["data-text"], !text.isEmpty else { continue }
            if text.count > 40 { text = String(text.prefix(40)) + "…" }
            guard let caret = l.caretRect(at: deco.from), onScreen(caret) else { continue }
            let color = Self.authorColor(deco.attributes["data-author"])
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: theme.bodyFont.pointSize * 0.75),
                .foregroundColor: color,
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .strikethroughColor: color,
            ]
            let ns = NSAttributedString(string: text, attributes: attrs)
            let size = ns.size()
            let origin = CGPoint(x: caret.minX, y: caret.minY - size.height + 2)
            ctx.setFillColor(color.withAlphaComponent(0.08).cgColor)
            ctx.fill(CGRect(x: origin.x - 2, y: origin.y - 1, width: size.width + 4, height: size.height + 2))
            ns.draw(at: origin)
        }
        // Selection highlight (every range — a cell selection has several).
        let sel = editor.state.selection
        if !sel.empty {
            ctx.setFillColor(theme.selectionColor.cgColor)
            for range in sel.ranges {
                for r in l.selectionRects(from: range.from.pos, to: range.to.pos) where onScreen(r) { ctx.fill(r) }
            }
        }
        l.draw(in: ctx, clipY: visibleY, highlightRenderer: highlightRenderer)

        // Spelling underlines — skip the word under the caret, and only the
        // misspellings within the visible block window (bounds the work on huge
        // documents).
        if let visiblePos = visiblePositionRange(l, y: visibleY) {
            ctx.setStrokeColor(UIColor.systemRed.cgColor)
            ctx.setLineWidth(1.5)
            ctx.setLineDash(phase: 0, lengths: [2, 2])
            for (from, to) in visibleSpellingRanges(decorations) where to >= visiblePos.lowerBound && from <= visiblePos.upperBound {
                for r in l.selectionRects(from: from, to: to) where onScreen(r) {
                    let y = r.maxY - 1
                    ctx.move(to: CGPoint(x: r.minX, y: y))
                    ctx.addLine(to: CGPoint(x: r.maxX, y: y))
                }
            }
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }

        // Marked (IME / composing) text: a solid underline.
        if let m = markedRange {
            ctx.setStrokeColor(theme.textColor.cgColor)
            ctx.setLineWidth(1)
            for r in l.selectionRects(from: m.0, to: m.1) where onScreen(r) {
                let y = r.maxY - 0.5
                ctx.move(to: CGPoint(x: r.minX, y: y))
                ctx.addLine(to: CGPoint(x: r.maxX, y: y))
            }
            ctx.strokePath()
        }

        // Remote collaboration cursors (other participants / agents).
        for cursor in editor.collabCursors {
            guard let color = UIColor(hex: cursor.color) else { continue }
            // Selection highlight (when not collapsed).
            if !cursor.isCollapsed {
                ctx.setFillColor(color.withAlphaComponent(0.25).cgColor)
                for r in l.selectionRects(from: min(cursor.anchor, cursor.head), to: max(cursor.anchor, cursor.head)) where onScreen(r) {
                    ctx.fill(r)
                }
            }
            guard let caret = l.caretRect(at: min(cursor.head, editor.doc.content.size)), onScreen(caret) else { continue }
            let bar = CGRect(x: caret.minX, y: caret.minY, width: 2, height: caret.height)
            ctx.setFillColor(color.cgColor)
            ctx.fill(bar)
            drawCollabLabel(cursor.label, color: color, at: bar, in: ctx)
        }

        // Block drag handles + drop indicator (reordering).
        if blockReorderingEnabled, isEditable {
            let entries = l.entries
            for i in entries.indices {
                guard blockHandleVisible(i), let handle = blockHandleRect(forEntryAt: i), onScreen(handle) else { continue }
                let active = blockDrag?.sourceIndex == i
                ctx.setFillColor(theme.quoteBarColor.withAlphaComponent(active ? 0.9 : 0.45).cgColor)
                // Six grip dots (2 columns × 3 rows).
                let dot: CGFloat = 2.5, gapX: CGFloat = 4, gapY: CGFloat = 5
                let ox = handle.minX + 2, oy = handle.midY - gapY
                for r in 0..<3 { for c in 0..<2 {
                    ctx.fillEllipse(in: CGRect(x: ox + CGFloat(c) * gapX, y: oy + CGFloat(r) * gapY, width: dot, height: dot))
                } }
            }
            if let drag = blockDrag, drag.dropIndex != drag.sourceIndex, drag.dropIndex != drag.sourceIndex + 1 {
                let y: CGFloat = drag.dropIndex < entries.count
                    ? entries[drag.dropIndex].topY
                    : (entries.last.map { $0.topY + $0.height } ?? 0)
                ctx.setFillColor(theme.caretColor.cgColor)
                ctx.fill(CGRect(x: theme.pageInsets.left, y: y - 1, width: max(bounds.width, 1) - theme.pageInsets.left * 2, height: 2))
            }
        }

        // Image resize handles: a grip at each block image's bottom-right corner.
        if imageResizingEnabled, isEditable {
            for (pos, rect) in l.imageRects {
                let handle = imageResizeHandleRect(for: rect)
                guard imageHandleVisible(pos), onScreen(handle) else { continue }
                let active = imageResize?.pos == pos
                let grip = handle.insetBy(dx: 2, dy: 2)
                let path = UIBezierPath(roundedRect: grip, cornerRadius: 2).cgPath
                ctx.setFillColor(UIColor.systemBackground.withAlphaComponent(0.9).cgColor)
                ctx.addPath(path); ctx.fillPath()
                ctx.setStrokeColor(theme.caretColor.withAlphaComponent(active ? 1 : 0.7).cgColor)
                ctx.setLineWidth(active ? 2 : 1.5)
                ctx.addPath(path); ctx.strokePath()
            }
        }
        ctx.restoreGState()
    }

    /// A small name flag above a remote caret.
    private func drawCollabLabel(_ label: String, color: UIColor, at caret: CGRect, in ctx: CGContext) {
        guard !label.isEmpty else { return }
        let font = UIFont.systemFont(ofSize: 10, weight: .semibold)
        let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: UIColor.white])
        let textSize = text.size()
        let pad: CGFloat = 4
        let flag = CGRect(x: caret.minX, y: caret.minY - (textSize.height + 4), width: textSize.width + pad * 2, height: textSize.height + 2)
        ctx.setFillColor(color.cgColor)
        UIBezierPath(roundedRect: flag, cornerRadius: 3).fill()
        text.draw(at: CGPoint(x: flag.minX + pad, y: flag.minY + 1))
    }

    /// The document-position range spanned by the blocks intersecting the
    /// visible y window (for culling per-position drawing on large documents).
    private func visiblePositionRange(_ l: DocumentLayout, y: ClosedRange<CGFloat>) -> ClosedRange<Int>? {
        var lo = Int.max, hi = Int.min
        for b in l.blocks where b.frame.maxY >= y.lowerBound && b.frame.minY <= y.upperBound {
            lo = min(lo, b.contentStart); hi = max(hi, b.contentEnd)
        }
        return lo <= hi ? lo...hi : nil
    }

    /// The misspelled ranges that should currently be underlined: every spelling
    /// decoration except the one containing the collapsed caret (the word being
    /// typed isn't flagged until the caret leaves it — e.g. after a space).
    func visibleSpellingRanges(_ decorations: [Decoration]) -> [(Int, Int)] {
        let sel = editor.state.selection
        let caret: Int? = sel.empty ? sel.head : nil
        return decorations.compactMap { deco in
            guard deco.attributes["spelling"] != nil else { return nil }
            if let caret, caret >= deco.from, caret <= deco.to { return nil }
            return (deco.from, deco.to)
        }
    }

    var spellCache: [Decoration] = []
    private var spellCheckedVersion = -1
    private var spellCheckedRange: ClosedRange<Int>?

    /// Collect decorations contributed by the active plugins, plus spelling.
    private func gatherDecorations() -> [Decoration] {
        var result: [Decoration] = []
        for plugin in editor.state.plugins {
            if let provider = plugin.props?.decorations, let set = provider(editor.state) {
                result.append(contentsOf: set.find())
            }
        }
        result.append(contentsOf: currentSpellDecorations())
        return result
    }

    /// Spell-check decorations, **debounced** (only after scrolling/typing
    /// settles) and **bounded to the visible region** (± a viewport margin), so a
    /// pass is cheap enough to run on the main actor (`UITextChecker` is main-
    /// actor isolated). `draw` shows the last result until the next pass lands.
    private var spellWorkItem: DispatchWorkItem?

    /// The visible document range to spell-check (± a viewport margin), or nil
    /// when nothing is laid out.
    private func spellTargetRange() -> ClosedRange<Int>? {
        let margin = max(bounds.height, 300)
        let expandedY = (contentOffsetY - margin) ... (contentOffsetY + max(bounds.height, 1) + margin)
        return visiblePositionRange(ensureLayout(), y: expandedY)
    }

    private func spellCovered(_ want: ClosedRange<Int>) -> Bool {
        spellCheckedVersion == docVersion
            && (spellCheckedRange.map { $0.lowerBound <= want.lowerBound && $0.upperBound >= want.upperBound } ?? false)
    }

    func currentSpellDecorations() -> [Decoration] {
        guard spellCheckingEnabled else { return [] }
        // Debounce: while scrolling/typing keeps changing the visible region or
        // the document, defer the (relatively expensive) UITextChecker pass until
        // things settle, rather than running it on every frame/keystroke.
        if let want = spellTargetRange(), !spellCovered(want) {
            spellWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.runSpellPassIfNeeded() }
            spellWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
        }
        // The cache may be a revision behind, but `mapSpellCache(through:)`
        // keeps its positions in step with every edit, so drawing it avoids
        // the blink-out/blink-in flash while the debounced pass is pending.
        return spellCache
    }

    /// Keep the spelling cache in step with an edit, without a full re-check:
    /// shift the cached underlines through the transaction's mapping, then
    /// synchronously re-check ONLY the textblock(s) the edit touched and
    /// splice the result in. The cache stays valid for the new revision, so
    /// the debounced viewport pass isn't scheduled while typing — underlines
    /// outside the edited paragraph never change, and the edited paragraph
    /// updates immediately. The word being typed is hidden separately
    /// (`visibleSpellingRanges` skips the decoration under the caret).
    private func mapSpellCache(through tr: Transaction) {
        guard tr.docChanged else { return }
        if !spellCache.isEmpty {
            spellCache = DecorationSet(spellCache).map(tr.mapping).find()
        }
        if let range = spellCheckedRange {
            let lo = tr.mapping.map(range.lowerBound, 1)
            let hi = tr.mapping.map(range.upperBound, -1)
            spellCheckedRange = lo <= hi ? lo...hi : nil
        }
        guard spellCheckingEnabled else { return }

        // The edited range, in final-document coordinates.
        let maps = tr.mapping.maps
        var lo = Int.max, hi = Int.min
        for (i, m) in maps.enumerated() {
            m.forEach { _, _, fromB, toB in
                var f = fromB, t = toB
                for j in (i + 1)..<maps.count {
                    f = maps[j].map(f, -1)
                    t = maps[j].map(t, 1)
                }
                lo = min(lo, f)
                hi = max(hi, t)
            }
        }
        guard lo <= hi else { return }

        // Expand to whole textblocks (the checker works word-by-word; a partial
        // block could split a word at the boundary).
        let doc = editor.doc
        func textblockBounds(_ pos: Int) -> ClosedRange<Int>? {
            let resolved = doc.resolve(min(max(pos, 0), doc.content.size))
            guard resolved.parent.isTextblock else { return nil }
            return resolved.start() ... resolved.end()
        }
        let from = textblockBounds(lo)?.lowerBound ?? lo
        let to = max(textblockBounds(hi)?.upperBound ?? hi, from)
        // A huge edit (multi-page paste): leave it to the debounced viewport
        // pass rather than blocking the keystroke.
        guard to - from <= 10_000 else { return }

        let fresh = SpellCheck.decorations(for: doc, in: from...to)
        spellCache = spellCache.filter { $0.to < from || $0.from > to } + fresh
        spellCheckedVersion = docVersion
        if let range = spellCheckedRange {
            spellCheckedRange = min(range.lowerBound, from) ... max(range.upperBound, to)
        }
    }

    /// Run a spell pass for the region visible *now*, if still needed. Runs on
    /// the main actor (debounced + bounded, so it's quick).
    func runSpellPassIfNeeded() {
        guard spellCheckingEnabled, let want = spellTargetRange(), !spellCovered(want) else { return }
        spellCache = SpellCheck.decorations(for: editor.doc, in: want)
        spellCheckedVersion = docVersion
        spellCheckedRange = want
        setNeedsDisplay()
    }

    /// Whether the document is a single empty textblock.
    private var isDocumentEmpty: Bool {
        editor.doc.childCount == 1
            && editor.doc.firstChild?.isTextblock == true
            && editor.doc.firstChild?.content.size == 0
    }

    // MARK: - Caret

    /// Convert a gesture point (viewport coordinates) to document coordinates.
    func docPoint(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: point.y + contentOffsetY) }

    /// The caret rect for the current (empty) selection: the usual vertical
    /// bar, or a short horizontal bar for a gap cursor (there is no text
    /// position at a gap, so the caret marks where the paragraph would go).
    func selectionCaretRect(_ l: DocumentLayout) -> CGRect? {
        let sel = editor.state.selection
        guard sel.empty else { return nil }
        if sel is GapCursor { return gapCaretRect(at: sel.head, in: l) }
        return l.caretRect(at: sel.head)
    }

    /// A horizontal blink bar at the block boundary `pos` points at, centered
    /// in the visual gap between its neighbor blocks.
    func gapCaretRect(at pos: Int, in l: DocumentLayout) -> CGRect {
        let below = l.blocks.first(where: { $0.contentStart >= pos })
        let above = l.blocks.last(where: { $0.contentEnd <= pos })
        var x = theme.pageInsets.left
        var y = theme.pageInsets.top
        switch (above, below) {
        case let (above?, below?):
            x = below.frame.minX
            y = (above.frame.maxY + below.frame.minY) / 2 - 1
        case let (nil, below?):
            x = below.frame.minX
            y = max(0, below.frame.minY - 4)
        case let (above?, nil):
            x = above.frame.minX
            y = above.frame.maxY + 2
        case (nil, nil):
            break
        }
        return CGRect(x: x, y: y, width: 20, height: 2)
    }

    /// The document position of the top-level gap at `point` (doc coords), if
    /// the point sits between blocks and a gap cursor is valid there.
    func gapBoundaryPosition(at point: CGPoint) -> Int? {
        let l = ensureLayout()
        var above: TextBlock?
        var below: TextBlock?
        for b in l.blocks {
            if b.frame.minY <= point.y, point.y <= b.frame.maxY { return nil } // inside a block band
            if b.frame.maxY < point.y {
                if above == nil || b.frame.maxY > above!.frame.maxY { above = b }
            } else if b.frame.minY > point.y {
                if below == nil || b.frame.minY < below!.frame.minY { below = b }
            }
        }
        let pos: Int
        if let above {
            // After the top-level node containing the block above the point.
            pos = editor.doc.resolve(min(above.contentEnd, editor.doc.content.size)).after(1)
        } else if below != nil {
            pos = 0 // above the first block
        } else {
            return nil
        }
        guard pos >= 0, pos <= editor.doc.content.size else { return nil }
        return GapCursor.valid(editor.doc.resolve(pos)) ? pos : nil
    }

    /// Reposition the caret layer for the current scroll offset, without
    /// scrolling (used while the user scrolls).
    private func positionCaretLayer() {
        guard isFirstResponder, editor.state.selection.empty,
              let rect = selectionCaretRect(ensureLayout()) else {
            caretLayer.path = nil
            return
        }
        caretLayer.path = UIBezierPath(rect: rect.offsetBy(dx: 0, dy: -contentOffsetY)).cgPath
        caretLayer.fillColor = theme.caretColor.cgColor
    }

    /// Test hook: the caret's current on-screen rect (the caret layer's path).
    var caretViewRectForTesting: CGRect? { caretLayer.path?.boundingBoxOfPath }

    private func updateCaret() {
        let l = ensureLayout()
        realizeCaretRegionIfNeeded() // make an off-screen (estimated) caret target real
        let sel = editor.state.selection
        guard isFirstResponder, sel.empty, let rect = selectionCaretRect(l) else {
            caretLayer.path = nil
            if isFirstResponder, let rect = l.caretRect(at: editor.state.selection.head) {
                revealRect(rect) // keep the active end of a range visible too
            }
            return
        }
        // The caret layer lives in viewport coordinates; the rect is in document
        // coordinates, so shift by the scroll offset.
        caretLayer.path = UIBezierPath(rect: rect.offsetBy(dx: 0, dy: -contentOffsetY)).cgPath
        caretLayer.fillColor = theme.caretColor.cgColor
        caretLayer.opacity = 1
        revealRect(rect)
    }

    /// Scroll the nearest enclosing scroll view so the document-coordinate rect
    /// is visible. Works whether the view is the scroll content or a fixed
    /// viewport whose content height the host sets to `documentHeight`.
    private func revealRect(_ rect: CGRect) {
        guard let scrollView = enclosingScrollView else { return }
        let viewportHeight = scrollView.bounds.height
        guard viewportHeight > 0 else { return }
        let margin: CGFloat = 8
        var offset = scrollView.contentOffset.y
        if rect.minY - margin < offset {
            offset = rect.minY - margin
        } else if rect.maxY + margin > offset + viewportHeight {
            offset = rect.maxY + margin - viewportHeight
        }
        offset = max(0, min(offset, max(0, scrollView.contentSize.height - viewportHeight)))
        if abs(offset - scrollView.contentOffset.y) > 0.5 {
            scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: offset), animated: false)
        }
    }

    private var enclosingScrollView: UIScrollView? {
        var view = superview
        while let current = view {
            if let scroll = current as? UIScrollView { return scroll }
            view = current.superview
        }
        return nil
    }

    private func startBlink() {
        blinkTimer?.invalidate()
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.caretLayer.opacity = self.caretLayer.opacity > 0 ? 0 : 1 }
        }
    }

    private func stopBlink() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        caretLayer.opacity = 1
    }

    // MARK: - First responder

    open override var canBecomeFirstResponder: Bool { true }

    /// (Re)install the native text interaction for the current `isEditable` state:
    /// `.editable` gives a caret + keyboard; `.nonEditable` allows selection/copy
    /// without either. Called at init and whenever `isEditable` flips.
    private func installTextInteraction() {
        if let old = textInteraction { removeInteraction(old) }
        let interaction = UITextInteraction(for: isEditable ? .editable : .nonEditable)
        interaction.textInput = self
        addInteraction(interaction)
        textInteraction = interaction
    }

    /// Reports the current selection's on-screen rects (view coordinates) and
    /// whether it's empty, whenever the selection or its geometry changes — edits,
    /// selection drags, and scrolling. Enough to anchor a floating "bubble" menu
    /// over the selection; `rects` is empty when the selection is collapsed.
    public var onSelectionChange: ((_ rects: [CGRect], _ isEmpty: Bool) -> Void)?

    /// Called when the editor gains keyboard focus (becomes first responder).
    public var onFocus: (() -> Void)?
    /// Called when the editor loses keyboard focus (resigns first responder).
    public var onBlur: (() -> Void)?

    /// Contribute custom items to the text-selection edit menu (the callout shown
    /// over a selection). Return the extra elements to append after the system
    /// items (Copy/Paste/…); return `[]` to leave the menu unchanged. Each call
    /// reflects the current selection, so build actions against `editor` (e.g. a
    /// highlighter). See the demo's `HighlighterMenu` for an example.
    ///
    /// Installing a custom edit-menu interaction means the system's own callout
    /// (which contributes Writing Tools / Rewrite) is replaced by ours. So we only
    /// own the menu while a host actually sets this — leave it nil and the native
    /// menu (including Writing Tools) is untouched.
    public var editMenuItems: (@MainActor (_ editor: Editor) -> [UIMenuElement])? {
        didSet {
            let wantsCustomMenu = editMenuItems != nil
            if wantsCustomMenu, editMenuInteraction == nil {
                let interaction = UIEditMenuInteraction(delegate: self)
                addInteraction(interaction)
                editMenuInteraction = interaction
            } else if !wantsCustomMenu, let interaction = editMenuInteraction {
                removeInteraction(interaction)
                editMenuInteraction = nil
            }
        }
    }
    private var editMenuInteraction: UIEditMenuInteraction?

    /// When set, the host draws highlight-mark backgrounds itself instead of the
    /// built-in flat fill — e.g. a textured "drying ink" effect. Called during the
    /// draw pass with the graphics context (already in content coordinates, so
    /// draw runs at their given rects) and the visible runs. Each `HighlightRun`
    /// carries its document range (a stable identity across scrolling, for
    /// per-highlight animation) plus the on-screen rect and resolved color. Call
    /// `setNeedsDisplay()` to drive an animation. nil → default rendering.
    public var highlightRenderer: ((_ ctx: CGContext, _ runs: [HighlightRun]) -> Void)?

    /// Whether the editor currently has keyboard focus. Redefines UIView's
    /// focus-engine `isFocused` to mean "is first responder" — the meaningful
    /// notion of focus for a text editor.
    open override var isFocused: Bool { isFirstResponder }

    /// Give the editor keyboard focus (become first responder). Returns whether
    /// focus was taken.
    @discardableResult
    public func focus() -> Bool { becomeFirstResponder() }

    @discardableResult
    open override func becomeFirstResponder() -> Bool {
        let wasFirstResponder = isFirstResponder
        let became = super.becomeFirstResponder()
        if became { startBlink(); updateCaret() }
        if became, !wasFirstResponder { onFocus?() }
        return became
    }

    @discardableResult
    open override func resignFirstResponder() -> Bool {
        stopBlink()
        stopKeyRepeat()
        caretLayer.path = nil
        let wasFirstResponder = isFirstResponder
        let resigned = super.resignFirstResponder()
        if wasFirstResponder, !isFirstResponder { onBlur?() }
        return resigned
    }

    // MARK: - Gestures

    // MARK: - Suggestion popup

    /// Recompute which suggestion source is active and show/position or hide the
    /// popup. Called on every change and on scroll.
    private func updateSuggestionPopup() {
        for source in editor.suggestionSources {
            guard let context = source.context(editor) else { continue }
            let entries = source.entries(context.query, editor)
            if !entries.isEmpty {
                showSuggestion(entries, caretAt: context.to)
                return
            }
        }
        hideSuggestion()
    }

    // MARK: - Floating overlays (suggestion menu, link editor)

    /// The view that hosts floating overlays (the suggestion/slash menu and the
    /// link editor) so an enclosing scroll view can't clip them. The window when
    /// the view is in the hierarchy; otherwise self (still works, just clipped).
    public var overlayHost: UIView { window ?? self }

    /// Frame a floating `popup` of `size` relative to a viewport-space `anchor`
    /// (in this view's coordinates), hosting it in `overlayHost` so it isn't
    /// clipped. Prefers below the anchor, flips above when it would overflow the
    /// host's bottom edge, and clamps horizontally. Re-parents the popup as needed.
    func placeOverlay(_ popup: UIView, viewportAnchor anchor: CGRect, size: CGSize, gap: CGFloat = 4) {
        let host = overlayHost
        if popup.superview !== host {
            popup.removeFromSuperview()
            host.addSubview(popup)
        }
        let a = convert(anchor, to: host) // viewport rect → host (window) coords
        let b = host.bounds
        let x = min(max(a.minX, 4), max(4, b.width - size.width - 4))
        let below = a.maxY + gap
        let y = (below + size.height > b.maxY - 4 && a.minY - size.height - gap > b.minY + 4)
            ? a.minY - size.height - gap : below
        popup.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        host.bringSubviewToFront(popup)
    }

    private func showSuggestion(_ entries: [SuggestionEntry], caretAt pos: Int) {
        let popup = suggestionPopup ?? {
            let p = SuggestionPopupView(theme: theme)
            p.onSelect = { [weak self] _ in self?.acceptSuggestion() }
            suggestionPopup = p
            return p
        }()
        activeEntries = entries
        popup.setItems(entries.map { SuggestionPopupView.Item(title: $0.title, subtitle: $0.subtitle, icon: $0.icon) })
        // Anchor to the caret (viewport coords); the host keeps it un-clipped.
        let caret = (ensureLayout().caretRect(at: min(pos, editor.doc.content.size)) ?? .zero)
            .offsetBy(dx: 0, dy: -contentOffsetY)
        placeOverlay(popup, viewportAnchor: caret, size: popup.fittingSize())
    }

    private func hideSuggestion() {
        suggestionPopup?.removeFromSuperview()
        suggestionPopup = nil
        activeEntries = []
    }

    /// The titles currently shown in the suggestion popup (nil when hidden).
    /// For tests/inspection.
    var suggestionTitles: [String]? { suggestionPopup?.items.map(\.title) }

    /// Apply the highlighted suggestion (Enter / Tab / tap).
    private func acceptSuggestion() {
        guard let index = suggestionPopup?.selected, activeEntries.indices.contains(index) else { return }
        activeEntries[index].apply(editor)
        hideSuggestion()
    }

    // MARK: - Find / replace

    private var findBar: FindBarView?
    /// Whether the find bar is currently shown. (For tests/inspection.)
    var isFindBarVisible: Bool { findBar != nil }

    @objc private func handleFindCommand() { showFindBar() }
    @objc private func handleFindNextCommand() { editor.findNext(); refreshFindCount() }
    @objc private func handleFindPreviousCommand() { editor.findPrevious(); refreshFindCount() }

    /// Show the find/replace bar (⌘F), seeding it with the current selection.
    func showFindBar() {
        if findBar == nil {
            let bar = makeFindBar()
            addSubview(bar)
            NSLayoutConstraint.activate([
                bar.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 8),
                bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                bar.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            ])
            findBar = bar
        }
        guard let bar = findBar else { return }
        let sel = editor.state.selection
        if !sel.empty {
            let text = editor.doc.textBetween(sel.from, sel.to)
            if !text.isEmpty && !text.contains("\n") {
                bar.queryField.text = text
                editor.setSearch(text)
                refreshFindCount()
            }
        }
        bar.queryField.becomeFirstResponder()
    }

    func hideFindBar() {
        findBar?.removeFromSuperview()
        findBar = nil
        editor.clearSearch()
        becomeFirstResponder()
    }

    private func makeFindBar() -> FindBarView {
        let bar = FindBarView(theme: theme)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.onQueryChange = { [weak self] query in self?.editor.setSearch(query); self?.refreshFindCount() }
        bar.onNext = { [weak self] in self?.editor.findNext(); self?.refreshFindCount() }
        bar.onPrevious = { [weak self] in self?.editor.findPrevious(); self?.refreshFindCount() }
        bar.onReplace = { [weak self] in
            guard let self, let bar = self.findBar else { return }
            _ = self.editor.replaceCurrentMatch(with: bar.replaceField.text ?? "")
            self.refreshFindCount()
        }
        bar.onReplaceAll = { [weak self] in
            guard let self, let bar = self.findBar else { return }
            _ = self.editor.replaceAllMatches(with: bar.replaceField.text ?? "")
            self.refreshFindCount()
        }
        bar.onClose = { [weak self] in self?.hideFindBar() }
        return bar
    }

    private func refreshFindCount() {
        findBar?.setCount(current: editor.currentSearchMatchIndex, total: editor.searchMatches.count)
    }

    // MARK: - Task-item checkbox views

    /// Position the recycled checkbox views over the visible task items, syncing
    /// their checked state and toggle action. Called on layout, scroll, and
    /// document change; the shared `CheckboxOverlay` does the pooling.
    func syncCheckboxViews() {
        checkboxOverlay.theme = theme
        checkboxOverlay.sync(ensureLayout().checkboxes, offsetY: contentOffsetY,
                             viewportHeight: bounds.height, attached: window != nil)
    }

    /// Flip a task item's `checked` attribute (the checkbox view's toggle
    /// action). The new state flows back to the view via `syncCheckboxViews`.
    /// Test hook: drive a checkbox toggle by document position.
    func toggleCheckboxForTesting(at pos: Int) { toggleCheckbox(at: pos) }

    private func toggleCheckbox(at pos: Int) {
        guard isEditable else { return }
        if !isFirstResponder { becomeFirstResponder() }
        let checked = editor.doc.nodeAt(pos)?.attrs["checked"]?.boolValue ?? false
        if let tr = try? editor.state.tr.setNodeAttribute(pos, "checked", .bool(!checked)) {
            editor.dispatch(tr)
        }
    }

    /// Open a link the pointer activated. Gated to begin only on a Cmd-held
    /// click over a link (so ordinary taps still place the caret natively).
    @objc private func handleLinkTap(_ gesture: UITapGestureRecognizer) {
        let point = docPoint(gesture.location(in: self))
        guard let pos = ensureLayout().position(at: point) else { return }
        activateLink(at: pos)
    }

    /// Open the link at `docPos`, via `onOpenLink` if set, else the system.
    func activateLink(at docPos: Int) {
        guard let link = linkInfo(at: docPos), let url = URL(string: link.href) else { return }
        if let onOpenLink {
            onOpenLink(url)
        } else if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        }
    }

    /// Test hook: drive link activation by document position.
    func activateLinkForTesting(at docPos: Int) { activateLink(at: docPos) }

    /// Triple-tap → select the whole paragraph (the text block under the point).
    @objc private func handleTripleTap(_ gesture: UITapGestureRecognizer) {
        if !isFirstResponder { becomeFirstResponder() }
        let point = docPoint(gesture.location(in: self))
        guard let range = paragraphRange(at: point) else { return }
        setTextSelection(anchor: range.from, head: range.to)
    }

    /// The content range of the text block containing a document-space point.
    func paragraphRange(at point: CGPoint) -> (from: Int, to: Int)? {
        let l = ensureLayout()
        guard let pos = l.position(at: point), let block = l.blockContaining(pos) else { return nil }
        return (block.contentStart, block.contentEnd)
    }

    // MARK: - Link editing (Mod-K / menu)

    private var linkPopup: LinkPopupView?

    /// The range a link command should target and its current href: the
    /// selection (if any) or, for a collapsed caret inside a link, that link's
    /// full range. Nil when there's nothing to link.
    func currentLinkTarget() -> (from: Int, to: Int, href: String?)? {
        let sel = editor.state.selection
        if !sel.empty { return (sel.from, sel.to, linkInfo(at: sel.from)?.href) }
        if let link = linkInfo(at: sel.head) { return (link.from, link.to, link.href) }
        return nil
    }

    /// Whether a link can be added/edited at the current selection.
    var canEditLink: Bool { currentLinkTarget() != nil }

    /// Show the link popover for the current selection (or the link under the
    /// caret). No-op when there's nothing to link.
    func openLinkEditor() {
        guard editor.schema.marks["link"] != nil, let target = currentLinkTarget() else { return }
        linkPopup?.removeFromSuperview()
        let popup = LinkPopupView(theme: theme, initialURL: target.href, showRemove: target.href != nil)
        popup.onSubmit = { [weak self] url in self?.applyLink(url, from: target.from, to: target.to) }
        popup.onCancel = { [weak self] in self?.dismissLinkEditor() }
        linkPopup = popup
        let caret = (ensureLayout().caretRect(at: min(target.from, editor.doc.content.size)) ?? .zero)
            .offsetBy(dx: 0, dy: -contentOffsetY)
        let size = popup.systemLayoutSizeFitting(CGSize(width: 320, height: 0),
                                                 withHorizontalFittingPriority: .required,
                                                 verticalFittingPriority: .fittingSizeLevel)
        // Host in the window so the scroll view can't clip the popover.
        placeOverlay(popup, viewportAnchor: caret, size: size, gap: 6)
        popup.focus()
    }

    private func applyLink(_ url: String, from: Int, to: Int) {
        defer { dismissLinkEditor() }
        guard let linkType = editor.schema.marks["link"], to > from else { return }
        // Re-select the captured range (the popover's field stole the selection),
        // then add or remove the link.
        let state = editor.state
        let sel = TextSelection.create(state.doc, from, min(to, state.doc.content.size))
        let withSel = state.tr.setSelection(sel)
        editor.dispatch(withSel)
        if url.isEmpty {
            _ = editor.run(unsetLink(linkType))
        } else {
            _ = editor.run(setLink(linkType, href: url))
        }
    }

    private func dismissLinkEditor() {
        linkPopup?.removeFromSuperview()
        linkPopup = nil
        becomeFirstResponder()
    }

    /// Test hook: apply (or, with an empty URL, remove) a link over a range.
    func applyLinkForTesting(_ url: String, from: Int, to: Int) { applyLink(url, from: from, to: to) }
    /// Test hook: whether the link popover is showing.
    var isLinkEditorVisible: Bool { linkPopup != nil }

    /// Whether `gesture` is a Cmd-held click (the macOS/iPad open-link chord).
    private func isCommandClick(_ gesture: UIGestureRecognizer) -> Bool {
        gesture.modifierFlags.contains(.command)
    }

    // MARK: - Block reordering (drag handles)

    /// The drag-handle rect for top-level block `index`, in DOCUMENT coords.
    func blockHandleRect(forEntryAt index: Int) -> CGRect? {
        let entries = ensureLayout().entries
        guard entries.indices.contains(index) else { return nil }
        let e = entries[index]
        let height: CGFloat = 18
        let y = e.topY + max(0, (min(e.height, 44) - height) / 2)
        return CGRect(x: 1, y: y, width: 13, height: height)
    }

    /// The top-level entry whose handle contains `viewPoint` (view coords), when
    /// reordering is on.
    func blockHandleHit(at viewPoint: CGPoint) -> Int? {
        guard blockReorderingEnabled, isEditable else { return nil }
        let docP = docPoint(viewPoint)
        for i in ensureLayout().entries.indices
        where blockHandleRect(forEntryAt: i)?.insetBy(dx: -6, dy: -4).contains(docP) == true {
            return i
        }
        return nil
    }

    /// The drop-gap index (0...count) nearest a view-space y.
    func blockDropIndex(atViewY y: CGFloat) -> Int {
        let entries = ensureLayout().entries
        let docY = y + contentOffsetY
        for (i, e) in entries.enumerated() where docY < e.topY + e.height / 2 { return i }
        return entries.count
    }

    /// Note the pointer's position (desktop) so the hovered block reveals its
    /// handle. Called from the pointer interaction as the cursor moves.
    func updateBlockHover(at viewPoint: CGPoint) {
        guard blockReorderingEnabled else { return }
        usesPointer = true
        let docY = viewPoint.y + contentOffsetY
        let idx = ensureLayout().entries.firstIndex { docY >= $0.topY && docY < $0.topY + $0.height }
        if idx != hoveredBlockIndex { hoveredBlockIndex = idx; setNeedsDisplay() }
    }

    /// Whether block `index`'s handle should be visible right now.
    private func blockHandleVisible(_ index: Int) -> Bool {
        !usesPointer || hoveredBlockIndex == index || blockDrag?.sourceIndex == index
    }

    /// Test hook: whether block `index`'s handle is currently drawn.
    func blockHandleVisibleForTesting(_ index: Int) -> Bool { blockHandleVisible(index) }

    @objc private func handleBlockDrag(_ gesture: UIPanGestureRecognizer) {
        let p = gesture.location(in: self)
        switch gesture.state {
        case .began:
            guard let src = blockHandleHit(at: p) else { return }
            blockDrag = (src, src)
            setNeedsDisplay()
        case .changed:
            guard blockDrag != nil else { return }
            blockDrag?.dropIndex = blockDropIndex(atViewY: p.y)
            setNeedsDisplay()
        case .ended:
            if let d = blockDrag { moveTopBlock(from: d.sourceIndex, to: d.dropIndex) }
            blockDrag = nil
            setNeedsDisplay()
        default:
            blockDrag = nil
            setNeedsDisplay()
        }
    }

    /// Move top-level block `sourceIndex` to land at drop-gap `targetIndex`
    /// (0...childCount). Delegates to the pure `moveBlock` command in
    /// EditorCommands (no-op when the gap is adjacent to the source).
    func moveTopBlock(from sourceIndex: Int, to targetIndex: Int) {
        _ = editor.run(moveBlock(sourceIndex, targetIndex))
    }

    // MARK: - Image resize

    /// The resize handle's rect (document coords) for a block image drawn at
    /// `rect` — a small grip at its bottom-right corner.
    private func imageResizeHandleRect(for rect: CGRect) -> CGRect {
        let s: CGFloat = 14
        return CGRect(x: rect.maxX - s, y: rect.maxY - s, width: s, height: s)
    }

    /// The image position + drawn rect whose resize handle contains `viewPoint`.
    func imageResizeHit(at viewPoint: CGPoint) -> (pos: Int, rect: CGRect)? {
        guard imageResizingEnabled, isEditable else { return nil }
        let p = docPoint(viewPoint)
        for (pos, rect) in ensureLayout().imageRects
        where imageResizeHandleRect(for: rect).insetBy(dx: -8, dy: -8).contains(p) {
            return (pos, rect)
        }
        return nil
    }

    /// Note the pointer's position (desktop) so the hovered image reveals its
    /// resize handle. Called from the pointer interaction as the cursor moves.
    func updateImageHover(at viewPoint: CGPoint) {
        guard imageResizingEnabled else { return }
        usesPointer = true
        let p = docPoint(viewPoint)
        let pos = ensureLayout().imageRects.first { $0.rect.contains(p) }?.pos
        if pos != hoveredImagePos { hoveredImagePos = pos; setNeedsDisplay() }
    }

    /// Whether the resize handle for the image at `pos` should be visible now:
    /// on touch every image shows one; on desktop only the hovered (or actively
    /// resized) image does.
    private func imageHandleVisible(_ pos: Int) -> Bool {
        !usesPointer || hoveredImagePos == pos || imageResize?.pos == pos
    }

    /// Test hook: whether the image at `pos` currently draws its resize handle.
    func imageHandleVisibleForTesting(_ pos: Int) -> Bool { imageHandleVisible(pos) }

    // The resize pan, gated by the gesture delegate to begin only on an image's
    // resize handle. Each `.changed` commits the new width; the commits land
    // within one undo group (they fall inside the history grouping window), so a
    // single undo restores the pre-drag width.
    @objc private func handleImageResize(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            guard let hit = imageResizeHit(at: gesture.location(in: self)) else { return }
            imageResize = (hit.pos, hit.rect.minX)
        case .changed:
            guard let r = imageResize else { return }
            setImageWidth(r.pos, to: docPoint(gesture.location(in: self)).x - r.leftX)
        case .ended, .cancelled, .failed:
            imageResize = nil
        default:
            break
        }
    }

    /// Set the `width` attr of the image at `pos`, clamped to [40, content width].
    /// Internal so the resize gesture can be exercised in tests.
    func setImageWidth(_ pos: Int, to width: CGFloat) {
        let clamped = max(40, min(width, ensureLayout().contentWidth))
        guard let node = editor.doc.nodeAt(pos), node.type.name == "image" else { return }
        if let tr = try? editor.state.tr.setNodeAttribute(pos, "width", .int(Int(clamped.rounded()))) {
            editor.dispatch(tr)
        }
    }

    // The column-resize pan, gated by the gesture delegate to begin only on a
    // table column border. Caret placement and text selection are handled
    // natively by UITextInteraction.
    @objc private func handleMouseDrag(_ gesture: UIPanGestureRecognizer) {
        let point = docPoint(gesture.location(in: self))
        switch gesture.state {
        case .began: beginColumnResize(at: point)
        case .changed: updateColumnResize(to: point)
        case .ended, .cancelled, .failed: endColumnResize()
        default: break
        }
    }

    /// Our checkbox tap and column-resize pan begin only over their target, so
    /// ordinary taps/selection drags fall through to UITextInteraction. (Must be
    /// in the class body — it overrides `UIView`'s method.)
    open override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        let point = docPoint(gesture.location(in: self))
        if gesture === columnResizeRecognizer { return columnBorderHit(at: point) != nil }
        if gesture === blockDragRecognizer { return blockHandleHit(at: gesture.location(in: self)) != nil }
        if gesture === imageResizeRecognizer { return imageResizeHit(at: gesture.location(in: self)) != nil }
        if gesture === linkTapRecognizer {
            guard isCommandClick(gesture), let pos = ensureLayout().position(at: point) else { return false }
            return linkInfo(at: pos) != nil
        }
        return super.gestureRecognizerShouldBegin(gesture)
    }

    // Column-resize state, captured at the start of a border drag.
    private var resize: (tablePos: Int, leftColumn: Int, widths: [CGFloat], originX: CGFloat)?

    func beginColumnResize(at point: CGPoint) {
        guard let hit = columnBorderHit(at: point) else { resize = nil; return }
        resize = (hit.table.tablePos, hit.leftColumn, hit.table.widths, hit.table.originX)
        // Mirror the drag into the column-resizing plugin (handle first: setting
        // it resets dragging, so the metas go in separate transactions).
        if let cell = resizeHandleCell(tablePos: hit.table.tablePos, column: hit.leftColumn) {
            editor.dispatch(setResizeHandle(editor.state.tr, cell))
            editor.dispatch(setResizeDragging(editor.state.tr, ColumnDragging(
                startX: Double(point.x), startWidth: Double(hit.table.widths[hit.leftColumn]))))
        }
    }

    func updateColumnResize(to point: CGPoint) {
        if let r = resize { performColumnResize(r, to: point) }
    }

    func endColumnResize() {
        resize = nil
        // Clearing the handle also ends the drag in the plugin state.
        editor.dispatch(setResizeHandle(editor.state.tr, -1))
    }

    /// The first-row cell whose right edge is column `column`'s border.
    private func resizeHandleCell(tablePos: Int, column: Int) -> Int? {
        guard let table = editor.doc.nodeAt(tablePos) else { return nil }
        let map = TableMap.get(table)
        guard map.height > 0, column < map.width else { return nil }
        return tablePos + 1 + map.map[column]
    }

    /// The internal column border (and its table) within ~6pt of `point`, if any.
    // MARK: - Pointer (trackpad / mouse) cursor targets

    /// What the pointer is over, for cursor styling. Rects are in viewport
    /// coordinates (the pointer APIs work in view space, layout in doc space).
    enum PointerTarget: Equatable {
        case columnBorder(CGRect)
        case link(CGRect)
        case blockHandle(CGRect)
        case imageHandle(CGRect)
        case text
    }

    func pointerTarget(at viewPoint: CGPoint) -> PointerTarget {
        let point = docPoint(viewPoint)
        let l = ensureLayout()
        // A block drag handle (in the left gutter) takes priority.
        if let i = blockHandleHit(at: viewPoint), let r = blockHandleRect(forEntryAt: i) {
            return .blockHandle(r.offsetBy(dx: 0, dy: -contentOffsetY))
        }
        // An image resize handle (bottom-right corner).
        if let hit = imageResizeHit(at: viewPoint) {
            let r = imageResizeHandleRect(for: hit.rect)
            return .imageHandle(r.offsetBy(dx: 0, dy: -contentOffsetY))
        }
        // Checkboxes are their own subviews (with their own pointer hover).
        if let hit = columnBorderHit(at: point) {
            let x = hit.table.borderX(after: hit.leftColumn)
            let rect = CGRect(x: x - 6, y: hit.table.top - contentOffsetY,
                              width: 12, height: hit.table.bottom - hit.table.top)
            return .columnBorder(rect)
        }
        if let pos = l.position(at: point), let range = linkHoverRange(at: pos) {
            // Union the link's selection rects (it may wrap lines) into one
            // hover region; clamp to the line under the pointer if it spans.
            let rects = l.selectionRects(from: range.from, to: range.to)
                .filter { $0.minY - contentOffsetY <= viewPoint.y && viewPoint.y <= $0.maxY - contentOffsetY }
            if let rect = (rects.first ?? l.selectionRects(from: range.from, to: range.to).first) {
                return .link(rect.offsetBy(dx: 0, dy: -contentOffsetY))
            }
        }
        return .text
    }

    /// The link mark covering `docPos`: its full contiguous range and href, or
    /// nil if no link is there. The range spans adjacent inline children that
    /// share the same href within the textblock.
    func linkInfo(at docPos: Int) -> (from: Int, to: Int, href: String)? {
        guard let linkType = editor.schema.marks["link"] else { return nil }
        let size = editor.doc.content.size
        let pos = min(max(docPos, 0), size)
        let resolved = editor.doc.resolve(pos)
        let parent = resolved.parent
        guard parent.isTextblock else { return nil }
        let blockStart = resolved.start()

        // The href of each inline child, indexed by child, with its doc range.
        func href(_ child: Node) -> String? {
            child.marks.first(where: { $0.type === linkType })?.attrs["href"]?.stringValue
        }
        var ranges: [(from: Int, to: Int, href: String?)] = []
        var offset = 0
        for i in 0..<parent.childCount {
            let child = parent.child(i)
            ranges.append((blockStart + offset, blockStart + offset + child.nodeSize, href(child)))
            offset += child.nodeSize
        }
        // The child the position falls in (prefer the one ending at pos when
        // the caret sits on a boundary, matching mark inclusiveness).
        guard let idx = ranges.firstIndex(where: { pos >= $0.from && pos < $0.to })
            ?? ranges.firstIndex(where: { pos == $0.to }),
            let target = ranges[idx].href, !target.isEmpty else { return nil }

        var lo = idx, hi = idx
        while lo > 0, ranges[lo - 1].href == target { lo -= 1 }
        while hi + 1 < ranges.count, ranges[hi + 1].href == target { hi += 1 }
        return (ranges[lo].from, ranges[hi].to, target)
    }

    /// The document range of any link-like thing at `docPos` — a `link` mark run
    /// or a link-style inline atom (wikiLink / mention) — for pointer hovering.
    /// Atoms occupy a single position, so `position(at:)` can land on either side
    /// of one; check both the node starting at `docPos` and the one before it.
    func linkHoverRange(at docPos: Int) -> (from: Int, to: Int)? {
        if let link = linkInfo(at: docPos) { return (link.from, link.to) }
        let linkAtoms: Set<String> = ["wikiLink", "mention"]
        for p in [docPos, docPos - 1] where p >= 0 && p < editor.doc.content.size {
            if let node = editor.doc.nodeAt(p), node.isAtom, linkAtoms.contains(node.type.name) {
                return (p, p + node.nodeSize)
            }
        }
        return nil
    }

    func columnBorderHit(at point: CGPoint) -> (table: DocumentLayout.TableInfo, leftColumn: Int)? {
        guard isEditable else { return nil } // read-only: no column resizing
        let tolerance: CGFloat = 6
        for table in ensureLayout().tables where point.y >= table.top && point.y <= table.bottom {
            // Internal borders only (resizing the outer edges would change the
            // table's total width).
            for c in 0..<max(0, table.widths.count - 1) where abs(point.x - table.borderX(after: c)) <= tolerance {
                return (table, c)
            }
        }
        return nil
    }

    private func performColumnResize(_ r: (tablePos: Int, leftColumn: Int, widths: [CGFloat], originX: CGFloat), to point: CGPoint) {
        let minWidth: CGFloat = 24
        let left = r.leftColumn, right = r.leftColumn + 1
        guard right < r.widths.count else { return }
        let originalBorderX = r.originX + r.widths[0...left].reduce(0, +)
        let delta = point.x - originalBorderX
        let pairSum = r.widths[left] + r.widths[right]
        let newLeft = min(max(r.widths[left] + delta, minWidth), pairSum - minWidth)
        // Write both columns through the official plugin transaction (colwidth
        // as the array-of-ints the schema/serializer/TableMap expect). This
        // border drag keeps the pair's total width, unlike upstream's
        // one-column resize.
        guard let table = editor.doc.nodeAt(r.tablePos) else { return }
        let map = TableMap.get(table)
        guard map.height > 0, right < map.width else { return }
        let start = r.tablePos + 1
        let tr = editor.state.tr
        updateColumnWidth(tr, start + map.map[left], Int(newLeft.rounded()))
        updateColumnWidth(tr, start + map.map[right], Int((pairSum - newLeft).rounded()))
        editor.dispatch(tr)
    }


    /// Set a text selection between two document positions, snapping to valid
    /// text positions.
    private func setTextSelection(anchor: Int, head: Int) {
        let size = editor.doc.content.size
        let a = editor.doc.resolve(min(max(anchor, 0), size))
        let h = editor.doc.resolve(min(max(head, 0), size))
        editor.dispatch(editor.state.tr.setSelection(TextSelection.between(a, h)))
    }

    /// Fill colors for upstream decoration class names (the ported plugins
    /// don't carry explicit colors).
    private static func decorationClassColor(_ cls: String?) -> UIColor? {
        switch cls {
        case "ProseMirror-search-match": return UIColor(hex: "#FFE082")
        case "ProseMirror-active-search-match": return UIColor(hex: "#FFB300")
        case "column-resize-dragging": return UIColor.systemBlue.withAlphaComponent(0.10)
        case "insertion": return UIColor.systemGreen.withAlphaComponent(0.18)
        default: return nil
        }
    }

    /// A stable, distinct color per suggestion author (track changes). The
    /// hash is deterministic across processes — Swift's `String.hashValue` is
    /// per-process seeded, which would make a peer's color flicker between
    /// launches — so we FNV-1a the UTF-8 bytes ourselves.
    static func authorColor(_ author: String?) -> UIColor {
        let palette = [
            "#1E88E5", "#43A047", "#E53935", "#8E24AA",
            "#FB8C00", "#00897B", "#C0CA33", "#D81B60",
        ].map { UIColor(hex: $0)! }
        guard let author, !author.isEmpty else { return palette[0] }
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in author.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return palette[Int(hash % UInt64(palette.count))]
    }

    // MARK: - UIKeyInput

    public var hasText: Bool { editor.doc.content.size > 0 }

    public func insertText(_ text: String) {
        guard isEditable else { return }
        // This is a UIKit-initiated edit: suppress the input-delegate echo so a
        // mid-stream selectionDidChange doesn't desync fast typing.
        applyingTextInput = true
        defer { applyingTextInput = false }
        // Committing an IME composition: replace the marked range with the final text.
        if let m = markedRange {
            let from = min(m.0, editor.doc.content.size)
            let tr = editor.state.tr
            _ = try? tr.insertText(text, from, min(m.1, editor.doc.content.size))
            collapseCaret(tr, after: from, text: text)
            editor.dispatch(tr)
            markedRange = nil
            return
        }
        if text == "\n" {
            // Return arrives here (not via `handle`), so the suggestion popup
            // must be consulted on this path too: Enter chooses the item.
            if suggestionPopup != nil { acceptSuggestion(); return }
            runKey("Enter"); return
        }
        let sel = editor.state.selection
        // Try input rules (only at a collapsed cursor).
        if sel.empty, runTextInput(from: sel.from, to: sel.to, text: text) { return }
        // Replacing a *ranged* selection (e.g. a double-tapped word): the typed
        // text replaces it, then the caret must collapse to *after* the new text
        // so the next keystroke appends. (Mapping the old ranged selection through
        // the replace would otherwise leave the inserted text selected, so each
        // following character would replace it — "typing eats letters".)
        let from = sel.from
        let tr = editor.state.tr
        _ = try? tr.insertText(text)
        collapseCaret(tr, after: from, text: text)
        editor.dispatch(tr)
    }

    /// Place a collapsed caret just after text inserted at `from`.
    private func collapseCaret(_ tr: Transaction, after from: Int, text: String) {
        let pos = min(from + text.count, tr.doc.content.size)
        tr.setSelection(TextSelection.create(tr.doc, pos))
    }

    public func deleteBackward() {
        guard isEditable else { return }
        applyingTextInput = true
        defer { applyingTextInput = false }
        markedRange = nil // a delete ends any composition
        deleteInDirection(.backward, by: .character)
    }

    // MARK: - Clipboard (copy / cut / paste / select all)

    open override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(copy(_:)):
            return !editor.state.selection.empty
        case #selector(cut(_:)):
            return isEditable && !editor.state.selection.empty
        case #selector(paste(_:)):
            guard isEditable else { return false }
            let pb = UIPasteboard.general
            return pb.hasStrings || pb.contains(pasteboardTypes: [
                "public.html", "com.apple.flat-rtfd", "public.rtfd", "public.rtf",
                "com.apple.notes.richtext", // proto-only pasteboards still paste
            ])
        case #selector(pasteAndMatchStyle(_:)):
            // Match-style only reads the plain-text flavor; offering it for
            // rich-only pasteboards would be an enabled item that does nothing.
            return isEditable && UIPasteboard.general.hasStrings
        case #selector(selectAll(_:)):
            return editor.doc.content.size > 0
        case #selector(formatBold(_:)), #selector(formatItalic(_:)), #selector(formatUnderline(_:)),
             #selector(toggleHighlightAction(_:)), #selector(formatSubscript(_:)), #selector(formatSuperscript(_:)),
             #selector(formatTextColor(_:)), #selector(formatBackgroundColor(_:)):
            return isEditable && !editor.state.selection.empty
        case #selector(addOrEditLink(_:)):
            return isEditable && canEditLink
        default:
            return super.canPerformAction(action, withSender: sender)
        }
    }

    open override func copy(_ sender: Any?) { writeSelectionToPasteboard() }

    // Formatting actions, dispatched from the app's toolbar / Format menu.
    // NOTE: these are deliberately NOT the system selectors `toggleBoldface:`/
    // `toggleItalics:`/`toggleUnderline:` — implementing those makes Catalyst
    // auto-inject the Font/Color menu (which this editor can't honor). Using
    // custom names keeps formatting under our control, in the toolbar.
    @objc func formatBold(_ sender: Any?) { _ = editor.run("toggleBold") }
    @objc func formatItalic(_ sender: Any?) { _ = editor.run("toggleItalic") }
    @objc func formatUnderline(_ sender: Any?) { _ = editor.run("toggleUnderline") }

    /// Edit-menu / Cmd-K entry point for linking the selection.
    @objc func addOrEditLink(_ sender: Any?) { openLinkEditor() }

    /// Highlight the selection (right-click / Format menu / Mod-Shift-H).
    @objc func toggleHighlightAction(_ sender: Any?) { _ = editor.run("toggleHighlight") }

    @objc func formatSubscript(_ sender: Any?) { _ = editor.run("toggleSubscript") }
    @objc func formatSuperscript(_ sender: Any?) { _ = editor.run("toggleSuperscript") }

    /// Pick a foreground color for the selection (presents a system color picker).
    @objc func formatTextColor(_ sender: Any?) { presentColorPicker(background: false) }
    /// Pick a background color for the selection.
    @objc func formatBackgroundColor(_ sender: Any?) { presentColorPicker(background: true) }

    private func presentColorPicker(background: Bool) {
        guard !editor.state.selection.empty, let vc = nearestViewController() else { return }
        colorPickerTargetsBackground = background
        let picker = UIColorPickerViewController()
        picker.delegate = self
        picker.title = background ? "Background Color" : "Text Color"
        vc.present(picker, animated: true)
    }

    private func nearestViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let r = responder {
            if let vc = r as? UIViewController { return vc }
            responder = r.next
        }
        return window?.rootViewController
    }

    /// A UIColor as a `#rrggbb` CSS string (what the color marks store, so it
    /// round-trips through HTML/serialization).
    static func cssHex(_ color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ v: CGFloat) -> Int { Int((max(0, min(1, v)) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(r), byte(g), byte(b))
    }

    /// The supported formatting actions, for a host to build its menu from.
    /// Each routes through the responder chain to the focused editor.
    public static let formatMenuActions: [(title: String, action: Selector)] = [
        ("Bold", #selector(formatBold(_:))),
        ("Italic", #selector(formatItalic(_:))),
        ("Underline", #selector(formatUnderline(_:))),
        ("Highlight", #selector(toggleHighlightAction(_:))),
        ("Subscript", #selector(formatSubscript(_:))),
        ("Superscript", #selector(formatSuperscript(_:))),
        ("Text Color…", #selector(formatTextColor(_:))),
        ("Background Color…", #selector(formatBackgroundColor(_:))),
        ("Add Link…", #selector(addOrEditLink(_:))),
    ]

    open override func cut(_ sender: Any?) {
        guard isEditable else { return }
        writeSelectionToPasteboard()
        deleteCurrentSelection()
    }

    open override func paste(_ sender: Any?) {
        guard isEditable else { return }
        let pb = UIPasteboard.general
        // Pasting a bare URL over selected text links the selection instead of
        // replacing it (the common "select text, paste link" gesture).
        if pasteURLOverSelection(pb) { return }
        if let data = pb.data(forPasteboardType: "public.html"),
           let html = String(data: data, encoding: .utf8),
           let doc = try? HTMLParser.parse(html, schema: editor.schema) {
            // Sources can flatten checklists in their HTML while carrying the
            // state in the Notes proto — recover here too, not just on the RTF path.
            insertContent(recoverChecklists(in: doc, from: pb, attributedString: nil).content)
        } else if let doc = richTextPasteDoc(pb) {
            // Rich text without public.html (e.g. Apple Notes / Pages, which are
            // RTF-first) — bridge via NSAttributedString → HTML so tables, lists,
            // and checklists survive.
            insertContent(doc.content)
        } else if let string = pb.string {
            // Treat clearly-Markdown text as Markdown; otherwise plain.
            if looksLikeMarkdown(string), let doc = try? MarkdownParser.parse(string, schema: editor.schema) {
                insertContent(doc.content)
            } else {
                pastePlainText(string)
            }
        }
    }

    /// If the pasteboard is a single URL and there's a non-empty selection,
    /// link the selection rather than replacing it. Returns whether it handled
    /// the paste.
    func pasteURLOverSelection(_ pb: UIPasteboard) -> Bool {
        let sel = editor.state.selection
        guard !sel.empty, let linkType = editor.schema.marks["link"] else { return false }
        // Only when the pasteboard is purely a URL (a copied link), not rich
        // content that happens to contain one.
        guard !pb.contains(pasteboardTypes: ["public.html", "public.rtf", "public.rtfd",
                                             "com.apple.flat-rtfd", "com.apple.notes.richtext"]),
              let raw = pb.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              isSingleURL(raw) else { return false }
        let href = (raw.contains("://") || raw.hasPrefix("mailto:")) ? raw : "https://" + raw
        _ = editor.run(setLink(linkType, href: href))
        return true
    }

    /// Whether `string` is a single URL token (one word, with a scheme or a
    /// www./domain-like shape).
    private func isSingleURL(_ string: String) -> Bool {
        guard !string.isEmpty, !string.contains(where: { $0.isWhitespace || $0.isNewline }) else { return false }
        if string.hasPrefix("http://") || string.hasPrefix("https://") || string.hasPrefix("mailto:") { return true }
        // Bare domain like "example.com/x": a dot, no scheme, looks host-ish.
        return string.hasPrefix("www.") || (string.contains(".") && !string.contains("://"))
            && string.range(of: "^[A-Za-z0-9.-]+\\.[A-Za-z]{2,}(/.*)?$", options: .regularExpression) != nil
    }

    /// Build a document from the pasteboard's rich-text flavors. Best case:
    /// Apple Notes' private proto converted directly (headings, lists, marks,
    /// and checklist state all survive) — used when its text matches the pasted
    /// attributed string, so a whole-note proto never replaces a selection
    /// paste. Otherwise: RTF/RTFD → HTML via NSAttributedString, parsed, with
    /// checklist state recovered. Returns nil if no flavor converts.
    func richTextPasteDoc(_ pb: UIPasteboard) -> Node? {
        let proto = pb.data(forPasteboardType: "com.apple.notes.richtext")
        // The archived-attributed-string flavor first: it skips the RTF
        // round-trip's losses entirely when a UIKit-sourced copy provides it.
        func documentType(_ docType: NSAttributedString.DocumentType) -> (Data) -> NSAttributedString? {
            { try? NSAttributedString(data: $0, options: [.documentType: docType], documentAttributes: nil) }
        }
        let candidates: [(String, (Data) -> NSAttributedString?)] = [
            ("com.apple.uikit.attributedstring", { data in
                try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: data)
            }),
            ("com.apple.flat-rtfd", documentType(.rtfd)),
            ("public.rtfd", documentType(.rtfd)),
            ("public.rtf", documentType(.rtf)),
        ]
        var sawRichData = false
        for (type, decode) in candidates {
            guard let data = pb.data(forPasteboardType: type) else { continue }
            sawRichData = true
            guard let attr = decode(data) else { continue }
            if let proto,
               let doc = AppleNotesPasteboard.document(fromArchive: proto, schema: editor.schema,
                                                       matchingText: attr.string) {
                return doc
            }
            guard let htmlData = try? attr.data(from: NSRange(location: 0, length: attr.length),
                                                documentAttributes: [.documentType: NSAttributedString.DocumentType.html]),
                  let html = String(data: htmlData, encoding: .utf8),
                  let doc = try? HTMLParser.parse(html, schema: editor.schema)
            else { continue }
            return recoverChecklists(in: doc, from: pb, attributedString: attr)
        }
        // A proto with no convertible RTF flavor still describes the content —
        // but "RTF present yet undecodable" must not paste the whole note over a
        // selection copy, so keep the text-match guard whenever any text exists
        // to match against (a truly proto-only pasteboard has neither).
        if let proto, pb.string != nil || !sawRichData,
           let doc = AppleNotesPasteboard.document(fromArchive: proto, schema: editor.schema,
                                                   matchingText: pb.string) {
            return doc
        }
        return nil
    }

    /// Restore checklists the HTML round-trip flattened to bullet lists, using
    /// Apple Notes' private proto (every line + checked state, in note order) when
    /// present AND describing exactly the pasted content — a whole-note proto
    /// must not drive recovery for a selection copy (its lines would feed the
    /// positional queues with non-pasted state). Else the RTF `{check}` markers
    /// (checked items only).
    private func recoverChecklists(in doc: Node, from pb: UIPasteboard, attributedString attr: NSAttributedString?) -> Node {
        let lines = pb.data(forPasteboardType: "com.apple.notes.richtext")
            .flatMap { AppleNotesPasteboard.checklist(fromArchive: $0, matchingText: attr?.string ?? pb.string) } ?? []
        let checked = attr.map(checkedLines(from:)) ?? []
        guard !lines.isEmpty || !checked.isEmpty else { return doc }
        let content = applyChecklistMarkers(doc.content, checkedTexts: checked,
                                            checklistLines: lines, schema: editor.schema)
        return doc.copy(content: content)
    }

    /// The trimmed text of every paragraph whose list marker is a checkbox check
    /// (`{check}`) — i.e. checked checklist items in the attributed string.
    private func checkedLines(from attr: NSAttributedString) -> Set<String> {
        var result = Set<String>()
        let ns = attr.string as NSString
        attr.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: attr.length), options: []) { val, range, _ in
            guard let ps = val as? NSParagraphStyle,
                  ps.textLists.contains(where: { $0.markerFormat.rawValue.contains("check") }) else { return }
            // NB: literal RTF list markers ("☑\tmilk") are NOT stripped here —
            // applyChecklistMarkers' normalizedLine strips them on BOTH sides of
            // the comparison, so stripping one side here would re-break matching.
            for line in ns.substring(with: range).components(separatedBy: "\n") {
                let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { result.insert(t) }
            }
        }
        return result
    }

    /// Paste the pasteboard's text as plain text, discarding any rich formatting.
    open override func pasteAndMatchStyle(_ sender: Any?) {
        guard isEditable else { return }
        if let string = UIPasteboard.general.string { pastePlainText(string) }
    }

    private func looksLikeMarkdown(_ s: String) -> Bool {
        let lines = s.components(separatedBy: "\n")
        return lines.contains { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("# ") || t.hasPrefix("## ") || t.hasPrefix("- ") || t.hasPrefix("> ")
                || t.hasPrefix("```") || t.contains("**")
        }
    }

    open override func selectAll(_ sender: Any?) {
        editor.dispatch(editor.state.tr.setSelection(AllSelection(editor.doc)))
    }

    private func writeSelectionToPasteboard() {
        let sel = editor.state.selection
        guard !sel.empty else { return }
        let fragment = sel.content().content
        let html = HTMLSerializer.serialize(fragment: fragment)
        let text = editor.doc.textBetween(sel.from, sel.to, blockSeparator: "\n")
        UIPasteboard.general.items = [[
            "public.html": html,
            "public.utf8-plain-text": text,
        ]]
    }

    private func insertContent(_ content: Fragment) {
        editor.dispatch(editor.state.tr.replaceSelection(Slice.maxOpen(content)))
    }

    private func pastePlainText(_ string: String) {
        let lines = string.components(separatedBy: "\n")
        if lines.count <= 1 {
            let tr = editor.state.tr
            _ = try? tr.insertText(string)
            editor.dispatch(tr)
            return
        }
        let paragraphs = lines.compactMap { line -> Node? in
            try? editor.schema.node("paragraph", [:], content: Fragment.from(line.isEmpty ? [] : [editor.schema.text(line)]))
        }
        insertContent(Fragment.from(paragraphs))
    }

    // MARK: - Key handling

    // Arrow keys (and Tab) are claimed via key commands with priority over
    // system behavior, because an enclosing UIScrollView's keyboard-scrolling
    // otherwise swallows Up/Down before `pressesBegan` ever sees them.
    open override var keyCommands: [UIKeyCommand]? {
        // All arrows are handled via pressesBegan (not key commands) so holding
        // one auto-repeats — key commands fire once, presses repeat. We keep
        // Up/Down responsive over the scroll view via `pressesBegan` consuming
        // the press (and not calling super).
        var commands: [UIKeyCommand] = []
        // Home/End (line edges) and Tab also need priority over scroll-view
        // keyboard handling. PageUp/PageDown are intentionally left to the
        // scroll view, which scrolls by a page.
        for input in [UIKeyCommand.inputHome, UIKeyCommand.inputEnd] {
            for mods in [UIKeyModifierFlags(), .shift] {
                let command = UIKeyCommand(input: input, modifierFlags: mods, action: #selector(handleNavigationCommand(_:)))
                command.wantsPriorityOverSystemBehavior = true
                commands.append(command)
            }
        }
        for mods in [UIKeyModifierFlags(), .shift] {
            let command = UIKeyCommand(input: "\t", modifierFlags: mods, action: #selector(handleNavigationCommand(_:)))
            command.wantsPriorityOverSystemBehavior = true
            commands.append(command)
        }
        // Find / replace.
        let find = UIKeyCommand(input: "f", modifierFlags: .command, action: #selector(handleFindCommand))
        find.wantsPriorityOverSystemBehavior = true
        find.discoverabilityTitle = "Find"
        commands.append(find)
        // Add / edit a link.
        let link = UIKeyCommand(input: "k", modifierFlags: .command, action: #selector(addOrEditLink(_:)))
        link.wantsPriorityOverSystemBehavior = true
        link.discoverabilityTitle = "Add Link"
        commands.append(link)
        commands.append(UIKeyCommand(input: "g", modifierFlags: .command, action: #selector(handleFindNextCommand)))
        commands.append(UIKeyCommand(input: "g", modifierFlags: [.command, .shift], action: #selector(handleFindPreviousCommand)))
        return commands
    }

    @objc private func handleNavigationCommand(_ command: UIKeyCommand) {
        let keyCode: UIKeyboardHIDUsage?
        switch command.input {
        case UIKeyCommand.inputUpArrow: keyCode = .keyboardUpArrow
        case UIKeyCommand.inputDownArrow: keyCode = .keyboardDownArrow
        case UIKeyCommand.inputLeftArrow: keyCode = .keyboardLeftArrow
        case UIKeyCommand.inputRightArrow: keyCode = .keyboardRightArrow
        case UIKeyCommand.inputHome: keyCode = .keyboardHome
        case UIKeyCommand.inputEnd: keyCode = .keyboardEnd
        case "\t": keyCode = .keyboardTab
        default: keyCode = nil
        }
        if let keyCode { _ = handle(KeyEvent(keyCode, modifiers: command.modifierFlags)) }
    }

    open override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handledAny = false
        for press in presses {
            guard let key = press.key else { continue }
            if handle(key: key) {
                handledAny = true
                // Auto-repeat held keys that move/delete (key commands don't
                // repeat; presses do) so holding ←/→/Delete behaves like Notes.
                if isAutoRepeatKey(key.keyCode) {
                    startKeyRepeat(KeyEvent(key.keyCode, modifiers: key.modifierFlags,
                                            characters: key.charactersIgnoringModifiers))
                }
            }
        }
        if !handledAny { super.pressesBegan(presses, with: event) }
    }

    open override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.key != nil { stopKeyRepeat(for: press.key!.keyCode) }
        super.pressesEnded(presses, with: event)
    }

    open override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        stopKeyRepeat()
        super.pressesCancelled(presses, with: event)
    }

    // MARK: - Key auto-repeat

    private var keyRepeatTimer: Timer?
    private var keyRepeatEvent: KeyEvent?

    private func isAutoRepeatKey(_ keyCode: UIKeyboardHIDUsage) -> Bool {
        // All arrows + Delete/Backspace repeat when held (they flow through
        // presses, not key commands).
        keyCode == .keyboardLeftArrow || keyCode == .keyboardRightArrow
            || keyCode == .keyboardUpArrow || keyCode == .keyboardDownArrow
            || keyCode == .keyboardDeleteOrBackspace || keyCode == .keyboardDeleteForward
    }

    private func startKeyRepeat(_ event: KeyEvent) {
        stopKeyRepeat()
        keyRepeatEvent = event
        // Initial delay, then a steady repeat — the usual key-repeat cadence.
        // (If the OS also repeats presses, each repeat resets this timer, so the
        // move still happens once per event and never double-fires.)
        // Timers scheduled on the main run loop fire on the main actor, so it's
        // safe to assume isolation to touch the main-actor state they drive.
        keyRepeatTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.keyRepeatTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let event = self.keyRepeatEvent else { return }
                        _ = self.handle(event)
                    }
                }
            }
        }
    }

    private func stopKeyRepeat(for keyCode: UIKeyboardHIDUsage? = nil) {
        if let keyCode, keyRepeatEvent?.keyCode != keyCode { return }
        keyRepeatTimer?.invalidate()
        keyRepeatTimer = nil
        keyRepeatEvent = nil
    }

    /// A key press, decoupled from `UIKey` so the key handler can be unit-tested
    /// (UIKey has no public initializer).
    struct KeyEvent {
        var keyCode: UIKeyboardHIDUsage
        var modifiers: UIKeyModifierFlags
        var characters: String
        init(_ keyCode: UIKeyboardHIDUsage, modifiers: UIKeyModifierFlags = [], characters: String = "") {
            self.keyCode = keyCode
            self.modifiers = modifiers
            self.characters = characters
        }
    }

    private func handle(key: UIKey) -> Bool {
        handle(KeyEvent(key.keyCode, modifiers: key.modifierFlags, characters: key.charactersIgnoringModifiers))
    }

    /// Handle a key event, returning whether it was consumed. The single entry
    /// point for hardware-key behavior, driven by `pressesBegan` in production
    /// and directly by tests.
    func handle(_ key: KeyEvent) -> Bool {
        // While a suggestion popup is open, the arrow/enter/escape keys drive it.
        if suggestionPopup != nil {
            switch key.keyCode {
            case .keyboardUpArrow: suggestionPopup?.moveSelection(by: -1); return true
            case .keyboardDownArrow: suggestionPopup?.moveSelection(by: 1); return true
            case .keyboardReturnOrEnter, .keyboardTab: acceptSuggestion(); return true
            case .keyboardEscape: hideSuggestion(); return true
            default: break
            }
        }
        let mods = key.modifiers
        let extend = mods.contains(.shift)
        // Cmd = to line/doc edge, Option = by word, otherwise by character.
        let granularity: TextGranularity = mods.contains(.command)
            ? .lineBoundary
            : (mods.contains(.alternate) ? .word : .character)
        switch key.keyCode {
        case .keyboardLeftArrow:
            moveHorizontal(.backward, by: granularity, extend: extend); return true
        case .keyboardRightArrow:
            moveHorizontal(.forward, by: granularity, extend: extend); return true
        case .keyboardUpArrow:
            if mods.contains(.command) { moveToDocumentEdge(.backward, extend: extend) }
            else { moveCaretVertically(up: true, extend: extend) }
            return true
        case .keyboardDownArrow:
            if mods.contains(.command) { moveToDocumentEdge(.forward, extend: extend) }
            else { moveCaretVertically(up: false, extend: extend) }
            return true
        case .keyboardHome:
            moveHorizontal(.backward, by: .lineBoundary, extend: extend); return true
        case .keyboardEnd:
            moveHorizontal(.forward, by: .lineBoundary, extend: extend); return true
        case .keyboardDeleteOrBackspace:
            guard isEditable else { return false }
            deleteInDirection(.backward, by: granularity); return true
        case .keyboardDeleteForward:
            guard isEditable else { return false }
            deleteInDirection(.forward, by: mods.contains(.alternate) ? .word : .character); return true
        case .keyboardReturnOrEnter:
            guard isEditable else { return false }
            // Respect modifiers (Shift-Enter = hard break, Mod-Enter = exit code).
            let enter = modifierPrefix(mods) + "Enter"
            if runKey(enter) { return true }
            return runKey("Enter")
        case .keyboardTab:
            guard isEditable else { return false }
            // The Tab key produces "\t"; map it to the named "Tab" binding.
            return runKey(mods.contains(.shift) ? "Shift-Tab" : "Tab")
        case .keyboardEscape:
            if isFindBarVisible { hideFindBar(); return true }
            // Escape has no characters, so map it to the named binding.
            return runKey("Escape")
        default:
            // Editor key-bindings (formatting, lists, …) mutate the document, so
            // they're inert when read-only. Copy/select-all/find don't route here.
            guard isEditable else { return false }
            let stroke = keyStroke(from: key)
            if stroke == "Mod-k" { openLinkEditor(); return true }
            if !stroke.isEmpty { return runKey(stroke) }
            return false
        }
    }

    private func modifierPrefix(_ mods: UIKeyModifierFlags) -> String {
        var parts: [String] = []
        if mods.contains(.command) { parts.append("Mod") }
        if mods.contains(.control) { parts.append("Ctrl") }
        if mods.contains(.alternate) { parts.append("Alt") }
        if mods.contains(.shift) { parts.append("Shift") }
        return parts.isEmpty ? "" : parts.joined(separator: "-") + "-"
    }

    /// Build a key-binding string ("Mod-Shift-b") from a key event.
    private func keyStroke(from key: KeyEvent) -> String {
        var parts: [String] = []
        let mods = key.modifiers
        if mods.contains(.command) { parts.append("Mod") }
        if mods.contains(.control) { parts.append("Ctrl") }
        if mods.contains(.alternate) { parts.append("Alt") }
        if mods.contains(.shift) { parts.append("Shift") }
        guard !key.characters.isEmpty else { return "" }
        parts.append(key.characters.lowercased())
        return parts.joined(separator: "-")
    }

    /// Delete in a direction by a granularity. A plain character delete first
    /// lets the keymap handle block-edge cases (join/lift/node deletion); only
    /// when that doesn't apply do we remove the adjacent character/word range.
    /// Delete the current (non-empty) selection — clearing cells for a cell
    /// selection, otherwise removing the selected content.
    private func deleteCurrentSelection() {
        if editor.state.selection is CellSelection {
            _ = deleteCellSelectionContent(editor.state, { [weak self] tr in self?.editor.dispatch(tr) }, nil)
        } else if !editor.state.selection.empty {
            editor.dispatch(editor.state.tr.deleteSelection())
        }
    }

    private func deleteInDirection(_ direction: TextDirection, by granularity: TextGranularity) {
        let sel = editor.state.selection
        if !sel.empty {
            deleteCurrentSelection()
            return
        }
        let keymapBinding = direction == .backward ? "Backspace" : "Delete"
        if granularity == .character, runKey(keymapBinding) { return }
        let head = sel.head
        let target = TextNavigation.position(in: editor.doc, from: head, moving: direction, by: granularity)
        if target == head {
            _ = runKey(keymapBinding) // at a block edge — let the keymap join/lift
            return
        }
        if let tr = try? editor.state.tr.delete(min(head, target), max(head, target)) {
            editor.dispatch(tr.scrollIntoView())
        }
    }

    @discardableResult
    private func runKey(_ binding: String) -> Bool {
        let normalized = normalizeKeyName(binding)
        for plugin in editor.state.plugins {
            if let handler = plugin.props?.handleKeyDown,
               handler(normalized, editor.state, { [weak self] tr in self?.editor.dispatch(tr) }) {
                return true
            }
        }
        return false
    }

    @discardableResult
    private func runTextInput(from: Int, to: Int, text: String) -> Bool {
        for plugin in editor.state.plugins {
            if let handler = plugin.props?.handleTextInput,
               handler(from, to, text, editor.state, { [weak self] tr in self?.editor.dispatch(tr) }) {
                return true
            }
        }
        return false
    }

    // MARK: - Caret movement

    private func moveHorizontal(_ direction: TextDirection, by granularity: TextGranularity, extend: Bool) {
        let sel = editor.state.selection
        // A non-extending character move with a range collapses to its edge.
        if !extend, !sel.empty, granularity == .character {
            let edge = min(max(direction == .backward ? sel.from : sel.to, 0), editor.doc.content.size)
            editor.dispatch(editor.state.tr.setSelection(Selection.near(editor.doc.resolve(edge), direction.sign)))
            return
        }
        let target: Int
        if granularity == .lineBoundary {
            // Home/End/⌘←→ go to the visual (wrapped) line edge, falling back to
            // the textblock edge when there's no laid-out line.
            target = ensureLayout().lineBoundary(from: sel.head, toEnd: direction == .forward)
                ?? TextNavigation.position(in: editor.doc, from: sel.head, moving: direction, by: .lineBoundary)
        } else {
            target = TextNavigation.position(in: editor.doc, from: sel.head, moving: direction, by: granularity)
        }
        applyMove(to: target, extend: extend, bias: direction.sign)
    }

    private func moveToDocumentEdge(_ direction: TextDirection, extend: Bool) {
        applyMove(to: direction == .backward ? 0 : editor.doc.content.size, extend: extend, bias: direction.sign)
    }

    private func applyMove(to target: Int, extend: Bool, bias: Int) {
        let clamped = max(0, min(editor.doc.content.size, target))
        if extend {
            setTextSelection(anchor: editor.state.selection.anchor, head: clamped)
        } else {
            editor.dispatch(editor.state.tr.setSelection(Selection.near(editor.doc.resolve(clamped), bias)))
        }
    }

    private var goalColumnX: CGFloat?
    private var goalColumnHead: Int?

    private func moveCaretVertically(up: Bool, extend: Bool = false) {
        let sel = editor.state.selection
        let l = ensureLayout()
        guard let caret = l.caretRect(at: sel.head) else { return }
        // Preserve the column across consecutive ↑/↓ presses. If the cursor
        // moved by any other means since our last vertical move, restart it.
        if goalColumnHead != sel.head { goalColumnX = caret.midX }
        let preferredX = goalColumnX ?? caret.midX
        guard let pos = l.verticalPosition(from: sel.head, up: up, preferredX: preferredX) else {
            // Already on the first/last visual line. Like AppKit/UIKit text views,
            // snap to the document edge in the travel direction — so Shift-Up on
            // the top line extends the selection to the start of the document
            // rather than doing nothing. Keep goalColumnX so a following ↑/↓
            // returns to the original column.
            applyMove(to: up ? 0 : editor.doc.content.size, extend: extend, bias: up ? -1 : 1)
            goalColumnHead = editor.state.selection.head
            return
        }
        let target = min(pos, editor.doc.content.size)
        if extend {
            setTextSelection(anchor: sel.anchor, head: target)
        } else {
            editor.dispatch(editor.state.tr.setSelection(Selection.near(editor.doc.resolve(target))))
        }
        goalColumnHead = editor.state.selection.head
    }

    // MARK: - Accessibility

    // Basic exposure for VoiceOver. (Full per-element text navigation / rotor
    // would come with a UITextInput conformance.)
    open override var isAccessibilityElement: Bool {
        get { true }
        set {}
    }
    open override var accessibilityLabel: String? {
        get { "Rich text editor" }
        set {}
    }
    open override var accessibilityValue: String? {
        get { editor.doc.textBetween(0, editor.doc.content.size, blockSeparator: "\n") }
        set {}
    }
    open override var accessibilityTraits: UIAccessibilityTraits {
        get { [.updatesFrequently] }
        set {}
    }

    deinit {
        imageTasks.values.forEach { $0.cancel() }
    }
}

// MARK: - Drag & drop

extension EditorTextView: UIDragInteractionDelegate, UIDropInteractionDelegate {
    public func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: any UIDragSession) -> [UIDragItem] {
        let start = docPoint(session.location(in: self))
        // A drag starting on an image's resize handle resizes it, not reorders it.
        if imageResizeHit(at: session.location(in: self)) != nil { return [] }
        // Grabbing an existing image starts a drag of that node (move within the
        // document; its bytes are offered to other apps).
        if let img = imageAt(start) { return [imageDragItem(for: img)] }
        // Otherwise, only drag when the gesture starts on the (non-empty) selection.
        let sel = editor.state.selection
        guard !sel.empty, let pos = ensureLayout().position(at: start),
              pos >= sel.from, pos <= sel.to else { return [] }
        let text = editor.doc.textBetween(sel.from, sel.to)
        guard !text.isEmpty else { return [] }
        dragSourceRange = (sel.from, sel.to)
        return [UIDragItem(itemProvider: NSItemProvider(object: text as NSString))]
    }

    public func dragInteraction(_ interaction: UIDragInteraction, session: any UIDragSession, didEndWith operation: UIDropOperation) {
        dragSourceRange = nil
        draggingImage = nil
    }

    /// The image node (and its document range) under a point, if one lands there.
    /// Handles both block images (their own row) and inline images (within text).
    func imageAt(_ point: CGPoint) -> (node: Node, from: Int, to: Int)? {
        // Block image: hit-test its drawn rect directly (it isn't in a text block).
        if let start = ensureLayout().blockImage(at: point), let node = editor.doc.nodeAt(start) {
            return (node, start, start + node.nodeSize)
        }
        // Inline image: resolve the nearest text position and look at its neighbors.
        guard let pos = ensureLayout().position(at: point) else { return nil }
        let p = min(max(pos, 0), editor.doc.content.size)
        let resolved = editor.doc.resolve(p)
        if let after = resolved.nodeAfter, after.type.name == "image" {
            return (after, p, p + after.nodeSize)
        }
        if let before = resolved.nodeBefore, before.type.name == "image" {
            return (before, p - before.nodeSize, p)
        }
        return nil
    }

    /// Build a drag item for an existing image: it records the source range for a
    /// local move and registers the rendered image's bytes for external drops.
    private func imageDragItem(for img: (node: Node, from: Int, to: Int)) -> UIDragItem {
        draggingImage = img
        dragSourceRange = nil
        let provider = NSItemProvider()
        if let image = resolveImage(img.node), let data = image.pngData() {
            provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
                completion(data, nil)
                return nil
            }
        }
        let item = UIDragItem(itemProvider: provider)
        item.localObject = img.node
        return item
    }

    public func dropInteraction(_ interaction: UIDropInteraction, canHandle session: any UIDropSession) -> Bool {
        guard isEditable else { return false } // read-only: no drops into the document
        return session.canLoadObjects(ofClass: NSString.self) || session.canLoadObjects(ofClass: UIImage.self)
            || imageItemProvider(in: session) != nil
            || (session.localDragSession != nil && draggingImage != nil)
    }

    public func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: any UIDropSession) -> UIDropProposal {
        updateDropCursor(at: session.location(in: self))
        // A drag we started → move; anything from outside → copy.
        return UIDropProposal(operation: session.localDragSession != nil ? .move : .copy)
    }

    public func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: any UIDropSession) {
        dropCursorLayer.path = nil
    }

    public func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: any UIDropSession) {
        dropCursorLayer.path = nil
    }

    /// The indicator rect (doc coordinates) for a drop at the given view point:
    /// a horizontal gap bar between blocks, or a text caret inside one.
    func dropCursorRect(at point: CGPoint) -> CGRect? {
        let dp = docPoint(point)
        let l = ensureLayout()
        if let gap = gapBoundaryPosition(at: dp) { return gapCaretRect(at: gap, in: l) }
        guard let pos = l.position(at: dp) else { return nil }
        return l.caretRect(at: pos)
    }

    private func updateDropCursor(at point: CGPoint) {
        guard let rect = dropCursorRect(at: point) else {
            dropCursorLayer.path = nil
            return
        }
        dropCursorLayer.path = UIBezierPath(rect: rect.offsetBy(dx: 0, dy: -contentOffsetY)).cgPath
    }

    public func dropInteraction(_ interaction: UIDropInteraction, performDrop session: any UIDropSession) {
        dropCursorLayer.path = nil
        let location = docPoint(session.location(in: self))
        // A drop in a gap between blocks targets the gap boundary.
        guard let dropPos = gapBoundaryPosition(at: location) ?? ensureLayout().position(at: location) else { return }
        // Capture the move source now (the drag session ends before async loads).
        let moveFrom = session.localDragSession != nil ? dragSourceRange : nil
        // Dragging one of our own images back into the document moves that exact
        // node (preserving its attrs), rather than re-inserting a copy of its bytes.
        if session.localDragSession != nil, let dragged = draggingImage {
            moveImage(dragged, to: dropPos)
            return
        }
        // An image (incl. one dragged out of Apple Notes, which exposes image
        // file data) takes priority over a text representation of the same drag.
        if let provider = imageItemProvider(in: session) {
            loadDroppedImage(from: provider, at: dropPos)
        } else if session.canLoadObjects(ofClass: NSString.self) {
            _ = session.loadObjects(ofClass: NSString.self) { [weak self] items in
                guard let self, let text = items.first as? String, !text.isEmpty else { return }
                Task { @MainActor in self.dropText(text, at: dropPos, movingFrom: moveFrom) }
            }
        } else if session.canLoadObjects(ofClass: UIImage.self) {
            // A provider that vends only a UIImage (no registered image-data UTI).
            _ = session.loadObjects(ofClass: UIImage.self) { [weak self] items in
                guard let self, let image = items.first as? UIImage, let data = image.pngData() else { return }
                Task { @MainActor in self.insertDroppedImage(data, typeIdentifier: UTType.png.identifier, suggestedName: nil, at: dropPos) }
            }
        }
    }

    /// The first dropped item that carries image bytes (a registered type that
    /// conforms to `public.image`).
    private func imageItemProvider(in session: any UIDropSession) -> NSItemProvider? {
        session.items.map(\.itemProvider).first { provider in
            provider.registeredTypeIdentifiers.contains { UTType($0)?.conforms(to: .image) == true }
        }
    }

    /// Load an image item's raw bytes (preserving format/UTI/name) and insert it.
    /// Internal so the Apple Notes / item-provider path can be tested directly.
    func loadDroppedImage(from provider: NSItemProvider, at dropPos: Int) {
        let uti = provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .image) == true }
            ?? UTType.image.identifier
        let name = provider.suggestedName
        provider.loadDataRepresentation(forTypeIdentifier: uti) { [weak self] data, _ in
            guard let self, let data else { return }
            Task { @MainActor in self.insertDroppedImage(data, typeIdentifier: uti, suggestedName: name, at: dropPos) }
        }
    }

    /// Insert dropped text at `dropPos`, or move it there from `moveFrom`. All
    /// positions are clamped against the live document at each step — the source
    /// range can include inline atoms (so its document span differs from the
    /// text's character count), and the document can shift between drop capture
    /// and this call (async load / a collaborator's edit).
    func dropText(_ text: String, at dropPos: Int, movingFrom moveFrom: (from: Int, to: Int)?) {
        let tr = editor.state.tr
        func clamp(_ p: Int) -> Int { min(max(p, 0), tr.doc.content.size) }
        if let raw = moveFrom {
            let a = clamp(min(raw.from, raw.to)), b = clamp(max(raw.from, raw.to))
            let drop = clamp(dropPos)
            if a >= b || (drop >= a && drop <= b) {
                if a >= b { _ = try? tr.insertText(text, drop) } // empty source → just insert
                // dropped inside the source range → no-op
            } else if drop > b {
                _ = try? tr.delete(a, b)
                _ = try? tr.insertText(text, clamp(drop - (b - a)))
            } else { // drop < a
                _ = try? tr.insertText(text, drop)
                let lo = clamp(a + text.count), hi = clamp(b + text.count)
                if lo < hi { _ = try? tr.delete(lo, hi) }
            }
        } else {
            _ = try? tr.insertText(text, clamp(dropPos))
        }
        if tr.docChanged { editor.dispatch(tr.scrollIntoView()) }
    }

    /// Insert a dropped image as an image node (a `data:` URL it can load/render).
    /// Insert a dropped/pasted image at `dropPos`. The host's `onImageDrop` (if
    /// set) chooses the `image` node's attributes — typically persisting the
    /// bytes and returning a `src`; otherwise the bytes are embedded as a `data:`
    /// URL. Internal so paste and tests can reuse it.
    func insertDroppedImage(_ data: Data, typeIdentifier: String?, suggestedName: String?, at dropPos: Int) {
        guard let type = editor.schema.nodes["image"] else { return }
        let dropped = DroppedImage(data: data, typeIdentifier: typeIdentifier, suggestedName: suggestedName)
        let attrs = onImageDrop?(dropped) ?? Self.dataURLAttrs(for: data, typeIdentifier: typeIdentifier)
        guard let node = try? type.create(attrs) else { return }
        let tr = editor.state.tr
        let at = min(max(dropPos, 0), tr.doc.content.size)
        // replaceRangeWith places a block image at a valid block boundary
        // (splitting the surrounding textblock); inline images insert in place.
        _ = try? tr.replaceRangeWith(at, at, node)
        if tr.docChanged { editor.dispatch(tr.scrollIntoView()) }
    }

    /// Move an existing image node to `dropPos` (delete it from its source range,
    /// then re-insert the same node at the mapped target). A drop inside its own
    /// range is a no-op. Internal so the drag-to-reorder path can be tested.
    func moveImage(_ dragged: (node: Node, from: Int, to: Int), to dropPos: Int) {
        let tr = editor.state.tr
        func clamp(_ p: Int) -> Int { min(max(p, 0), tr.doc.content.size) }
        let from = clamp(min(dragged.from, dragged.to)), to = clamp(max(dragged.from, dragged.to))
        let drop = clamp(dropPos)
        guard from < to, !(drop >= from && drop <= to) else { return } // dropped on itself
        guard (try? tr.delete(from, to)) != nil else { return }
        let target = min(max(tr.mapping.map(drop), 0), tr.doc.content.size)
        // Re-insert at a valid block boundary (block image) or in place (inline).
        guard (try? tr.replaceRangeWith(target, target, dragged.node)) != nil else { return }
        if tr.docChanged { editor.dispatch(tr.scrollIntoView()) }
    }

    /// Embed image bytes as a `data:` URL src (the fallback when no host handler).
    static func dataURLAttrs(for data: Data, typeIdentifier: String?) -> Attrs {
        let mime = typeIdentifier.flatMap { UTType($0)?.preferredMIMEType } ?? "image/png"
        return ["src": .string("data:\(mime);base64," + data.base64EncodedString())]
    }
}

extension EditorTextView: UIGestureRecognizerDelegate {
    /// Coexist with UITextInteraction's own recognizers.
    public func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

extension EditorTextView: UIEditMenuInteractionDelegate {
    // Append the host's custom items (e.g. a highlighter) after the system menu
    // items. Returning nil leaves the default menu untouched. The protocol method
    // is nonisolated in this SDK; UIKit invokes it on the main thread, so it's
    // safe to assume main-actor isolation to read our state.
    public nonisolated func editMenuInteraction(_ interaction: UIEditMenuInteraction,
                                                menuFor configuration: UIEditMenuConfiguration,
                                                suggestedActions: [UIMenuElement]) -> UIMenu? {
        MainActor.assumeIsolated {
            guard let custom = editMenuItems?(editor), !custom.isEmpty else { return nil }
            return UIMenu(children: suggestedActions + custom)
        }
    }
}

extension EditorTextView: UIColorPickerViewControllerDelegate {
    // Apply once, on dismiss, so a live drag through the picker doesn't flood the
    // undo history (the selection persists in the model while the picker is up).
    public func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
        let css = Self.cssHex(viewController.selectedColor)
        if colorPickerTargetsBackground { _ = editor.setBackgroundColor(css) }
        else { _ = editor.setTextColor(css) }
        becomeFirstResponder()
    }
}

extension EditorTextView: UIPointerInteractionDelegate {
    public func pointerInteraction(_ interaction: UIPointerInteraction,
                                   regionFor request: UIPointerRegionRequest,
                                   defaultRegion: UIPointerRegion) -> UIPointerRegion? {
        // Track the pointer so the hovered block / image reveals its handle.
        updateBlockHover(at: request.location)
        updateImageHover(at: request.location)
        switch pointerTarget(at: request.location) {
        case .columnBorder(let rect):
            return UIPointerRegion(rect: rect, identifier: "columnBorder")
        case .link(let rect):
            return UIPointerRegion(rect: rect, identifier: "link")
        case .blockHandle(let rect):
            return UIPointerRegion(rect: rect, identifier: "blockHandle")
        case .imageHandle(let rect):
            return UIPointerRegion(rect: rect, identifier: "imageHandle")
        case .text:
            return defaultRegion
        }
    }

    public func pointerInteraction(_ interaction: UIPointerInteraction,
                                   styleFor region: UIPointerRegion) -> UIPointerStyle? {
        switch region.identifier as? String {
        case "columnBorder":
            return UIPointerStyle(shape: .path(Self.columnResizeCursorPath()))
        case "link":
            // A rounded highlight over the link text — its "Cmd-click to open"
            // affordance (the I-beam still serves caret placement on a plain
            // click). The region rect is in view coordinates.
            return UIPointerStyle(shape: .roundedRect(region.rect.insetBy(dx: -2, dy: -1), radius: 4))
        case "blockHandle":
            // A highlight over the grip — its "drag to reorder" affordance.
            return UIPointerStyle(shape: .roundedRect(region.rect.insetBy(dx: -3, dy: -2), radius: 4))
        case "imageHandle":
            // A highlight over the corner grip — its "drag to resize" affordance.
            return UIPointerStyle(shape: .roundedRect(region.rect.insetBy(dx: -3, dy: -3), radius: 4))
        default:
            // Text: the standard I-beam.
            return UIPointerStyle(shape: .verticalBeam(length: theme.bodyFont.lineHeight + 4))
        }
    }

    /// A horizontal double-arrow (⟷), centered on the pointer — the resize
    /// affordance for dragging a column border.
    private static func columnResizeCursorPath() -> UIBezierPath {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: -11, y: 0))
        path.addLine(to: CGPoint(x: -5, y: -5))
        path.addLine(to: CGPoint(x: -5, y: -1.5))
        path.addLine(to: CGPoint(x: 5, y: -1.5))
        path.addLine(to: CGPoint(x: 5, y: -5))
        path.addLine(to: CGPoint(x: 11, y: 0))
        path.addLine(to: CGPoint(x: 5, y: 5))
        path.addLine(to: CGPoint(x: 5, y: 1.5))
        path.addLine(to: CGPoint(x: -5, y: 1.5))
        path.addLine(to: CGPoint(x: -5, y: 5))
        path.close()
        return path
    }
}

/// Resolve an image node to a loadable URL: the host resolver first (it sees the
/// whole node's attributes), then the node's `src` as data:/http(s)/file/
/// absolute-path. Shared by the editable `EditorTextView` and read-only
/// `DocumentView`.
func resolveImageURL(_ node: Node, resolver: ImageURLResolver?) -> URL? {
    if let resolved = resolver?(node) { return resolved }
    let src = node.attrs["src"]?.stringValue ?? ""
    if src.hasPrefix("data:"), let url = URL(string: src) { return url }
    if let url = URL(string: src), let scheme = url.scheme, ["http", "https", "file"].contains(scheme) { return url }
    if FileManager.default.fileExists(atPath: src) { return URL(fileURLWithPath: src) }
    return nil
}

/// Load an image from a data:, file:, or http(s) URL. Nonisolated so it can run
/// off the main actor.
func loadImage(from url: URL) async -> UIImage? {
    if url.scheme == "data" {
        let string = url.absoluteString
        guard let comma = string.firstIndex(of: ",") else { return nil }
        let meta = string[..<comma]
        let payload = String(string[string.index(after: comma)...])
        if meta.contains("base64"), let data = Data(base64Encoded: payload) { return UIImage(data: data) }
        return payload.removingPercentEncoding.flatMap { UIImage(data: Data($0.utf8)) }
    }
    if url.isFileURL {
        return (try? Data(contentsOf: url)).flatMap(UIImage.init(data:))
    }
    do {
        let (data, _) = try await URLSession.shared.data(from: url)
        return UIImage(data: data)
    } catch {
        return nil
    }
}
#endif

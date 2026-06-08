#if canImport(UIKit)
import UIKit
import DocumentModel
import DocumentTransform
import EditorStateKit
import EditorCommands
import EditorKeymap
import SchemaKit
import EditorSerialization

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
    private var blinkTimer: Timer?
    /// Native selection UI (loupe, handles, edit menu, tap-to-place caret).
    private var textInteraction: UITextInteraction?
    private weak var checkboxRecognizer: UIGestureRecognizer?
    private weak var columnResizeRecognizer: UIGestureRecognizer?
    /// The document range being dragged (set while a local drag we started is in
    /// flight), so a drop back into this document moves rather than copies.
    private var dragSourceRange: (from: Int, to: Int)?

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

        // Native text interaction: caret placement, the loupe/magnifier,
        // selection handles, and the edit menu — all driven by our UITextInput
        // conformance.
        let interaction = UITextInteraction(for: .editable)
        interaction.textInput = self
        addInteraction(interaction)
        textInteraction = interaction

        // Our own gestures handle only what UITextInteraction doesn't: toggling
        // task-list checkboxes and dragging table column borders. Each is gated
        // (via the gesture delegate) to begin only on its target, so ordinary
        // taps and selection drags fall through to UITextInteraction.
        let checkboxTap = UITapGestureRecognizer(target: self, action: #selector(handleCheckboxTap(_:)))
        let columnResize = UIPanGestureRecognizer(target: self, action: #selector(handleMouseDrag(_:)))
        checkboxRecognizer = checkboxTap
        columnResizeRecognizer = columnResize
        for recognizer in [checkboxTap, columnResize] as [UIGestureRecognizer] {
            recognizer.delegate = self
            recognizer.cancelsTouchesInView = false
            addGestureRecognizer(recognizer)
        }

        // Drag selected text/images out, and drop text/images in (move within the
        // document, or copy from another app).
        addInteraction(UIDragInteraction(delegate: self))
        addInteraction(UIDropInteraction(delegate: self))

        editor.onChange = { [weak self] _ in self?.setNeedsRebuild() }
        registerForDynamicTypeChanges()
    }

    /// The editor's document revision — bumped only when the document actually
    /// changes (not on selection moves), so caret moves / clicks / scrolling
    /// never invalidate the layout. O(1) cache key.
    private var docVersion: Int { editor.docRevision }
    private let blockCache = TextBlockLayoutCache()
    /// Vertical scroll offset; the host feeds the enclosing scroll view's offset
    /// so the view renders only the visible window (bounded layer + culling).
    public var contentOffsetY: CGFloat = 0 {
        // Scrolling only repositions the caret layer; it must NOT reveal the
        // caret (that would scroll back to the cursor and fight the user).
        didSet { if oldValue != contentOffsetY { realizeVisibleIfNeeded(); setNeedsDisplay(); positionCaretLayer(); updateSuggestionPopup(); notifySelectionGeometryChanged() } }
    }
    /// The full document height; the host uses it as the scroll content height.
    public var documentHeight: CGFloat { ensureLayout().height }
    /// Called when the document height changes (so the host can resize the
    /// scroll content).
    public var onDocumentHeightChange: ((CGFloat) -> Void)?
    private var lastReportedHeight: CGFloat = -1

    // MARK: - UITextInput state
    /// The system input delegate, notified when text/selection change outside
    /// of a UITextInput-initiated edit.
    weak var textInputDelegate: UITextInputDelegate?
    /// The marked (composing/IME) range in document positions, if any.
    var markedRange: (Int, Int)?
    var markedTextStyleStore: [NSAttributedString.Key: Any]?
    /// Set while applying a UITextInput-initiated edit, so our `onChange` hook
    /// doesn't echo the change back to the input delegate (which would confuse
    /// autocorrect / marked-text state).
    var applyingTextInput = false
    lazy var inputTokenizer: UITextInputTokenizer = UITextInputStringTokenizer(textInput: self)

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
    }

    /// Hook to supply the raw image bytes for an image node (e.g. from the host's
    /// asset store, keyed off any of the node's attributes). When it returns nil
    /// the renderer falls back to loading the node's `src` URL, and otherwise
    /// draws a placeholder.
    public var imageData: ((Node) -> Data?)?

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
                               blockCache: blockCache, previous: layout, realizeWindow: realizeWindow())
        layout = l
        lastLayoutWidth = bounds.width
        layoutVersion = docVersion
        loadPendingImages(l.pendingImageSources)
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

    /// The system draws the selection highlight + handles from our `UITextInput`
    /// geometry, which is in view coordinates. Our virtualized scrolling changes
    /// that geometry without moving the view, so the system would keep a stale
    /// selection — tell it to re-query when there's a selection to re-map.
    private func notifySelectionGeometryChanged() {
        guard !applyingTextInput, !editor.state.selection.empty else { return }
        textInputDelegate?.selectionWillChange(self)
        textInputDelegate?.selectionDidChange(self)
    }

    /// If the caret sits in a still-estimated (off-screen) block under lazy
    /// layout, realize the region around it so `caretRect`/`revealRect` can scroll
    /// to it (e.g. ⌘↓ to the end of a huge document, or a programmatic selection).
    private func realizeCaretRegionIfNeeded() {
        guard let layout, layout.hasEstimatedContent else { return }
        let head = editor.state.selection.head
        guard layout.isEstimated(pos: head),
              layout.realize(aroundPos: head, viewportHeight: bounds.height) else { return }
        loadPendingImages(layout.pendingImageSources)
        if layout.height != lastReportedHeight {
            lastReportedHeight = layout.height
            onDocumentHeightChange?(layout.height)
        }
        setNeedsDisplay()
    }

    /// Typeset any estimated blocks that have scrolled near the viewport.
    private func realizeVisibleIfNeeded() {
        guard let layout, layout.hasEstimatedContent, layout.realize(window: realizeWindow()) else { return }
        loadPendingImages(layout.pendingImageSources)
        if layout.height != lastReportedHeight {
            lastReportedHeight = layout.height
            onDocumentHeightChange?(layout.height)
        }
        setNeedsDisplay()
    }

    /// Asynchronously load any images the layout couldn't find in the cache,
    /// then rebuild so they draw at their intrinsic size.
    private func loadPendingImages(_ sources: [String]) {
        for src in sources where imageCache[src] == nil && imageTasks[src] == nil {
            guard let url = imageURL(for: src) else { continue }
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

    private func imageURL(for src: String) -> URL? {
        if src.hasPrefix("data:"), let url = URL(string: src) { return url }
        if let url = URL(string: src), let scheme = url.scheme, ["http", "https", "file"].contains(scheme) { return url }
        if FileManager.default.fileExists(atPath: src) { return URL(fileURLWithPath: src) }
        return nil
    }

    open override func layoutSubviews() {
        super.layoutSubviews()
        if lastLayoutWidth != bounds.width { setNeedsRebuild() }
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
        for deco in decorations where deco.kind == .inline {
            if let hex = deco.attributes["background"], let color = UIColor(hex: hex) {
                ctx.setFillColor(color.cgColor)
                for r in l.selectionRects(from: deco.from, to: deco.to) where onScreen(r) { ctx.fill(r) }
            }
        }
        // Selection highlight (every range — a cell selection has several).
        let sel = editor.state.selection
        if !sel.empty {
            ctx.setFillColor(theme.selectionColor.cgColor)
            for range in sel.ranges {
                for r in l.selectionRects(from: range.from.pos, to: range.to.pos) where onScreen(r) { ctx.fill(r) }
            }
        }
        l.draw(in: ctx, clipY: visibleY)

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

    private var spellCache: [Decoration] = []
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

    private func currentSpellDecorations() -> [Decoration] {
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
        // Only draw decorations computed for the CURRENT document revision — the
        // positions of a stale pass are wrong once an edit shifts the text.
        return spellCheckedVersion == docVersion ? spellCache : []
    }

    /// Run a spell pass for the region visible *now*, if still needed. Runs on
    /// the main actor (debounced + bounded, so it's quick).
    private func runSpellPassIfNeeded() {
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

    /// Reposition the caret layer for the current scroll offset, without
    /// scrolling (used while the user scrolls).
    private func positionCaretLayer() {
        guard isFirstResponder, editor.state.selection.empty,
              let rect = ensureLayout().caretRect(at: editor.state.selection.head) else {
            caretLayer.path = nil
            return
        }
        caretLayer.path = UIBezierPath(rect: rect.offsetBy(dx: 0, dy: -contentOffsetY)).cgPath
        caretLayer.fillColor = theme.caretColor.cgColor
    }

    private func updateCaret() {
        let l = ensureLayout()
        realizeCaretRegionIfNeeded() // make an off-screen (estimated) caret target real
        let sel = editor.state.selection
        guard isFirstResponder, sel.empty, let rect = l.caretRect(at: sel.head) else {
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

    @discardableResult
    open override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { startBlink(); updateCaret() }
        return became
    }

    @discardableResult
    open override func resignFirstResponder() -> Bool {
        stopBlink()
        caretLayer.path = nil
        return super.resignFirstResponder()
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

    private func showSuggestion(_ entries: [SuggestionEntry], caretAt pos: Int) {
        let popup = suggestionPopup ?? {
            let p = SuggestionPopupView(theme: theme)
            p.onSelect = { [weak self] _ in self?.acceptSuggestion() }
            addSubview(p)
            suggestionPopup = p
            return p
        }()
        activeEntries = entries
        popup.setItems(entries.map(\.title))
        // Position just below the caret, in view (viewport) coordinates.
        let caret = (ensureLayout().caretRect(at: min(pos, editor.doc.content.size)) ?? .zero)
            .offsetBy(dx: 0, dy: -contentOffsetY)
        let size = popup.systemLayoutSizeFitting(CGSize(width: 260, height: 0),
                                                 withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        let x = min(max(caret.minX, 4), max(4, bounds.width - size.width - 4))
        popup.frame = CGRect(x: x, y: caret.maxY + 4, width: size.width, height: size.height)
    }

    private func hideSuggestion() {
        suggestionPopup?.removeFromSuperview()
        suggestionPopup = nil
        activeEntries = []
    }

    /// The titles currently shown in the suggestion popup (nil when hidden).
    /// For tests/inspection.
    var suggestionTitles: [String]? { suggestionPopup?.items }

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
        findBar?.setCount(current: editor.searchState?.currentIndex ?? -1, total: editor.searchMatches.count)
    }

    /// Toggle a task-item checkbox. Gated by the gesture delegate to begin only
    /// when the tap lands on a checkbox (otherwise UITextInteraction places the
    /// caret).
    @objc private func handleCheckboxTap(_ gesture: UITapGestureRecognizer) {
        if !isFirstResponder { becomeFirstResponder() }
        let point = docPoint(gesture.location(in: self))
        guard let box = ensureLayout().checkbox(at: point) else { return }
        if let tr = try? editor.state.tr.setNodeAttribute(box.pos, "checked", .bool(!box.checked)) {
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
        if gesture === checkboxRecognizer { return ensureLayout().checkbox(at: point) != nil }
        if gesture === columnResizeRecognizer { return columnBorderHit(at: point) != nil }
        return super.gestureRecognizerShouldBegin(gesture)
    }

    // Column-resize state, captured at the start of a border drag.
    private var resize: (tablePos: Int, leftColumn: Int, widths: [CGFloat], originX: CGFloat)?

    func beginColumnResize(at point: CGPoint) {
        guard let hit = columnBorderHit(at: point) else { resize = nil; return }
        resize = (hit.table.tablePos, hit.leftColumn, hit.table.widths, hit.table.originX)
    }

    func updateColumnResize(to point: CGPoint) {
        if let r = resize { performColumnResize(r, to: point) }
    }

    func endColumnResize() { resize = nil }

    /// The internal column border (and its table) within ~6pt of `point`, if any.
    func columnBorderHit(at point: CGPoint) -> (table: DocumentLayout.TableInfo, leftColumn: Int)? {
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
        var widths = r.widths
        widths[left] = newLeft
        widths[right] = pairSum - newLeft
        setColumnWidths(tablePos: r.tablePos, widths: widths)
    }

    /// Write `colwidth` onto every cell in each column of the table at `tablePos`.
    private func setColumnWidths(tablePos: Int, widths: [CGFloat]) {
        guard let table = editor.doc.nodeAt(tablePos) else { return }
        var tr = editor.state.tr
        var rowPos = tablePos + 1
        for r in 0..<table.childCount {
            let row = table.child(r)
            var cellPos = rowPos + 1
            for c in 0..<row.childCount {
                if c < widths.count {
                    tr = (try? tr.setNodeAttribute(cellPos, "colwidth", .double(Double(widths[c])))) ?? tr
                }
                cellPos += row.child(c).nodeSize
            }
            rowPos += row.nodeSize
        }
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

    // MARK: - UIKeyInput

    public var hasText: Bool { editor.doc.content.size > 0 }

    public func insertText(_ text: String) {
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
        applyingTextInput = true
        defer { applyingTextInput = false }
        markedRange = nil // a delete ends any composition
        deleteInDirection(.backward, by: .character)
    }

    // MARK: - Clipboard (copy / cut / paste / select all)

    open override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(copy(_:)), #selector(cut(_:)):
            return !editor.state.selection.empty
        case #selector(paste(_:)), #selector(pasteAndMatchStyle(_:)):
            let pb = UIPasteboard.general
            return pb.hasStrings || pb.contains(pasteboardTypes: ["public.html"])
        case #selector(selectAll(_:)):
            return editor.doc.content.size > 0
        default:
            return super.canPerformAction(action, withSender: sender)
        }
    }

    open override func copy(_ sender: Any?) { writeSelectionToPasteboard() }

    open override func cut(_ sender: Any?) {
        writeSelectionToPasteboard()
        deleteCurrentSelection()
    }

    open override func paste(_ sender: Any?) {
        let pb = UIPasteboard.general
        if pb.contains(pasteboardTypes: ["public.html"]),
           let data = pb.data(forPasteboardType: "public.html"),
           let html = String(data: data, encoding: .utf8),
           let doc = try? HTMLParser.parse(html, schema: editor.schema) {
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

    /// Paste the pasteboard's text as plain text, discarding any rich formatting.
    open override func pasteAndMatchStyle(_ sender: Any?) {
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
        let arrows = [UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow,
                      UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow]
        let modifierSets: [UIKeyModifierFlags] = [[], .shift, .alternate, .command, [.shift, .alternate], [.shift, .command]]
        var commands: [UIKeyCommand] = []
        for input in arrows {
            for mods in modifierSets {
                let command = UIKeyCommand(input: input, modifierFlags: mods, action: #selector(handleNavigationCommand(_:)))
                command.wantsPriorityOverSystemBehavior = true
                commands.append(command)
            }
        }
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
            if handle(key: key) { handledAny = true }
        }
        if !handledAny { super.pressesBegan(presses, with: event) }
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
            deleteInDirection(.backward, by: granularity); return true
        case .keyboardDeleteForward:
            deleteInDirection(.forward, by: mods.contains(.alternate) ? .word : .character); return true
        case .keyboardReturnOrEnter:
            // Respect modifiers (Shift-Enter = hard break, Mod-Enter = exit code).
            let enter = modifierPrefix(mods) + "Enter"
            if runKey(enter) { return true }
            return runKey("Enter")
        case .keyboardTab:
            // The Tab key produces "\t"; map it to the named "Tab" binding.
            return runKey(mods.contains(.shift) ? "Shift-Tab" : "Tab")
        case .keyboardEscape:
            if isFindBarVisible { hideFindBar(); return true }
            // Escape has no characters, so map it to the named binding.
            return runKey("Escape")
        default:
            let stroke = keyStroke(from: key)
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
            let edge = direction == .backward ? sel.from : sel.to
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
            goalColumnHead = sel.head // at an edge: keep the goal for the next move
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
        // Only drag when the gesture starts on the (non-empty) selection.
        let sel = editor.state.selection
        guard !sel.empty, let pos = ensureLayout().position(at: docPoint(session.location(in: self))),
              pos >= sel.from, pos <= sel.to else { return [] }
        let text = editor.doc.textBetween(sel.from, sel.to)
        guard !text.isEmpty else { return [] }
        dragSourceRange = (sel.from, sel.to)
        return [UIDragItem(itemProvider: NSItemProvider(object: text as NSString))]
    }

    public func dragInteraction(_ interaction: UIDragInteraction, session: any UIDragSession, didEndWith operation: UIDropOperation) {
        dragSourceRange = nil
    }

    public func dropInteraction(_ interaction: UIDropInteraction, canHandle session: any UIDropSession) -> Bool {
        session.canLoadObjects(ofClass: NSString.self) || session.canLoadObjects(ofClass: UIImage.self)
    }

    public func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: any UIDropSession) -> UIDropProposal {
        // A drag we started → move; anything from outside → copy.
        UIDropProposal(operation: session.localDragSession != nil ? .move : .copy)
    }

    public func dropInteraction(_ interaction: UIDropInteraction, performDrop session: any UIDropSession) {
        guard let dropPos = ensureLayout().position(at: docPoint(session.location(in: self))) else { return }
        // Capture the move source now (the drag session ends before async loads).
        let moveFrom = session.localDragSession != nil ? dragSourceRange : nil
        if session.canLoadObjects(ofClass: NSString.self) {
            _ = session.loadObjects(ofClass: NSString.self) { [weak self] items in
                guard let self, let text = items.first as? String, !text.isEmpty else { return }
                Task { @MainActor in self.dropText(text, at: dropPos, movingFrom: moveFrom) }
            }
        } else if session.canLoadObjects(ofClass: UIImage.self) {
            _ = session.loadObjects(ofClass: UIImage.self) { [weak self] items in
                guard let self, let image = items.first as? UIImage, let data = image.pngData() else { return }
                Task { @MainActor in self.dropImage(data, at: dropPos) }
            }
        }
    }

    /// Insert dropped text at `dropPos`, or move it there from `moveFrom`.
    func dropText(_ text: String, at dropPos: Int, movingFrom moveFrom: (from: Int, to: Int)?) {
        let tr = editor.state.tr
        if let (a, b) = moveFrom {
            if dropPos >= a && dropPos <= b { return } // dropped inside itself — no-op
            if dropPos > b {
                _ = try? tr.delete(a, b)
                _ = try? tr.insertText(text, dropPos - (b - a))
            } else { // dropPos < a
                _ = try? tr.insertText(text, dropPos)
                _ = try? tr.delete(a + text.count, b + text.count)
            }
        } else {
            _ = try? tr.insertText(text, dropPos)
        }
        if tr.docChanged { editor.dispatch(tr.scrollIntoView()) }
    }

    /// Insert a dropped image as an image node (a `data:` URL it can load/render).
    func dropImage(_ data: Data, at dropPos: Int) {
        guard let type = editor.schema.nodes["image"],
              let node = try? type.create(["src": .string("data:image/png;base64," + data.base64EncodedString())]) else { return }
        let tr = editor.state.tr
        _ = try? tr.insert(dropPos, node)
        if tr.docChanged { editor.dispatch(tr.scrollIntoView()) }
    }
}

extension EditorTextView: UIGestureRecognizerDelegate {
    /// Coexist with UITextInteraction's own recognizers.
    public func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

/// Load an image from a data:, file:, or http(s) URL. Nonisolated so it can run
/// off the main actor.
private func loadImage(from url: URL) async -> UIImage? {
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

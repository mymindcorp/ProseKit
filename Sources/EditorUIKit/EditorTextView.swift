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
    public var spellCheckingEnabled = true { didSet { spellCacheDoc = nil; setNeedsDisplay() } }
    /// Whether a Shift key is currently held (for shift-click selection).
    private var shiftDown = false

    private var layout: DocumentLayout?
    private var lastLayoutWidth: CGFloat = 0
    private var caretLayer = CAShapeLayer()
    private var blinkTimer: Timer?

    public init(editor: Editor, theme: TextTheme = TextTheme(), frame: CGRect = .zero) {
        self.editor = editor
        self.theme = theme
        super.init(frame: frame)
        backgroundColor = .systemBackground
        isUserInteractionEnabled = true
        contentMode = .redraw
        caretLayer.fillColor = theme.caretColor.cgColor
        layer.addSublayer(caretLayer)

        // A single tap fires immediately (no require-to-fail chain, which would
        // delay it by the multi-tap timeouts). A double/triple tap also fires
        // the single tap first — harmless, since it just places then refines the
        // selection.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        let tripleTap = UITapGestureRecognizer(target: self, action: #selector(handleTripleTap(_:)))
        tripleTap.numberOfTapsRequired = 3
        // On touch, a long-press initiates a drag selection (so it doesn't
        // fight scrolling). With a mouse/trackpad, a click-drag selects right
        // away — a pan restricted to the indirect-pointer touch type, which
        // leaves finger-drag scrolling untouched.
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.3
        let mouseDrag = UIPanGestureRecognizer(target: self, action: #selector(handleMouseDrag(_:)))
        mouseDrag.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        addGestureRecognizer(tap)
        addGestureRecognizer(doubleTap)
        addGestureRecognizer(tripleTap)
        addGestureRecognizer(longPress)
        addGestureRecognizer(mouseDrag)

        editor.onChange = { [weak self] _ in self?.setNeedsRebuild() }
    }

    /// The document position currently anchoring a drag selection.
    private var dragAnchor: Int?

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Layout lifecycle

    private func setNeedsRebuild() {
        // The layout is rebuilt lazily by `ensureLayout`, and only when the
        // document or width actually changes — selection/caret/scroll changes
        // reuse the existing layout (avoiding a full relayout per keystroke move).
        setNeedsDisplay()
        invalidateIntrinsicContentSize()
        updateCaret()
    }

    private var imageCache: [String: UIImage] = [:]
    private var imageTasks: [String: Task<Void, Never>] = [:]
    private var layoutDoc: Node?

    /// Force a full relayout on the next draw (for theme / Dynamic Type changes
    /// where the document is unchanged but fonts/sizing differ).
    private func invalidateLayout() {
        layout = nil
        layoutDoc = nil
        setNeedsRebuild()
    }

    private func ensureLayout() -> DocumentLayout {
        if let layout, lastLayoutWidth == bounds.width, layoutDoc == editor.doc { return layout }
        let l = DocumentLayout(doc: editor.doc, width: max(bounds.width, 1), theme: theme,
                               imageProvider: { [weak self] src in self?.imageCache[src] })
        layout = l
        lastLayoutWidth = bounds.width
        layoutDoc = editor.doc
        loadPendingImages(l.pendingImageSources)
        return l
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

    open override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            invalidateLayout() // Dynamic Type changed — re-lay-out with new font sizes
        }
    }

    open override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: ensureLayout().height)
    }

    open override func sizeThatFits(_ size: CGSize) -> CGSize {
        let l = DocumentLayout(doc: editor.doc, width: max(size.width, 1), theme: theme)
        return CGSize(width: size.width, height: l.height)
    }

    // MARK: - Drawing

    open override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let l = ensureLayout()
        // Placeholder when the document is empty.
        if let placeholder, !placeholder.isEmpty, isDocumentEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: theme.bodyFont, .foregroundColor: theme.codeColor]
            let origin = CGPoint(x: theme.pageInsets.left, y: theme.pageInsets.top)
            NSAttributedString(string: placeholder, attributes: attrs).draw(at: origin)
        }
        // Plugin + spelling decorations.
        let decorations = gatherDecorations()
        for deco in decorations where deco.kind == .inline {
            if let hex = deco.attributes["background"], let color = UIColor(hex: hex) {
                ctx.setFillColor(color.cgColor)
                for r in l.selectionRects(from: deco.from, to: deco.to) { ctx.fill(r) }
            }
        }
        // Selection highlight (every range — a cell selection has several).
        let sel = editor.state.selection
        if !sel.empty {
            ctx.setFillColor(theme.selectionColor.cgColor)
            for range in sel.ranges {
                for r in l.selectionRects(from: range.from.pos, to: range.to.pos) { ctx.fill(r) }
            }
        }
        l.draw(in: ctx)

        // Spelling: dotted red underline beneath each misspelled range.
        ctx.setStrokeColor(UIColor.systemRed.cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [2, 2])
        for deco in decorations where deco.attributes["spelling"] != nil {
            for r in l.selectionRects(from: deco.from, to: deco.to) {
                let y = r.maxY - 1
                ctx.move(to: CGPoint(x: r.minX, y: y))
                ctx.addLine(to: CGPoint(x: r.maxX, y: y))
            }
        }
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
    }

    private var spellCacheDoc: Node?
    private var spellCache: [Decoration] = []

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

    private var spellInFlightDoc: Node?

    /// Spell-check decorations. Computed off the main thread (UITextChecker is
    /// slow) and cached by document; `draw` never blocks on it — it shows the
    /// last result until the async pass finishes and triggers a redraw.
    private func currentSpellDecorations() -> [Decoration] {
        guard spellCheckingEnabled else { return [] }
        let doc = editor.doc
        if spellCacheDoc == doc { return spellCache }
        if spellInFlightDoc != doc {
            spellInFlightDoc = doc
            Task.detached(priority: .utility) {
                let decos = SpellCheck.decorations(for: doc)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.spellCache = decos
                    self.spellCacheDoc = doc
                    if self.editor.doc == doc { self.setNeedsDisplay() }
                }
            }
        }
        return spellCache // possibly stale; refreshed when the async pass lands
    }

    /// Whether the document is a single empty textblock.
    private var isDocumentEmpty: Bool {
        editor.doc.childCount == 1
            && editor.doc.firstChild?.isTextblock == true
            && editor.doc.firstChild?.content.size == 0
    }

    // MARK: - Caret

    private func updateCaret() {
        let sel = editor.state.selection
        guard isFirstResponder, sel.empty, let rect = ensureLayout().caretRect(at: sel.head) else {
            caretLayer.path = nil
            if isFirstResponder, let rect = ensureLayout().caretRect(at: editor.state.selection.head) {
                revealRect(rect) // keep the active end of a range visible too
            }
            return
        }
        caretLayer.path = UIBezierPath(rect: rect).cgPath
        caretLayer.fillColor = theme.caretColor.cgColor
        caretLayer.opacity = 1
        revealRect(rect)
    }

    /// Scroll the nearest enclosing scroll view so the given rect is visible.
    private func revealRect(_ rect: CGRect) {
        guard let scrollView = enclosingScrollView else { return }
        let inView = convert(rect.insetBy(dx: 0, dy: -8), to: scrollView)
        scrollView.scrollRectToVisible(inView, animated: false)
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

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        if !isFirstResponder { becomeFirstResponder() }
        let point = gesture.location(in: self)
        // A tap on a task-item checkbox toggles its checked state.
        if let box = ensureLayout().checkbox(at: point) {
            if let tr = try? editor.state.tr.setNodeAttribute(box.pos, "checked", .bool(!box.checked)) {
                editor.dispatch(tr)
            }
            return
        }
        if let pos = ensureLayout().position(at: point) {
            let target = min(pos, editor.doc.content.size)
            if shiftDown {
                // Shift-click extends the selection from the current anchor.
                setTextSelection(anchor: editor.state.selection.anchor, head: target)
            } else {
                editor.dispatch(editor.state.tr.setSelection(Selection.near(editor.doc.resolve(target))))
            }
        }
    }

    @objc private func handleTripleTap(_ gesture: UITapGestureRecognizer) {
        if !isFirstResponder { becomeFirstResponder() }
        let point = gesture.location(in: self)
        if let pos = ensureLayout().position(at: point) {
            selectParagraph(at: min(pos, editor.doc.content.size))
        }
    }

    /// The document position before the table cell containing `pos`, if any.
    private func cellPosition(containing pos: Int) -> Int? {
        let resolved = editor.doc.resolve(min(max(pos, 0), editor.doc.content.size))
        var depth = resolved.depth
        while depth > 0 {
            let name = resolved.node(depth).type.name
            if name == "tableCell" || name == "tableHeader" { return resolved.before(depth) }
            depth -= 1
        }
        return nil
    }

    /// Select the whole textblock (paragraph/heading/…) at the given position.
    private func selectParagraph(at pos: Int) {
        let resolved = editor.doc.resolve(pos)
        guard resolved.parent.isTextblock else { return }
        setTextSelection(anchor: resolved.start(), head: resolved.end())
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if !isFirstResponder { becomeFirstResponder() }
        let point = gesture.location(in: self)
        if let pos = ensureLayout().position(at: point) {
            selectWord(at: min(pos, editor.doc.content.size))
        }
    }

    // Touch long-press and mouse/trackpad drag share one drag-selection model.
    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        driveDragSelection(state: gesture.state, point: gesture.location(in: self))
    }

    @objc private func handleMouseDrag(_ gesture: UIPanGestureRecognizer) {
        driveDragSelection(state: gesture.state, point: gesture.location(in: self))
    }

    private func driveDragSelection(state: UIGestureRecognizer.State, point: CGPoint) {
        switch state {
        case .began:
            if !isFirstResponder { becomeFirstResponder() }
            dragAnchor = ensureLayout().position(at: point)
            if let anchor = dragAnchor {
                editor.dispatch(editor.state.tr.setSelection(Selection.near(editor.doc.resolve(min(anchor, editor.doc.content.size)))))
            }
        case .changed:
            guard let anchor = dragAnchor, let head = ensureLayout().position(at: point) else { return }
            // Dragging across cells of the same table makes a cell selection.
            if let anchorCell = cellPosition(containing: anchor),
               let headCell = cellPosition(containing: head), anchorCell != headCell {
                editor.dispatch(editor.state.tr.setSelection(
                    CellSelection.create(editor.doc, anchorCellPos: anchorCell, headCellPos: headCell)))
            } else {
                setTextSelection(anchor: anchor, head: head)
            }
        case .ended, .cancelled, .failed:
            dragAnchor = nil
        default:
            break
        }
    }

    /// Set a text selection between two document positions, snapping to valid
    /// text positions.
    private func setTextSelection(anchor: Int, head: Int) {
        let size = editor.doc.content.size
        let a = editor.doc.resolve(min(max(anchor, 0), size))
        let h = editor.doc.resolve(min(max(head, 0), size))
        editor.dispatch(editor.state.tr.setSelection(TextSelection.between(a, h)))
    }

    /// Select the word at the given document position.
    private func selectWord(at pos: Int) {
        let resolved = editor.doc.resolve(pos)
        guard resolved.parent.isTextblock else {
            setTextSelection(anchor: pos, head: min(pos + 1, editor.doc.content.size))
            return
        }
        let contentStart = resolved.start()
        let chars = inlineCharacters(of: resolved.parent)
        let offset = pos - contentStart
        let isWord: (Character) -> Bool = { $0.isLetter || $0.isNumber || $0 == "_" }
        var lo = min(max(offset, 0), chars.count)
        var hi = lo
        while lo > 0 && isWord(chars[lo - 1]) { lo -= 1 }
        while hi < chars.count && isWord(chars[hi]) { hi += 1 }
        if lo == hi { // not on a word — select a single character if possible
            if hi < chars.count { hi += 1 } else if lo > 0 { lo -= 1 }
        }
        setTextSelection(anchor: contentStart + lo, head: contentStart + hi)
    }

    /// The inline characters of a textblock, one entry per document position
    /// (atoms contribute a single placeholder).
    private func inlineCharacters(of parent: Node) -> [Character] {
        var chars: [Character] = []
        for i in 0..<parent.childCount {
            let child = parent.child(i)
            if child.isText {
                chars.append(contentsOf: Array(child.text ?? ""))
            } else {
                chars.append("\u{fffc}") // object replacement — a non-word boundary
            }
        }
        return chars
    }

    // MARK: - UIKeyInput

    public var hasText: Bool { editor.doc.content.size > 0 }

    public func insertText(_ text: String) {
        if text == "\n" { runKey("Enter"); return }
        let sel = editor.state.selection
        // Try input rules (only at a collapsed cursor).
        if sel.empty, runTextInput(from: sel.from, to: sel.to, text: text) { return }
        let tr = editor.state.tr
        try? tr.insertText(text)
        editor.dispatch(tr)
    }

    public func deleteBackward() {
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
            try? tr.insertText(string)
            editor.dispatch(tr)
            return
        }
        let paragraphs = lines.compactMap { line -> Node? in
            try? editor.schema.node("paragraph", [:], content: Fragment.from(line.isEmpty ? [] : [editor.schema.text(line)]))
        }
        insertContent(Fragment.from(paragraphs))
    }

    // MARK: - Key handling

    open override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handledAny = false
        for press in presses {
            guard let key = press.key else { continue }
            if key.modifierFlags.contains(.shift) { shiftDown = true }
            if handle(key: key) { handledAny = true }
        }
        if !handledAny { super.pressesBegan(presses, with: event) }
    }

    open override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where !(press.key?.modifierFlags.contains(.shift) ?? true) { shiftDown = false }
        if presses.contains(where: { $0.key?.keyCode == .keyboardLeftShift || $0.key?.keyCode == .keyboardRightShift }) {
            shiftDown = false
        }
        super.pressesEnded(presses, with: event)
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
        let target = TextNavigation.position(in: editor.doc, from: sel.head, moving: direction, by: granularity)
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

    private func moveCaretVertically(up: Bool, extend: Bool = false) {
        let sel = editor.state.selection
        let l = ensureLayout()
        guard let caret = l.caretRect(at: sel.head),
              let pos = l.verticalPosition(from: sel.head, up: up, preferredX: caret.midX) else { return }
        let target = min(pos, editor.doc.content.size)
        if extend {
            setTextSelection(anchor: sel.anchor, head: target)
        } else {
            editor.dispatch(editor.state.tr.setSelection(Selection.near(editor.doc.resolve(target))))
        }
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

#if canImport(UIKit)
public import UIKit
import DocumentModel
import EditorStateKit
import SchemaKit
import DocumentTransform

// `UITextInput` conformance: lets the system drive text input the native way —
// IME / marked-text composition (CJK, accents), dictation, autocorrect, and the
// loupe / selection handles / edit menu. Document positions (ProseMirror ints)
// are exposed as opaque `UITextPosition` offsets; geometry comes from the
// CoreText `DocumentLayout`.

/// A document position, wrapping a ProseMirror integer position.
final class DocTextPosition: UITextPosition {
    let offset: Int
    init(_ offset: Int) { self.offset = offset }
}

/// A document range in position offsets.
final class DocTextRange: UITextRange {
    let from: Int
    let to: Int
    init(_ from: Int, _ to: Int) { self.from = min(from, to); self.to = max(from, to) }
    override var start: UITextPosition { DocTextPosition(from) }
    override var end: UITextPosition { DocTextPosition(to) }
    override var isEmpty: Bool { from == to }
}

/// A selection rectangle for the loupe / handles.
final class DocSelectionRect: UITextSelectionRect {
    private let _rect: CGRect
    private let _containsStart: Bool
    private let _containsEnd: Bool
    init(rect: CGRect, containsStart: Bool, containsEnd: Bool) {
        _rect = rect
        _containsStart = containsStart
        _containsEnd = containsEnd
    }
    override var rect: CGRect { _rect }
    override var writingDirection: NSWritingDirection { .natural }
    override var containsStart: Bool { _containsStart }
    override var containsEnd: Bool { _containsEnd }
    override var isVertical: Bool { false }
}

extension EditorTextView: UITextInput {
    private var docSize: Int { editor.doc.content.size }
    private func clamp(_ p: Int) -> Int { min(max(p, 0), docSize) }

    // MARK: Delegate / tokenizer / styles

    public var inputDelegate: (any UITextInputDelegate)? {
        get { textInputDelegate }
        set { textInputDelegate = newValue }
    }
    public var tokenizer: any UITextInputTokenizer { inputTokenizer }
    public var markedTextStyle: [NSAttributedString.Key: Any]? {
        get { markedTextStyleStore }
        set { markedTextStyleStore = newValue }
    }

    // MARK: Ranges & positions

    public var beginningOfDocument: UITextPosition { DocTextPosition(0) }
    public var endOfDocument: UITextPosition { DocTextPosition(docSize) }

    public var selectedTextRange: UITextRange? {
        get { let s = editor.state.selection; return DocTextRange(s.from, s.to) }
        set {
            guard let r = newValue as? DocTextRange else { return }
            applyingTextInput = true
            defer { applyingTextInput = false }
            let a = editor.doc.resolve(clamp(r.from))
            let h = editor.doc.resolve(clamp(r.to))
            // An empty selection at a valid gap becomes a gap cursor —
            // TextSelection.between would snap away into a neighbor block.
            if r.from == r.to, GapCursor.valid(h) {
                editor.dispatch(editor.state.tr.setSelection(GapCursor(h)))
                return
            }
            // A range that exactly spans one leaf atom is that node, selected:
            // double-tapping an image (or a mention chip) reaches here as the
            // atom's one-position "word", and the node should be what deleting
            // or copying then addresses. Only leaf atoms — a drag whose
            // endpoints happen to bracket a paragraph is still a text drag.
            if let node = a.nodeAfter, node.isLeaf, NodeSelection.isSelectable(node),
               clamp(r.from) + node.nodeSize == clamp(r.to) {
                editor.dispatch(editor.state.tr.setSelection(NodeSelection(a)))
                return
            }
            // A drag whose endpoints sit in different cells of one table is a
            // cell selection (prosemirror-tables' createSelectionBetween).
            if r.from != r.to,
               let anchorCell = cellAround(a), let headCell = cellAround(h),
               anchorCell.pos != headCell.pos, inSameTable(anchorCell, headCell) {
                editor.dispatch(editor.state.tr.setSelection(
                    CellSelection.create(editor.doc, anchorCellPos: anchorCell.pos, headCellPos: headCell.pos)))
                return
            }
            editor.dispatch(editor.state.tr.setSelection(TextSelection.between(a, h)))
        }
    }

    public var markedTextRange: UITextRange? {
        guard let m = markedRange else { return nil }
        return DocTextRange(m.0, m.1)
    }

    public func text(in range: UITextRange) -> String? {
        guard let r = range as? DocTextRange else { return nil }
        let from = clamp(r.from), to = clamp(r.to)
        guard to > from else { return "" }
        // One character per document position, so length == offset difference.
        return projectedText(from: from, to: to)
    }

    public func replace(_ range: UITextRange, withText text: String) {
        guard isEditable, let r = range as? DocTextRange else { return }
        applyingTextInput = true
        defer { applyingTextInput = false }
        let from = clamp(r.from), to = clamp(r.to)
        let tr = editor.state.tr
        _ = try? tr.insertText(text, from, to)
        // Collapse to a caret *after* the inserted text. Without this, mapping the
        // old (often ranged, from a double-tap) selection through the replace can
        // leave the inserted text selected — so the next keystroke replaces it
        // instead of appending, which reads as "typed characters get eaten".
        let caret = min(from + text.count, tr.doc.content.size)
        tr.setSelection(TextSelection.create(tr.doc, caret))
        editor.dispatch(tr)
    }

    // MARK: Marked (IME / composing) text

    public func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        guard isEditable else { return }
        let text = markedText ?? ""
        let sel = editor.state.selection
        let range = markedRange ?? (sel.from, sel.to)
        applyingTextInput = true
        defer { applyingTextInput = false }
        let from = clamp(range.0), to = clamp(range.1)
        let tr = editor.state.tr
        _ = try? tr.insertText(text, from, to)
        let newEnd = from + text.count
        markedRange = text.isEmpty ? nil : (from, newEnd)
        // Selection within the marked text (UTF-16 range approximated onto graphemes).
        let selStart = from + min(max(selectedRange.location, 0), text.count)
        let selEnd = min(selStart + selectedRange.length, newEnd)
        let size = tr.doc.content.size
        tr.setSelection(TextSelection.between(
            tr.doc.resolve(min(max(selStart, 0), size)),
            tr.doc.resolve(min(max(selEnd, 0), size))))
        editor.dispatch(tr)
        setNeedsDisplay()
    }

    public func unmarkText() {
        markedRange = nil
        setNeedsDisplay()
    }

    // MARK: Position arithmetic

    public func textRange(from: UITextPosition, to: UITextPosition) -> UITextRange? {
        guard let f = from as? DocTextPosition, let t = to as? DocTextPosition else { return nil }
        return DocTextRange(f.offset, t.offset)
    }

    public func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let p = position as? DocTextPosition else { return nil }
        let n = p.offset + offset
        guard n >= 0, n <= docSize else { return nil }
        return DocTextPosition(n)
    }

    public func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        guard let p = position as? DocTextPosition else { return nil }
        switch direction {
        case .right: return self.position(from: p, offset: offset)
        case .left: return self.position(from: p, offset: -offset)
        case .up, .down:
            var pos = p.offset
            let layout = ensureLayout()
            for _ in 0..<max(offset, 0) {
                guard let caret = layout.caretRect(at: pos),
                      let next = layout.verticalPosition(from: pos, up: direction == .up, preferredX: caret.midX) else { break }
                pos = next
            }
            return DocTextPosition(clamp(pos))
        @unknown default: return nil
        }
    }

    public func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        let a = (position as? DocTextPosition)?.offset ?? 0
        let b = (other as? DocTextPosition)?.offset ?? 0
        if a < b { return .orderedAscending }
        if a > b { return .orderedDescending }
        return .orderedSame
    }

    public func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        ((toPosition as? DocTextPosition)?.offset ?? 0) - ((from as? DocTextPosition)?.offset ?? 0)
    }

    public func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        guard let r = range as? DocTextRange else { return nil }
        switch direction {
        case .left, .up: return DocTextPosition(r.from)
        default: return DocTextPosition(r.to)
        }
    }

    public func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        guard let p = position as? DocTextPosition else { return nil }
        switch direction {
        case .left, .up: return DocTextRange(max(0, p.offset - 1), p.offset)
        default: return DocTextRange(p.offset, min(docSize, p.offset + 1))
        }
    }

    // MARK: Writing direction

    public func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection {
        .natural
    }
    public func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}

    // MARK: Geometry
    //
    // `UITextInteraction` and the system text loupe/handles work in the view's
    // coordinate space, while the layout is in document coordinates. With
    // virtualization the two differ by `contentOffsetY`, so rects are shifted up
    // by it and incoming points (`docPoint`) shifted down by it.

    public func firstRect(for range: UITextRange) -> CGRect {
        guard let r = range as? DocTextRange else { return .zero }
        let from = clamp(r.from), to = clamp(r.to)
        // In document space this doesn't move while you scroll, and UIKit asks
        // for it on every tick — so cache it and re-apply only the offset.
        let layout = ensureLayout()   // may realize, and so bump the generation
        if firstRectCacheStamp != (layoutGeneration, bounds.width) {
            firstRectCache.removeAll(keepingCapacity: true)
            firstRectCacheStamp = (layoutGeneration, bounds.width)
        }
        let key = RangeKey(from: from, to: to)
        if let hit = firstRectCache[key] { return hit.offsetBy(dx: 0, dy: -contentOffsetY) }
        // Only the first line is wanted, so look where the range starts rather
        // than computing every rect of it and throwing all but one away.
        let band = (layout.caretRect(at: from)?.minY).map { ($0 - 1) ... ($0 + max(bounds.height, 1)) }
        let rects = layout.selectionRects(from: from, to: to, clipY: band)
        guard let first = rects.first else { return caretRect(for: DocTextPosition(r.from)) }
        if firstRectCache.count >= Self.geometryCacheLimit {
            firstRectCache.removeAll(keepingCapacity: true)
        }
        firstRectCache[key] = first
        return first.offsetBy(dx: 0, dy: -contentOffsetY)
    }

    public func caretRect(for position: UITextPosition) -> CGRect {
        guard let p = position as? DocTextPosition else { return .zero }
        return (ensureLayout().caretRect(at: clamp(p.offset)) ?? .zero).offsetBy(dx: 0, dy: -contentOffsetY)
    }

    /// UIKit re-queries this on every scroll tick — `notifySelectionGeometryChanged`
    /// tells it to, so the native caret doesn't strand — and a lazily realized
    /// layout only ever grows, so an unclipped answer grows with it: a document
    /// selected end to end went from 291 rects to 1261 over the first few
    /// screens, and to tens of thousands by the bottom, each one queried per
    /// frame. Answer for a band around the viewport instead. UIKit is drawing
    /// handles and a loupe, neither of which can show what isn't near the
    /// screen, so the rects it cannot use are the ones we stop computing.
    ///
    /// `containsStart`/`containsEnd` stay honest about the *whole* selection:
    /// they're only set when the real endpoint is inside the band, so a
    /// selection running off screen reports no handle there rather than
    /// pinning one to the edge.
    public func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        guard let r = range as? DocTextRange else { return [] }
        let from = clamp(r.from), to = clamp(r.to)
        let layout = ensureLayout()
        let h = max(bounds.height, 1)
        let band = (contentOffsetY - h) ... (contentOffsetY + 2 * h)
        let rects = layout.selectionRects(from: from, to: to, clipY: band)
        func endpointVisible(_ pos: Int) -> Bool {
            guard let caret = layout.caretRect(at: pos) else { return false }
            return caret.maxY >= band.lowerBound && caret.minY <= band.upperBound
        }
        let startVisible = endpointVisible(from), endVisible = endpointVisible(to)
        return rects.enumerated().map { index, rect in
            DocSelectionRect(rect: rect.offsetBy(dx: 0, dy: -contentOffsetY),
                             containsStart: index == 0 && startVisible,
                             containsEnd: index == rects.count - 1 && endVisible)
        }
    }

    public func closestPosition(to point: CGPoint) -> UITextPosition? {
        let dp = docPoint(point)
        // A tap between blocks where no text position exists maps to the gap
        // boundary; setting an empty selection there produces a GapCursor.
        if let gap = gapBoundaryPosition(at: dp) { return DocTextPosition(gap) }
        return DocTextPosition(ensureLayout().position(at: dp) ?? 0)
    }

    public func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
        guard let r = range as? DocTextRange, let p = ensureLayout().position(at: docPoint(point)) else {
            return closestPosition(to: point)
        }
        return DocTextPosition(min(max(p, r.from), r.to))
    }

    public func characterRange(at point: CGPoint) -> UITextRange? {
        guard let p = ensureLayout().position(at: docPoint(point)) else { return nil }
        return DocTextRange(p, min(docSize, p + 1))
    }
}
#endif

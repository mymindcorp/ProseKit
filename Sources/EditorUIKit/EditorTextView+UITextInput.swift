#if canImport(UIKit)
import UIKit
import DocumentModel
import EditorStateKit

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

    public var inputDelegate: UITextInputDelegate? {
        get { textInputDelegate }
        set { textInputDelegate = newValue }
    }
    public var tokenizer: UITextInputTokenizer { inputTokenizer }
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
        guard let r = range as? DocTextRange else { return }
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
        let rects = ensureLayout().selectionRects(from: clamp(r.from), to: clamp(r.to))
        return (rects.first?.offsetBy(dx: 0, dy: -contentOffsetY)) ?? caretRect(for: DocTextPosition(r.from))
    }

    public func caretRect(for position: UITextPosition) -> CGRect {
        guard let p = position as? DocTextPosition else { return .zero }
        return (ensureLayout().caretRect(at: clamp(p.offset)) ?? .zero).offsetBy(dx: 0, dy: -contentOffsetY)
    }

    public func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        guard let r = range as? DocTextRange else { return [] }
        let rects = ensureLayout().selectionRects(from: clamp(r.from), to: clamp(r.to))
        return rects.enumerated().map { index, rect in
            DocSelectionRect(rect: rect.offsetBy(dx: 0, dy: -contentOffsetY), containsStart: index == 0, containsEnd: index == rects.count - 1)
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

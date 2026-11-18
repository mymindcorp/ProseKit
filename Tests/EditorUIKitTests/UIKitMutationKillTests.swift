#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

@MainActor
private final class KillPointerTouch: UITouch {
    var point: CGPoint = .zero
    var clicks = 1
    override func location(in view: UIView?) -> CGPoint { point }
    override var type: UITouch.TouchType { .indirectPointer }
    override var tapCount: Int { clicks }
}

@MainActor
private final class KillPointerEvent: UIEvent {
    override var buttonMask: UIEvent.ButtonMask { .primary }
    override var modifierFlags: UIKeyModifierFlags { [] }
}

@MainActor
private final class KillMouseSelection: MouseSelectionRecognizer {
    var fakeState: UIGestureRecognizer.State = .possible
    override var state: UIGestureRecognizer.State {
        get { fakeState }
        set { fakeState = newValue }
    }
}

/// Behaviour that a mutation-testing pass over `EditorUIKit` found could be
/// broken without any other test noticing. Each case names the decision it
/// pins; each was checked to fail against the broken source and pass against
/// the real one.
@MainActor
final class UIKitMutationKillTests: XCTestCase {
    // MARK: - Helpers

    private func makeView(extensions: [any Extension] = fullKit(),
                          width: CGFloat = 320, height: CGFloat = 480,
                          _ blocks: (Schema) throws -> [Node]) throws -> EditorTextView {
        let editor = try Editor(extensions: extensions)
        editor.setContent(try editor.schema.node("doc", [:], content: Fragment.from(try blocks(editor.schema))))
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        view.layoutIfNeeded()
        return view
    }

    private func paragraphs(_ texts: [String], width: CGFloat = 320, height: CGFloat = 480) throws -> EditorTextView {
        try makeView(width: width, height: height) { s in
            try texts.map { t in try s.node("paragraph", [:], content: Fragment.from(t.isEmpty ? [] : [s.text(t)])) }
        }
    }

    /// "ab", an inline image, "cd": text at 1..<3, the image at 3, text at 4..<6.
    private func inlineImageView() throws -> EditorTextView {
        try makeView(extensions: starterKit() + [ImageExtension(inline: true)]) { s in
            [try s.node("paragraph", [:], content: Fragment.from([
                s.text("ab"),
                try s.node("image", ["src": .string("asset://inline"), "width": .int(60), "height": .int(40)]),
                s.text("cd"),
            ]))]
        }
    }

    private func spans(_ decos: [Decoration]) -> [String] { decos.map { "\($0.from)-\($0.to)" } }

    /// A layout of one paragraph that opens with a *drawable* inline image —
    /// one U+FFFC under a run delegate, not the placeholder text an image
    /// without bytes shows — followed by "after". The image is at position 1.
    private func leadingImageLayout() throws -> DocumentLayout {
        let editor = try Editor(extensions: starterKit() + [ImageExtension(inline: true)])
        let s = editor.schema
        let doc = try s.node("doc", [:], content: Fragment.from([
            try s.node("paragraph", [:], content: Fragment.from([
                try s.node("image", ["src": .string("asset://lead"), "width": .int(60), "height": .int(40)]),
                s.text("after"),
            ])),
        ]))
        let picture = UIGraphicsImageRenderer(size: CGSize(width: 60, height: 40)).image { ctx in
            UIColor.blue.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 60, height: 40))
        }
        return DocumentLayout(doc: doc, width: 320, theme: DocumentTheme(), imageProvider: { _ in picture })
    }

    // MARK: - SpellCheck

    /// An inline atom ends a word: re-checking an edit just after an image must
    /// not widen back across it into the word in front.
    func testRecheckStopsWideningAtAnInlineAtom() throws {
        let view = try makeView(extensions: starterKit() + [ImageExtension(inline: true)]) { s in
            [try s.node("paragraph", [:], content: Fragment.from([
                s.text("helo"),                                         // 1..<5
                try s.node("image", ["src": .string("asset://x")]),     // 5
                s.text("wrold"),                                        // 6..<11
            ]))]
        }
        let result = SpellCheck.recheck(view.editor.doc, around: 8...8)
        XCTAssertEqual(result.checked, [6...11], "only the word after the image")
        XCTAssertEqual(spans(result.decorations), ["6-11"])
    }

    /// The full (viewport) pass skips code blocks just as the re-check does.
    func testTheViewportPassDoesNotSpellCheckCode() throws {
        let view = try makeView { s in
            [try s.node("paragraph", [:], content: Fragment.from([s.text("mispeled")])),   // 1..<9
             try s.node("codeBlock", [:], content: Fragment.from([s.text("mispeled")]))]
        }
        XCTAssertEqual(spans(SpellCheck.decorations(for: view.editor.doc)), ["1-9"])
    }

    // MARK: - UITextInput selection

    /// A range that starts on an inline atom but runs past it is a text drag,
    /// not a node selection of the atom.
    func testARangeReachingPastAnInlineAtomStaysATextSelection() throws {
        let view = try inlineImageView()
        XCTAssertEqual(view.editor.doc.nodeAt(3)?.type.name, "image")
        view.selectedTextRange = DocTextRange(3, 5)
        let sel = view.editor.state.selection
        XCTAssertFalse(sel is NodeSelection)
        XCTAssertEqual(sel.from, 3)
        XCTAssertEqual(sel.to, 5)
        // Exactly the atom is still the node.
        view.selectedTextRange = DocTextRange(3, 4)
        XCTAssertTrue(view.editor.state.selection is NodeSelection)
    }
    /// The selection IME asks for inside the marked text is honoured: a
    /// candidate that highlights its whole reading selects all of it.
    func testMarkedTextSelectionSpansTheRangeTheIMEAsksFor() throws {
        let view = try paragraphs([""])
        view.setMarkedText("abc", selectedRange: NSRange(location: 0, length: 3))
        let sel = view.editor.state.selection
        XCTAssertEqual(sel.from, 1)
        XCTAssertEqual(sel.to, 4)
        view.setMarkedText("abcd", selectedRange: NSRange(location: 1, length: 2))
        XCTAssertEqual(view.editor.state.selection.from, 2)
        XCTAssertEqual(view.editor.state.selection.to, 4)
    }

    /// The end of the document is a position: offsetting onto it answers it.
    func testOffsettingOntoTheEndOfTheDocumentIsAPosition() throws {
        let view = try paragraphs(["abc"])
        let end = view.editor.doc.content.size
        XCTAssertEqual((view.position(from: DocTextPosition(end - 1), offset: 1) as? DocTextPosition)?.offset, end)
        XCTAssertEqual((view.position(from: DocTextPosition(0), offset: end) as? DocTextPosition)?.offset, end)
        XCTAssertNil(view.position(from: DocTextPosition(0), offset: end + 1))
    }

    // MARK: - Vertical movement

    /// Going down into a table cell that holds several paragraphs lands in the
    /// cell's *first* paragraph, even when the row's other cell is tall enough
    /// to put both of them on the same "row" of blocks.
    func testDownIntoAMultiParagraphCellLandsInItsFirstParagraph() throws {
        let view = try makeView { s in
            func para(_ t: String) throws -> Node { try s.node("paragraph", [:], content: Fragment.from([s.text(t)])) }
            func cell(_ ps: [Node]) throws -> Node { try s.node("tableCell", [:], content: Fragment.from(ps)) }
            func row(_ cs: [Node]) throws -> Node { try s.node("tableRow", [:], content: Fragment.from(cs)) }
            let long = String(repeating: "tall words wrap ", count: 12)
            return [try s.node("table", [:], content: Fragment.from([
                try row([try cell([try para("a")]), try cell([try para("b")])]),
                try row([try cell([try para(long)]), try cell([try para("first"), try para("second")])]),
            ]))]
        }
        let doc = view.editor.doc
        var bPos = 0
        doc.descendants { n, p, _, _ in if n.isText, n.text == "b" { bPos = p + 1 }; return true }
        let l = view.ensureLayout()
        let caret = try XCTUnwrap(l.caretRect(at: bPos))
        let down = try XCTUnwrap(l.verticalPosition(from: bPos, up: false, preferredX: caret.midX))
        XCTAssertEqual(doc.resolve(down).parent.textContent, "first")
    }
    // MARK: - Hit testing

    /// A tap exactly on a line's leading edge resolves to the line's first
    /// position. CoreText, asked about x = 0 itself on a line that opens with a
    /// character that draws nothing (a zero-width space here), answers with the
    /// index *after* it — so sweeping rightwards from the edge went backwards.
    /// Found by `GeometryFuzzTests.testHitTestingRunsLeftToRightAlongALine` at
    /// depth 250 (`focus:bulletList`, `seed:135`); this is the same line alone.
    func testATapOnTheLeadingEdgeOfALineLandsOnItsFirstPosition() throws {
        let view = try paragraphs(["\u{200B}b"])
        let l = view.ensureLayout()
        let line = try XCTUnwrap(l.blocks.first?.lines.first)
        let y = line.baselineOrigin.y - line.ascent + line.height / 2
        XCTAssertEqual(l.position(at: CGPoint(x: line.baselineOrigin.x, y: y)), 1)
        XCTAssertEqual(l.position(at: CGPoint(x: line.baselineOrigin.x + 2, y: y)), 1)
        XCTAssertEqual(l.position(at: CGPoint(x: line.baselineOrigin.x - 10, y: y)), 1)
    }

    // MARK: - Selection rects

    /// A clip band keeps exactly the rects that meet it, even inside a table,
    /// where blocks in document order are not in vertical order: a tall first
    /// cell must not end the walk before the cell beside it.
    func testClippedSelectionRectsInATableKeepTheCellBesideATallOne() throws {
        let view = try makeView { s in
            func para(_ t: String) throws -> Node { try s.node("paragraph", [:], content: Fragment.from([s.text(t)])) }
            func cell(_ ps: [Node]) throws -> Node { try s.node("tableCell", [:], content: Fragment.from(ps)) }
            return [try s.node("table", [:], content: Fragment.from([
                try s.node("tableRow", [:], content: Fragment.from([
                    try cell([try para("p one"), try para("p two"), try para("p three"), try para("p four")]),
                    try cell([try para("q one")]),
                ])),
            ]))]
        }
        let l = view.ensureLayout()
        let first = try XCTUnwrap(l.blocks.first)
        let band = first.frame.minY ... first.frame.maxY
        let size = view.editor.doc.content.size
        let all = l.selectionRects(from: 0, to: size)
        let clipped = l.selectionRects(from: 0, to: size, clipY: band)
        let expected = all.filter { $0.maxY >= band.lowerBound && $0.minY <= band.upperBound }
        XCTAssertEqual(expected.count, 2, "p one and q one share the band")
        XCTAssertEqual(Set(clipped.map { "\($0)" }), Set(expected.map { "\($0)" }))
    }

    // MARK: - Estimated heights

    /// An inline image adds only what it makes its line taller by to a block's
    /// height estimate — its line is already counted as text.
    func testAnInlineImageEstimateAddsOnlyTheExtraOverItsLine() throws {
        let editor = try Editor(extensions: starterKit() + [ImageExtension(inline: true)])
        let s = editor.schema
        func doc(withImage: Bool) throws -> Node {
            let paras = try (0 ..< 70).map { _ -> Node in
                var inline: [Node] = [s.text("x")]
                if withImage {
                    inline.append(try s.node("image", ["src": .string("asset://e"), "width": .int(100), "height": .int(100)]))
                }
                return try s.node("paragraph", [:], content: Fragment.from(inline))
            }
            return try s.node("doc", [:], content: Fragment.from(paras))
        }
        let theme = DocumentTheme()
        let far: ClosedRange<CGFloat> = 1_000_000 ... 1_000_001
        let plain = DocumentLayout(doc: try doc(withImage: false), width: 320, theme: theme, realizeWindow: far)
        let pictured = DocumentLayout(doc: try doc(withImage: true), width: 320, theme: theme, realizeWindow: far)
        let e0 = try XCTUnwrap(plain.entries.last), e1 = try XCTUnwrap(pictured.entries.last)
        XCTAssertTrue(e0.estimated && e1.estimated)
        let image = try XCTUnwrap(e1.node.lastChild)
        let box = DocumentLayout.imageDisplaySize(image, natural: nil, available: pictured.contentWidth).height
        let extra = e1.height - e0.height
        XCTAssertGreaterThan(extra, 0)
        XCTAssertLessThan(extra, box - 5, "the image's line was already in the text estimate")
    }
    // MARK: - Attr-index mapping

    /// An atom's own glyph index maps back to the position in front of it,
    /// and the index after it to the position behind it.
    func testTheGlyphOfALeadingAtomMapsToThePositionBeforeIt() throws {
        let block = try XCTUnwrap(try leadingImageLayout().blocks.first)
        XCTAssertEqual(block.segments.first?.attrLen, 1, "precondition: the image is a one-character atom")
        XCTAssertEqual(block.docPos(forAttrIndex: 0), 1)
        XCTAssertEqual(block.docPos(forAttrIndex: 1), 2)
    }

    /// No UTF-16 index — even one inside a ZWJ sequence's last scalar — maps
    /// past the end of its block.
    func testAnIndexInsideAZWJSequenceStaysInsideTheBlock() throws {
        let view = try paragraphs(["a\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"])
        let block = try XCTUnwrap(view.ensureLayout().blocks.first)
        XCTAssertEqual(block.contentEnd - block.contentStart, 2, "one letter and one family emoji")
        for i in 0 ... block.attributed.length {
            let pos = block.docPos(forAttrIndex: i)
            XCTAssertGreaterThanOrEqual(pos, block.contentStart, "index \(i)")
            XCTAssertLessThanOrEqual(pos, block.contentEnd, "index \(i)")
        }
    }

    // MARK: - Pointer selection

    private func pointer(_ view: EditorTextView) -> KillMouseSelection {
        let pointer = KillMouseSelection()
        pointer.anchorAtPoint = { view.mouseSelectionAnchor(at: $0) }
        return pointer
    }

    private func point(_ view: EditorTextView, _ pos: Int, dx: CGFloat = 0) -> CGPoint {
        let caret = view.caretRect(for: DocTextPosition(pos))
        return CGPoint(x: caret.midX + dx, y: caret.midY)
    }

    /// A double-click drag that stays inside the word it started on selects
    /// that word forwards: the anchor stays at the word's start.
    func testADoubleClickDragWithinTheWordKeepsItForwards() throws {
        let view = try paragraphs(["hello world"])
        let pointer = pointer(view), touch = KillPointerTouch(), event = KillPointerEvent()
        touch.clicks = 2
        touch.point = point(view, 3)
        pointer.touchesBegan([touch], with: event)
        view.handleMouseSelection(pointer)
        XCTAssertEqual(view.editor.state.selection.anchor, 1)
        XCTAssertEqual(view.editor.state.selection.head, 6)
        touch.point = point(view, 2)
        pointer.touchesMoved([touch], with: event)
        view.handleMouseSelection(pointer)
        XCTAssertEqual(view.editor.state.selection.anchor, 1)
        XCTAssertEqual(view.editor.state.selection.head, 6)
    }

    /// Double-clicking the first letter of a word that directly follows another
    /// (no space between them) selects the word clicked, not the one before.
    func testADoubleClickAtAWordThatAbutsAnotherSelectsTheOneClicked() throws {
        let view = try paragraphs(["hello\u{65E5}\u{672C}\u{8A9E}"])  // hello + 日本語
        let tokenizer = view.tokenizer
        let fwd = UITextDirection(rawValue: UITextStorageDirection.forward.rawValue)
        let after = try XCTUnwrap(tokenizer.rangeEnclosingPosition(DocTextPosition(6), with: .word, inDirection: fwd) as? DocTextRange)
        XCTAssertEqual(after.from, 6, "precondition: the CJK run is a word of its own")
        let pointer = pointer(view), touch = KillPointerTouch(), event = KillPointerEvent()
        touch.clicks = 2
        let caret = view.caretRect(for: DocTextPosition(6))
        touch.point = CGPoint(x: caret.midX + 2, y: caret.midY)   // left half of the first CJK glyph
        pointer.touchesBegan([touch], with: event)
        XCTAssertEqual(pointer.anchor, 6)
        view.handleMouseSelection(pointer)
        XCTAssertEqual(view.editor.state.selection.from, after.from)
        XCTAssertEqual(view.editor.state.selection.to, after.to)
    }

    // MARK: - Marked text

    /// Text a collaborator inserts right at the start of an IME composition is
    /// theirs, not part of the composition.
    func testAnInsertionAtTheStartOfMarkedTextStaysOutsideIt() throws {
        let view = try paragraphs([""])
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        let before = try XCTUnwrap(view.markedTextRange as? DocTextRange)
        XCTAssertEqual(before.from, 1); XCTAssertEqual(before.to, 3)
        let tr = view.editor.state.tr
        try tr.insertText("X", 1)
        view.editor.dispatch(tr)
        let after = try XCTUnwrap(view.markedTextRange as? DocTextRange)
        XCTAssertEqual(after.from, 2)
        XCTAssertEqual(after.to, 4)
        XCTAssertEqual(view.text(in: after), "ni")
    }
    // MARK: - Image store

    private func squarePNG(_ side: CGFloat) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }.pngData()!
    }

    /// Over budget, the store lets go of the bitmap drawn *longest* ago — not
    /// the one it has just decoded, nor one drawn since.
    func testOverBudgetTheLeastRecentlyUsedBitmapIsTheOneDropped() throws {
        let schema = try Editor(extensions: fullKit()).schema
        var asks: [String: Int] = [:]
        let bytes = squarePNG(200)
        let store = DocumentImageStore(loads: ImageLoadTasks())
        store.maxPointWidth = 300
        store.displayScale = 2
        store.dataProvider = { node in
            asks[node.attrs["src"]?.stringValue ?? "", default: 0] += 1
            return bytes
        }
        let a = try schema.node("image", ["src": .string("asset://a")])
        let b = try schema.node("image", ["src": .string("asset://b")])
        let c = try schema.node("image", ["src": .string("asset://c")])
        _ = store.image(for: a)
        let one = store.debugByteCost
        XCTAssertGreaterThan(one, 0)
        store.byteBudget = 2 * one
        _ = store.image(for: b)
        _ = store.image(for: a)          // a is now more recent than b
        _ = store.image(for: c)          // over budget: b goes
        XCTAssertEqual(store.debugEntryCount, 2)
        _ = store.image(for: a)
        _ = store.image(for: c)
        XCTAssertEqual(asks["asset://a"], 1, "a was drawn recently and kept")
        XCTAssertEqual(asks["asset://c"], 1, "c was just decoded and kept")
        _ = store.image(for: b)
        XCTAssertEqual(asks["asset://b"], 2, "b was the least recently used, so it was dropped")
    }
}
#endif

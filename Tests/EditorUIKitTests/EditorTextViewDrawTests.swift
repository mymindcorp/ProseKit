#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

/// `draw(_:)` — the paint pass itself, rather than the layout it paints from.
///
/// Each branch is checked by rendering the view twice, with the feature off and
/// on, and requiring the pixels to differ: that the branch ran *and* put
/// something on screen. `PaintRealizeTests` covers what `realize` produces;
/// this covers the overlays `draw` adds on top of it.
@MainActor
final class EditorTextViewDrawTests: XCTestCase {
    private func makeView(_ build: (Schema) throws -> [Node]) throws -> EditorTextView {
        let editor = try Editor(extensions: fullKit())
        editor.setContent(try editor.schema.node("doc", [:], content: Fragment.from(build(editor.schema))))
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 400)
        view.layoutIfNeeded()
        _ = view.ensureLayout()
        return view
    }

    private func paragraphs(_ lines: [String]) throws -> EditorTextView {
        try makeView { s in
            try lines.map { line in
                try s.node("paragraph", [:], content: Fragment.from(line.isEmpty ? [] : [s.text(line)]))
            }
        }
    }

    /// Render the view through `draw(_:)` and return its raw pixels.
    private func pixels(_ view: EditorTextView) -> Data {
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
        let image = renderer.image { _ in view.draw(view.bounds) }
        return image.pngData() ?? Data()
    }

    private func assertPaintChanges(_ view: EditorTextView,
                                    _ message: String,
                                    file: StaticString = #filePath, line: UInt = #line,
                                    _ enable: () throws -> Void) rethrows {
        let before = pixels(view)
        XCTAssertFalse(before.isEmpty, "the baseline render produced no image", file: file, line: line)
        try enable()
        let after = pixels(view)
        XCTAssertNotEqual(before, after, message, file: file, line: line)
    }

    // MARK: - Placeholder

    func testThePlaceholderIsPaintedOnlyForAnEmptyDocument() throws {
        let view = try paragraphs([""])
        assertPaintChanges(view, "the placeholder was drawn") {
            view.placeholder = "Write something…"
        }
    }

    func testThePlaceholderIsSuppressedOnceThereIsText() throws {
        let view = try paragraphs([""])
        view.placeholder = "Write something…"
        let empty = pixels(view)

        // The same placeholder, but the document is no longer empty.
        view.editor.dispatch(view.editor.state.tr.setSelection(
            TextSelection.create(view.editor.doc, 1)))
        view.insertText("a")
        _ = view.ensureLayout()
        let typed = pixels(view)
        XCTAssertNotEqual(empty, typed)

        // And with the placeholder cleared the painted result is the same, which
        // it would not be if the placeholder were still being drawn.
        let withPlaceholder = pixels(view)
        view.placeholder = nil
        XCTAssertEqual(withPlaceholder, pixels(view), "no placeholder is drawn over real text")
    }

    func testAnEmptyPlaceholderStringPaintsNothing() throws {
        let view = try paragraphs([""])
        let before = pixels(view)
        view.placeholder = ""
        XCTAssertEqual(before, pixels(view))
    }

    // MARK: - Selection & decorations

    func testASearchHighlightIsPainted() throws {
        let view = try paragraphs(["find the needle here"])
        assertPaintChanges(view, "the search match was tinted") {
            view.editor.setSearch("needle")
            _ = view.ensureLayout()
        }
    }

    func testAColumnResizeInProgressTintsTheColumn() throws {
        let view = try makeView { s in
            func cell(_ text: String) throws -> Node {
                try s.node("tableCell", [:], content: Fragment.from([
                    try s.node("paragraph", [:], content: Fragment.from([s.text(text)])),
                ]))
            }
            return [try s.node("table", [:], content: Fragment.from([
                try s.node("tableRow", [:], content: Fragment.from([try cell("A"), try cell("B")])),
            ]))]
        }
        let table = try XCTUnwrap(view.ensureLayout().tables.first)
        let border = CGPoint(x: table.borderX(after: 0), y: (table.top + table.bottom) / 2)

        assertPaintChanges(view, "the column being dragged is tinted") {
            view.beginColumnResize(at: border)
            view.updateColumnResize(to: CGPoint(x: border.x + 30, y: border.y))
            _ = view.ensureLayout()
        }
        view.endColumnResize()
    }

    // MARK: - Spelling

    func testMisspellingsAreUnderlined() throws {
        let view = try paragraphs(["thiss worrd is wrogn"])
        view.spellCheckingEnabled = true
        assertPaintChanges(view, "the misspellings got their dashed underline") {
            view.runSpellPassIfNeeded()
            _ = view.ensureLayout()
        }
    }

    func testSpellingUnderlinesAreSuppressedWhenCheckingIsOff() throws {
        let view = try paragraphs(["thiss worrd is wrogn"])
        view.spellCheckingEnabled = false
        let before = pixels(view)
        view.runSpellPassIfNeeded()
        XCTAssertEqual(before, pixels(view), "nothing is underlined with checking off")
    }

    func testTheSpellCacheSurvivesAnEditWithoutARecheck() throws {
        let view = try paragraphs(["thiss worrd is wrogn"])
        view.spellCheckingEnabled = true
        view.runSpellPassIfNeeded()
        let underlined = pixels(view)

        // Type at the very end: the cached underlines shift through the mapping
        // rather than being dropped, so the earlier misspellings stay marked.
        view.editor.dispatch(view.editor.state.tr.setSelection(
            TextSelection.create(view.editor.doc, view.editor.doc.content.size - 1)))
        view.insertText("!")
        _ = view.ensureLayout()

        XCTAssertNotEqual(pixels(view), underlined, "the document changed")
        // With the cache mapped rather than cleared, a redundant pass is a no-op.
        let afterEdit = pixels(view)
        view.runSpellPassIfNeeded()
        XCTAssertEqual(afterEdit, pixels(view), "the mapped cache was still valid")
    }

    // MARK: - Marked (IME) text

    func testMarkedTextGetsASolidUnderline() throws {
        let view = try paragraphs(["ab"])
        view.editor.dispatch(view.editor.state.tr.setSelection(
            TextSelection.create(view.editor.doc, 3)))

        assertPaintChanges(view, "composing text is underlined") {
            view.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0))
            _ = view.ensureLayout()
        }
        view.unmarkText()
    }

    // MARK: - Collaboration cursors

    func testACollapsedRemoteCursorPaintsACaretBar() throws {
        let view = try paragraphs(["hello world"])
        assertPaintChanges(view, "the remote caret was drawn") {
            view.editor.setCollabCursor(id: "a", anchor: 4, head: 4,
                                        color: "#FF00FF", label: "Ada")
            _ = view.ensureLayout()
        }
    }

    func testARemoteSelectionPaintsAHighlightBand() throws {
        let view = try paragraphs(["hello world"])
        view.editor.setCollabCursor(id: "a", anchor: 4, head: 4, color: "#FF00FF", label: "Ada")
        _ = view.ensureLayout()
        let caretOnly = pixels(view)

        // Widen it into a selection: the band is painted as well as the bar.
        view.editor.setCollabCursor(id: "a", anchor: 1, head: 9, color: "#FF00FF", label: "Ada")
        _ = view.ensureLayout()
        XCTAssertNotEqual(caretOnly, pixels(view), "the selection band was added")
    }

    func testARemoteCursorWithAnUnreadableColorIsSkipped() throws {
        let view = try paragraphs(["hello world"])
        let before = pixels(view)
        view.editor.setCollabCursor(id: "a", anchor: 1, head: 9, color: "not a color", label: "Ada")
        _ = view.ensureLayout()
        XCTAssertEqual(before, pixels(view), "nothing is drawn for a cursor we can't color")
    }

    // MARK: - Block reordering

    func testBlockHandlesArePaintedWhenReorderingIsOn() throws {
        let view = try paragraphs(["one", "two", "three"])
        assertPaintChanges(view, "the grip dots were drawn") {
            view.blockReorderingEnabled = true
        }
    }

    func testTheDropIndicatorIsPaintedDuringADrag() throws {
        let view = try paragraphs(["one", "two", "three"])
        view.blockReorderingEnabled = true
        let handles = pixels(view)

        // Start a drag on the first block and hover a non-adjacent gap.
        let layout = view.ensureLayout()
        let pan = DrawFakePan()
        pan.point = CGPoint(x: 4, y: layout.blocks[0].frame.midY - view.contentOffsetY)
        pan.fakeState = .began
        view.handleBlockDrag(pan)
        pan.point = CGPoint(x: 4, y: layout.height - 1 - view.contentOffsetY)
        pan.fakeState = .changed
        view.handleBlockDrag(pan)

        XCTAssertNotEqual(handles, pixels(view), "the drop bar and the active grip were drawn")

        pan.fakeState = .cancelled
        view.handleBlockDrag(pan)
    }

    func testBlockHandlesAreNotPaintedWhenReadOnly() throws {
        let view = try paragraphs(["one", "two"])
        view.blockReorderingEnabled = true
        view.isEditable = false
        let readOnly = pixels(view)

        view.blockReorderingEnabled = false
        XCTAssertEqual(readOnly, pixels(view), "a read-only document draws no handles either way")
    }

    // MARK: - Scrolled viewport

    func testOnlyTheVisibleWindowIsPainted() throws {
        let view = try paragraphs((0 ..< 60).map { "line \($0)" })
        let top = pixels(view)
        view.contentOffsetY = 600
        let scrolled = pixels(view)
        XCTAssertNotEqual(top, scrolled, "the paint follows the scroll offset")
    }
}

/// A pan recognizer whose state and location the test drives.
@MainActor
private final class DrawFakePan: UIPanGestureRecognizer {
    var point: CGPoint = .zero
    var fakeState: UIGestureRecognizer.State = .possible
    override func location(in view: UIView?) -> CGPoint { point }
    override var state: UIGestureRecognizer.State {
        get { fakeState }
        set { fakeState = newValue }
    }
}
#endif

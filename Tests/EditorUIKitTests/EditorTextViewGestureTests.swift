#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import EditorStateKit
import SchemaKit
import EditorMath
@testable import EditorUIKit

/// Fake recognizers: `state` and `location(in:)` are read-only on the real
/// classes, so each gesture under test gets a subclass whose values the test
/// scripts. This drives the wiring the real gestures use — the `.began`-only
/// guards, the view→document point conversion, and each handler's state
/// machine — without needing synthesized touches.
@MainActor
private final class FakeTap: UITapGestureRecognizer {
    var point: CGPoint = .zero
    var modifiers: UIKeyModifierFlags = []
    override func location(in view: UIView?) -> CGPoint { point }
    override var modifierFlags: UIKeyModifierFlags { modifiers }
}

@MainActor
private final class FakePan: UIPanGestureRecognizer {
    var point: CGPoint = .zero
    var fakeState: UIGestureRecognizer.State = .possible
    override func location(in view: UIView?) -> CGPoint { point }
    override var state: UIGestureRecognizer.State {
        get { fakeState }
        set { fakeState = newValue }
    }
}

@MainActor
private final class FakeLongPress: UILongPressGestureRecognizer {
    var point: CGPoint = .zero
    var fakeState: UIGestureRecognizer.State = .possible
    override func location(in view: UIView?) -> CGPoint { point }
    override var state: UIGestureRecognizer.State {
        get { fakeState }
        set { fakeState = newValue }
    }
}

@MainActor
final class EditorTextViewGestureTests: XCTestCase {
    // MARK: - Fixtures

    private func makeView(_ build: (Schema) throws -> [Node]) throws -> EditorTextView {
        let editor = try Editor(extensions: fullKit())
        editor.setContent(try editor.schema.node("doc", [:], content: Fragment.from(build(editor.schema))))
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        view.blockReorderingEnabled = true // the drag handles are opt-in
        view.mathRenderer = makeMathRenderer()
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

    /// A view point for a document point (the inverse of the view's `docPoint`).
    private func viewPoint(_ view: EditorTextView, _ docPoint: CGPoint) -> CGPoint {
        CGPoint(x: docPoint.x, y: docPoint.y + view.contentOffsetY)
    }

    // MARK: - Block drag

    func testBlockDragMovesTheBlockOnEnd() throws {
        let view = try paragraphs(["one", "two", "three"])
        let layout = view.ensureLayout()
        let pan = FakePan()

        // Grab the first block by its handle.
        let firstBlock = layout.blocks[0]
        let handle = CGPoint(x: 4, y: firstBlock.frame.midY)
        pan.point = viewPoint(view, handle)
        pan.fakeState = .began
        view.handleBlockDrag(pan)

        // Drag past the last block and let go.
        pan.point = viewPoint(view, CGPoint(x: 4, y: layout.height - 1))
        pan.fakeState = .changed
        view.handleBlockDrag(pan)

        pan.fakeState = .ended
        view.handleBlockDrag(pan)

        let order = (0 ..< view.editor.doc.childCount).map { view.editor.doc.child($0).textContent }
        XCTAssertEqual(order, ["two", "three", "one"], "the dragged block landed at the end")
    }

    func testBlockDragBeginningOffAHandleDoesNothing() throws {
        let view = try paragraphs(["one", "two"])
        let pan = FakePan()
        // The middle of the text, nowhere near a drag handle.
        pan.point = viewPoint(view, CGPoint(x: 160, y: view.ensureLayout().blocks[0].frame.midY))
        pan.fakeState = .began
        view.handleBlockDrag(pan)
        pan.fakeState = .ended
        view.handleBlockDrag(pan)

        let order = (0 ..< view.editor.doc.childCount).map { view.editor.doc.child($0).textContent }
        XCTAssertEqual(order, ["one", "two"], "no drag was ever started")
    }

    func testBlockDragCancellationLeavesTheDocumentAlone() throws {
        let view = try paragraphs(["one", "two", "three"])
        let layout = view.ensureLayout()
        let pan = FakePan()

        pan.point = viewPoint(view, CGPoint(x: 4, y: layout.blocks[0].frame.midY))
        pan.fakeState = .began
        view.handleBlockDrag(pan)
        pan.point = viewPoint(view, CGPoint(x: 4, y: layout.height - 1))
        pan.fakeState = .changed
        view.handleBlockDrag(pan)
        pan.fakeState = .cancelled
        view.handleBlockDrag(pan)

        let order = (0 ..< view.editor.doc.childCount).map { view.editor.doc.child($0).textContent }
        XCTAssertEqual(order, ["one", "two", "three"], "a cancelled drag moves nothing")
    }

    func testBlockDragChangeWithoutABeginIsIgnored() throws {
        let view = try paragraphs(["one", "two"])
        let pan = FakePan()
        pan.point = viewPoint(view, CGPoint(x: 4, y: 10))
        pan.fakeState = .changed // no .began first
        view.handleBlockDrag(pan)
        pan.fakeState = .ended
        view.handleBlockDrag(pan)

        let order = (0 ..< view.editor.doc.childCount).map { view.editor.doc.child($0).textContent }
        XCTAssertEqual(order, ["one", "two"])
    }

    // MARK: - Triple tap

    func testTripleTapSelectsTheWholeParagraph() throws {
        let view = try paragraphs(["hello there", "second"])
        let block = view.ensureLayout().blocks[0]
        let tap = FakeTap()
        tap.point = viewPoint(view, CGPoint(x: block.frame.midX, y: block.frame.midY))
        view.handleTripleTap(tap)

        let sel = view.editor.state.selection
        XCTAssertEqual(view.editor.doc.textBetween(sel.from, sel.to), "hello there")
    }

    func testTripleTapBelowTheDocumentSelectsNothingNew() throws {
        let view = try paragraphs(["hello"])
        let before = view.editor.state.selection
        let tap = FakeTap()
        tap.point = viewPoint(view, CGPoint(x: 10, y: view.ensureLayout().height + 500))
        view.handleTripleTap(tap)
        // Far below the document there is no paragraph to select; the handler
        // returns without touching the selection.
        XCTAssertEqual(view.editor.state.selection.from, before.from)
    }

    // MARK: - Trailing tap

    func testTrailingTapAppendsAParagraphAfterACodeBlock() throws {
        let view = try makeView { s in
            [try s.node("codeBlock", [:], content: Fragment.from([s.text("let x = 1")]))]
        }
        let tap = FakeTap()
        tap.point = viewPoint(view, CGPoint(x: 10, y: view.ensureLayout().height + 20))
        view.handleTrailingTap(tap)

        XCTAssertEqual(view.editor.doc.lastChild?.type.name, "paragraph",
                       "the tap below a code block escaped it with a new paragraph")
    }

    func testTrailingTapAfterAParagraphDoesNotAppend() throws {
        let view = try paragraphs(["only"])
        let before = view.editor.doc.childCount
        let tap = FakeTap()
        tap.point = viewPoint(view, CGPoint(x: 10, y: view.ensureLayout().height + 20))
        view.handleTrailingTap(tap)
        XCTAssertEqual(view.editor.doc.childCount, before,
                       "a document already ending in a paragraph needs no extra one")
    }

    // MARK: - Link tap

    func testLinkTapHandsTheLinkToTheHost() throws {
        let view = try makeView { s in
            let link = s.marks["link"]!
            return [try s.node("paragraph", [:], content: Fragment.from([
                s.text("go", [link.create(["href": .string("https://example.com")])]),
            ]))]
        }
        var clicked: String?
        view.onLinkClick = { click in clicked = click.attrs["href"]?.stringValue }

        let block = view.ensureLayout().blocks[0]
        let tap = FakeTap()
        tap.point = viewPoint(view, CGPoint(x: block.frame.minX + 4, y: block.frame.midY))
        view.handleLinkTap(tap)

        XCTAssertEqual(clicked, "https://example.com")
    }

    func testLinkTapOffALinkNotifiesNobody() throws {
        let view = try paragraphs(["plain text"])
        var clicked = false
        view.onLinkClick = { _ in clicked = true }

        let block = view.ensureLayout().blocks[0]
        let tap = FakeTap()
        tap.point = viewPoint(view, CGPoint(x: block.frame.midX, y: block.frame.midY))
        view.handleLinkTap(tap)
        XCTAssertFalse(clicked)
    }

    // MARK: - Disclosure tap

    func testDisclosureTapTogglesTheDetailsBlock() throws {
        let view = try makeView { s in
            [try s.node("details", ["open": .bool(true)], content: Fragment.from([
                try s.node("detailsSummary", [:], content: Fragment.from([s.text("Summary")])),
                try s.node("detailsContent", [:], content: Fragment.from([
                    try s.node("paragraph", [:], content: Fragment.from([s.text("body")])),
                ])),
            ]))]
        }
        let layout = view.ensureLayout()
        let hit = try XCTUnwrap(layout.disclosures.first, "the details block draws a disclosure triangle")

        let tap = FakeTap()
        tap.point = viewPoint(view, CGPoint(x: hit.rect.midX, y: hit.rect.midY))
        view.handleDisclosureTap(tap)

        XCTAssertEqual(view.editor.doc.child(0).attrs["open"]?.boolValue, false, "the details block closed")
    }

    func testDisclosureTapOffTheTriangleDoesNothing() throws {
        let view = try makeView { s in
            [try s.node("details", ["open": .bool(true)], content: Fragment.from([
                try s.node("detailsSummary", [:], content: Fragment.from([s.text("Summary")])),
                try s.node("detailsContent", [:], content: Fragment.from([
                    try s.node("paragraph", [:], content: Fragment.from([s.text("body")])),
                ])),
            ]))]
        }
        let tap = FakeTap()
        tap.point = viewPoint(view, CGPoint(x: 300, y: 400))
        view.handleDisclosureTap(tap)
        XCTAssertEqual(view.editor.doc.child(0).attrs["open"]?.boolValue, true, "still open")
    }

    // MARK: - Image long press

    private func imageView() throws -> EditorTextView {
        try makeView { s in
            [try s.node("image", ["src": .string("https://example.com/a.png"),
                                  "width": .int(100), "height": .int(80)])]
        }
    }

    func testImageLongPressActivatesOnBeganOnly() throws {
        let view = try imageView()
        var activations = 0
        view.onActivateImage = { _, _ in activations += 1 }

        let rect = try XCTUnwrap(view.ensureLayout().imageRects.first).rect
        let press = FakeLongPress()
        press.point = viewPoint(view, CGPoint(x: rect.midX, y: rect.midY))

        press.fakeState = .changed
        view.handleImageLongPress(press)
        XCTAssertEqual(activations, 0, "only .began activates")

        press.fakeState = .began
        view.handleImageLongPress(press)
        XCTAssertEqual(activations, 1)
        XCTAssertTrue(view.editor.state.selection is NodeSelection, "the image is selected for the host")
    }

    func testImageLongPressOffAnImageDoesNothing() throws {
        let view = try imageView()
        var activations = 0
        view.onActivateImage = { _, _ in activations += 1 }

        let press = FakeLongPress()
        press.fakeState = .began
        press.point = viewPoint(view, CGPoint(x: 10, y: view.ensureLayout().height + 200))
        view.handleImageLongPress(press)
        XCTAssertEqual(activations, 0)
    }

    // MARK: - Math tap

    func testMathTapActivatesTheFormula() throws {
        let view = try makeView { s in
            [try s.node("paragraph", [:], content: Fragment.from([
                try s.node("inlineMath", ["latex": .string("x^2")]),
            ]))]
        }
        var activated: Int?
        view.onActivateMath = { _, pos in activated = pos }

        let hit = try XCTUnwrap(view.ensureLayout().mathTargets.first)
        let tap = FakeTap()
        tap.point = viewPoint(view, CGPoint(x: hit.rect.midX, y: hit.rect.midY))
        view.handleMathTap(tap)
        XCTAssertNotNil(activated)
    }

    // MARK: - Image resize

    func testImageResizeDragSetsTheWidth() throws {
        let view = try imageView()
        view.imageResizingEnabled = true
        let rect = try XCTUnwrap(view.ensureLayout().imageRects.first)

        let pan = FakePan()
        pan.point = viewPoint(view, CGPoint(x: rect.rect.maxX - 4, y: rect.rect.maxY - 4))
        pan.fakeState = .began
        view.handleImageResize(pan)

        // Drag the handle out to a wider width.
        pan.point = viewPoint(view, CGPoint(x: rect.rect.minX + 200, y: rect.rect.maxY))
        pan.fakeState = .changed
        view.handleImageResize(pan)

        pan.fakeState = .ended
        view.handleImageResize(pan)

        let width = try XCTUnwrap(view.editor.doc.child(0).attrs["width"]?.intValue)
        XCTAssertGreaterThan(width, 100, "the drag widened the image")
    }

    func testImageResizeBeginningOffTheHandleIsIgnored() throws {
        let view = try imageView()
        view.imageResizingEnabled = true
        let before = view.editor.doc.child(0).attrs["width"]?.intValue

        let pan = FakePan()
        pan.point = viewPoint(view, CGPoint(x: 5, y: 5)) // top-left, not the grip
        pan.fakeState = .began
        view.handleImageResize(pan)
        pan.point = viewPoint(view, CGPoint(x: 250, y: 60))
        pan.fakeState = .changed
        view.handleImageResize(pan)

        XCTAssertEqual(view.editor.doc.child(0).attrs["width"]?.intValue, before, "unchanged")
    }

    // MARK: - Column resize (mouse drag)

    private func tableView() throws -> EditorTextView {
        try makeView { s in
            func cell(_ text: String) throws -> Node {
                try s.node("tableCell", [:], content: Fragment.from([
                    try s.node("paragraph", [:], content: Fragment.from([s.text(text)])),
                ]))
            }
            return [try s.node("table", [:], content: Fragment.from([
                try s.node("tableRow", [:], content: Fragment.from([try cell("A"), try cell("B")])),
            ]))]
        }
    }

    func testColumnResizeDragChangesTheColumnWidth() throws {
        let view = try tableView()
        let table = try XCTUnwrap(view.ensureLayout().tables.first)
        let borderX = table.borderX(after: 0)
        let midY = (table.top + table.bottom) / 2

        let pan = FakePan()
        pan.point = viewPoint(view, CGPoint(x: borderX, y: midY))
        pan.fakeState = .began
        view.handleMouseDrag(pan)

        pan.point = viewPoint(view, CGPoint(x: borderX + 40, y: midY))
        pan.fakeState = .changed
        view.handleMouseDrag(pan)

        pan.fakeState = .ended
        view.handleMouseDrag(pan)

        let moved = try XCTUnwrap(view.ensureLayout().tables.first).borderX(after: 0)
        XCTAssertGreaterThan(moved, borderX, "the column border moved right")
    }

    func testColumnResizeStartedOffABorderDoesNothing() throws {
        let view = try tableView()
        let table = try XCTUnwrap(view.ensureLayout().tables.first)
        let borderX = table.borderX(after: 0)

        let pan = FakePan()
        pan.point = viewPoint(view, CGPoint(x: borderX - 30, y: (table.top + table.bottom) / 2))
        pan.fakeState = .began
        view.handleMouseDrag(pan)
        pan.point = viewPoint(view, CGPoint(x: borderX + 60, y: (table.top + table.bottom) / 2))
        pan.fakeState = .changed
        view.handleMouseDrag(pan)
        pan.fakeState = .ended
        view.handleMouseDrag(pan)

        XCTAssertEqual(try XCTUnwrap(view.ensureLayout().tables.first).borderX(after: 0), borderX,
                       "no border was grabbed, so nothing resized")
    }

    // MARK: - gestureRecognizerShouldBegin

    func testColumnResizeBeginsOnlyOnABorder() throws {
        let view = try tableView()
        let recognizer = try XCTUnwrap(view.columnResizeRecognizer)
        let table = try XCTUnwrap(view.ensureLayout().tables.first)
        let midY = (table.top + table.bottom) / 2

        XCTAssertTrue(view.gestureRecognizerShouldBegin(recognizer) ||
                      view.columnBorderHit(at: CGPoint(x: table.borderX(after: 0), y: midY)) != nil,
                      "a border is hittable")
        // The real recognizer reports (0,0) — the top-left corner is not a border.
        XCTAssertFalse(view.gestureRecognizerShouldBegin(recognizer),
                       "at the origin there is no column border to grab")
    }

    func testDisclosureTapBeginsOnlyOverATriangle() throws {
        let view = try paragraphs(["no details here"])
        let recognizer = try XCTUnwrap(view.disclosureTapRecognizer)
        XCTAssertFalse(view.gestureRecognizerShouldBegin(recognizer),
                       "a document with no details block never claims the tap")
    }

    func testMathTapIsClaimedOnlyWhenAHostWantsIt() throws {
        let view = try makeView { s in
            [try s.node("paragraph", [:], content: Fragment.from([
                try s.node("inlineMath", ["latex": .string("x^2")]),
            ]))]
        }
        let recognizer = try XCTUnwrap(view.mathTapRecognizer)
        // No handler installed: the tap should place a caret instead.
        view.onActivateMath = nil
        XCTAssertFalse(view.gestureRecognizerShouldBegin(recognizer))
    }

    func testUnknownRecognizerFallsThroughToSuper() throws {
        let view = try paragraphs(["text"])
        let stray = UITapGestureRecognizer()
        XCTAssertTrue(view.gestureRecognizerShouldBegin(stray),
                      "a recognizer the editor doesn't own is left to UIView")
    }
}
#endif

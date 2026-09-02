#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

/// Ticking a task off must not scroll. The editor reveals the caret after a
/// state update while it is focused, and a checkbox toggle is a state update —
/// so with the caret parked at the top of a long list, every tap far below it
/// jumped the page back to the caret. Only an update that moves the selection
/// (or asks, via `scrollIntoView`) may scroll.
@MainActor
final class CheckboxScrollTests: XCTestCase {

    /// A focused editor as the scroll content, caret at the top, scrolled well
    /// past it — the shape of "reading down a list you started editing at the
    /// top of".
    private func makeScrolledList() throws -> (scroll: UIScrollView, view: EditorTextView, window: UIWindow) {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        let items = try (0..<80).map { i in
            try s.node("taskItem", ["checked": .bool(false)], content: Fragment.from([
                try s.node("paragraph", [:], content: Fragment.from([s.text("task number \(i)")])),
            ]))
        }
        editor.setContent(try s.node("doc", [:], content: Fragment.from([
            try s.node("paragraph", [:], content: Fragment.from([s.text("Things to do")])),
            try s.node("taskList", [:], content: Fragment.from(items)),
        ])))

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        let scroll = UIScrollView(frame: window.bounds)
        // Deterministic insets: without this, the simulated device's safe
        // area feeds adjustedContentInset and shifts every expected offset.
        scroll.contentInsetAdjustmentBehavior = .never
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 400)
        scroll.addSubview(view)
        window.addSubview(scroll)
        window.makeKeyAndVisible()

        let docHeight = view.documentHeight
        XCTAssertGreaterThan(docHeight, 1200, "list should be far taller than the viewport")
        view.frame = CGRect(x: 0, y: 0, width: 320, height: docHeight)
        scroll.contentSize = CGSize(width: 320, height: docHeight)
        XCTAssertTrue(view.becomeFirstResponder())

        // Caret at the very top, then the reader scrolls down.
        view.editor.dispatch(view.editor.state.tr.setSelection(TextSelection.create(view.editor.doc, 1)))
        scroll.contentOffset = CGPoint(x: 0, y: 600)
        XCTAssertEqual(scroll.contentOffset.y, 600, accuracy: 0.5)
        return (scroll, view, window)
    }

    /// The position of a task item whose checkbox sits inside the window
    /// `[offsetY, offsetY + 400]` of the document.
    private func visibleTaskItem(_ view: EditorTextView, scrolledTo offsetY: CGFloat) throws -> Int {
        let boxes = view.ensureLayout().checkboxes
        let box = try XCTUnwrap(boxes.first { $0.rect.minY > offsetY + 100 && $0.rect.maxY < offsetY + 300 },
                                "a checkbox should be on screen at the scrolled offset")
        return box.pos
    }

    func testTogglingACheckboxBelowTheCaretDoesNotScroll() throws {
        let (scroll, view, _) = try makeScrolledList()
        let pos = try visibleTaskItem(view, scrolledTo: 600)

        view.toggleCheckboxForTesting(at: pos)

        XCTAssertEqual(view.editor.doc.nodeAt(pos)?.attrs["checked"]?.boolValue, true, "the item was ticked")
        XCTAssertEqual(scroll.contentOffset.y, 600, accuracy: 0.5,
                       "ticking a task off must leave the page where the reader put it")
    }

    func testUntogglingACheckboxBelowTheCaretDoesNotScroll() throws {
        let (scroll, view, _) = try makeScrolledList()
        let pos = try visibleTaskItem(view, scrolledTo: 600)

        view.toggleCheckboxForTesting(at: pos)
        XCTAssertEqual(scroll.contentOffset.y, 600, accuracy: 0.5)
        view.toggleCheckboxForTesting(at: pos)

        XCTAssertEqual(view.editor.doc.nodeAt(pos)?.attrs["checked"]?.boolValue, false, "the item was unticked")
        XCTAssertEqual(scroll.contentOffset.y, 600, accuracy: 0.5,
                       "unticking must leave the page alone too")
    }

    /// An update that leaves the selection where it was but asks for the caret
    /// (`scrollIntoView`) still reveals it — commands rely on that.
    func testScrollIntoViewStillRevealsAnUnmovedCaret() throws {
        let (scroll, view, _) = try makeScrolledList()

        view.editor.dispatch(view.editor.state.tr.scrollIntoView())

        let caret = try XCTUnwrap(view.caretViewRectForTesting)
        XCTAssertEqual(scroll.contentOffset.y, max(0, caret.minY - 8), accuracy: 1,
                       "an explicit scrollIntoView must still bring the caret back")
    }

    /// Moving the selection still reveals it (the behaviour the checkbox fix
    /// must not take away).
    func testMovingTheSelectionStillReveals() throws {
        let (scroll, view, _) = try makeScrolledList()

        view.editor.dispatch(view.editor.state.tr.setSelection(TextSelection.create(view.editor.doc, 3)))

        let caret = try XCTUnwrap(view.caretViewRectForTesting)
        XCTAssertEqual(scroll.contentOffset.y, max(0, caret.minY - 8), accuracy: 1,
                       "a selection change must still scroll the caret into view")
    }
}
#endif

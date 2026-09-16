#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

/// Regressions for focus, Escape, and pointer-selection behavior in note hosts.
@MainActor
final class InteractionTriageTests: XCTestCase {
    private func fixture() throws -> (UIWindow, UIScrollView, EditorTextView) {
        let editor = try Editor(extensions: fullKit())
        let paragraphs = try (0..<80).map { i in
            try editor.schema.node("paragraph", [:], content: Fragment.from([
                editor.schema.text("paragraph number \(i)")
            ]))
        }
        editor.setContent(try editor.schema.node("doc", [:], content: Fragment.from(paragraphs)))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        let scroll = UIScrollView(frame: window.bounds)
        scroll.contentInsetAdjustmentBehavior = .never
        let view = EditorTextView(editor: editor)
        view.frame = scroll.bounds
        scroll.addSubview(view)
        window.addSubview(scroll)
        window.makeKeyAndVisible()
        view.frame.size.height = view.documentHeight
        scroll.contentSize = view.frame.size
        return (window, scroll, view)
    }

    func testFirstFocusPreservesScrolledViewport() throws {
        let (window, scroll, view) = try fixture()
        defer { window.isHidden = true }
        scroll.contentOffset.y = 600
        XCTAssertFalse(view.isFirstResponder)
        XCTAssertTrue(view.becomeFirstResponder())
        XCTAssertEqual(scroll.contentOffset.y, 600, accuracy: 0.5, "focus must not move the document under the click")
        let hit = try XCTUnwrap(view.closestPosition(to: CGPoint(x: 70, y: 650)))
        view.selectedTextRange = view.textRange(from: hit, to: hit)
        XCTAssertGreaterThan(view.editor.state.selection.head, 1)
        XCTAssertEqual(scroll.contentOffset.y, 600, accuracy: 0.5)
        scroll.contentOffset.y = 600
        XCTAssertEqual(scroll.contentOffset.y, 600, "scrolling after focus stays put")
    }

    func testEscapeFallsThroughWithoutSelectingAncestors() throws {
        let editor = try Editor(extensions: fullKit())
        let paragraph = try editor.schema.node("paragraph", [:], content: Fragment.from([editor.schema.text("quoted")]))
        let quote = try editor.schema.node("blockquote", [:], content: Fragment.from([paragraph]))
        editor.setContent(try editor.schema.node("doc", [:], content: Fragment.from([quote])))
        let view = EditorTextView(editor: editor)
        editor.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.doc, 3)))
        XCTAssertFalse(view.handle(EditorTextView.KeyEvent(.keyboardEscape)))
        XCTAssertTrue(editor.state.selection is TextSelection)
        XCTAssertEqual(editor.state.selection.head, 3)
        XCTAssertTrue(editor.state.selection.empty)
    }

    func testFirstFocusPreservesPinnedViewportAndClick() throws {
        let (window, scroll, view) = try fixture()
        defer { window.isHidden = true }
        view.frame = CGRect(x: 0, y: 600, width: 320, height: 400)
        scroll.contentOffset.y = 600
        view.contentOffsetY = 600
        XCTAssertTrue(view.becomeFirstResponder())
        XCTAssertEqual(scroll.contentOffset.y, 600, accuracy: 0.5)
        let hit = try XCTUnwrap(view.closestPosition(to: CGPoint(x: 70, y: 50)))
        view.selectedTextRange = view.textRange(from: hit, to: hit)
        XCTAssertGreaterThan(view.editor.state.selection.head, 1)
        XCTAssertEqual(scroll.contentOffset.y, 600, accuracy: 0.5)
    }

    func testNativeRangeScrollsTowardMovingEndpoint() throws {
        let (window, scroll, view) = try fixture()
        defer { window.isHidden = true }
        XCTAssertTrue(view.becomeFirstResponder())
        let anchor = 500
        view.selectedTextRange = DocTextRange(anchor, anchor)
        let before = scroll.contentOffset.y
        XCTAssertGreaterThan(before, 100, "the anchor must be scrolled away from the document top")
        view.selectedTextRange = DocTextRange(1, anchor)
        XCTAssertEqual(view.editor.state.selection.head, 1)
        XCTAssertEqual(view.editor.state.selection.anchor, anchor)
        XCTAssertLessThan(scroll.contentOffset.y, 100, "upward growth reveals the leading endpoint")
        view.selectedTextRange = DocTextRange(1, 900)
        XCTAssertGreaterThan(scroll.contentOffset.y, before, "downward growth does scroll")
    }
    func testNativeRangeKeepsDirectionWhenShrinkingAndCrossingAnchor() throws {
        let (window, _, view) = try fixture()
        defer { window.isHidden = true }
        view.selectedTextRange = DocTextRange(500, 500)
        view.selectedTextRange = DocTextRange(300, 500)
        view.selectedTextRange = DocTextRange(400, 500)
        XCTAssertEqual(view.editor.state.selection.anchor, 500)
        XCTAssertEqual(view.editor.state.selection.head, 400)
        // UIKit may write the same sorted range back during geometry updates.
        view.selectedTextRange = DocTextRange(400, 500)
        XCTAssertEqual(view.editor.state.selection.head, 400)
        view.selectedTextRange = DocTextRange(500, 600)
        XCTAssertEqual(view.editor.state.selection.anchor, 500)
        XCTAssertEqual(view.editor.state.selection.head, 600)
        view.selectedTextRange = DocTextRange(500, 550)
        XCTAssertEqual(view.editor.state.selection.head, 550)
    }

    func testSelectedTextDoesNotStartDragUnlessEnabled() throws {
        let (window, _, view) = try fixture()
        defer { window.isHidden = true }
        view.selectedTextRange = DocTextRange(1, 12)
        let rect = view.caretRect(for: DocTextPosition(5))
        let session = SelectionDragSession(point: CGPoint(x: rect.midX, y: rect.midY))
        let interaction = UIDragInteraction(delegate: view)
        XCTAssertTrue(view.dragInteraction(interaction, itemsForBeginning: session).isEmpty)
        view.textDraggingEnabled = true
        XCTAssertEqual(view.dragInteraction(interaction, itemsForBeginning: session).count, 1)
        view.selectedTextRange = DocTextRange(1, 1)
        XCTAssertTrue(view.dragInteraction(interaction, itemsForBeginning: session).isEmpty)
    }

    func testRefocusingWithOffscreenSelectionDoesNotRevealIt() throws {
        let (window, scroll, view) = try fixture()
        defer { window.isHidden = true }
        XCTAssertTrue(view.becomeFirstResponder())
        view.selectedTextRange = DocTextRange(1, 12)
        let original = view.editor.state.selection
        var focusEvents = 0
        view.onFocus = { focusEvents += 1 }
        for offset: CGFloat in [600, 900] {
            XCTAssertTrue(view.resignFirstResponder())
            scroll.contentOffset.y = offset
            XCTAssertTrue(view.becomeFirstResponder())
            XCTAssertTrue(view.becomeFirstResponder(), "repeated focus should be harmless")
            XCTAssertEqual(scroll.contentOffset.y, offset, accuracy: 0.5)
            XCTAssertTrue(view.editor.state.selection.eq(original))
        }
        XCTAssertEqual(focusEvents, 2, "notify only on an actual focus transition")
    }

    func testSwitchingSelectionHandlesChangesTheActiveEndpoint() throws {
        let (window, _, view) = try fixture()
        defer { window.isHidden = true }
        view.selectedTextRange = DocTextRange(500, 500)
        view.selectedTextRange = DocTextRange(300, 500)
        // Grab the other handle: the former moving end is now stationary.
        view.selectedTextRange = DocTextRange(300, 600)
        XCTAssertEqual(view.editor.state.selection.anchor, 300)
        XCTAssertEqual(view.editor.state.selection.head, 600)
        view.selectedTextRange = DocTextRange(205, 600)
        XCTAssertEqual(view.editor.state.selection.anchor, 600)
        XCTAssertEqual(view.editor.state.selection.head, 205)
        // Hardware extension must continue from the last handle, not jump ends.
        XCTAssertTrue(view.handle(EditorTextView.KeyEvent(.keyboardLeftArrow, modifiers: .shift)))
        XCTAssertEqual(view.editor.state.selection.anchor, 600)
        XCTAssertEqual(view.editor.state.selection.head, 204)
    }

    func testFreshSelectionInsideHighlightReplacesTheOldAnchorWithoutEditing() throws {
        let (window, _, view) = try fixture()
        defer { window.isHidden = true }
        let original = view.editor.doc
        view.selectedTextRange = DocTextRange(500, 500)
        view.selectedTextRange = DocTextRange(300, 500)
        let rect = view.caretRect(for: DocTextPosition(400))
        let session = SelectionDragSession(point: CGPoint(x: rect.midX, y: rect.midY))
        XCTAssertTrue(view.dragInteraction(UIDragInteraction(delegate: view), itemsForBeginning: session).isEmpty)
        // Native selection starts a fresh caret, then extends from that point.
        view.selectedTextRange = DocTextRange(400, 400)
        view.selectedTextRange = DocTextRange(350, 400)
        XCTAssertEqual(view.editor.state.selection.anchor, 400)
        XCTAssertEqual(view.editor.state.selection.head, 350)
        XCTAssertTrue(view.editor.doc.eq(original), "selection must not move or delete content")
    }

    func testUpwardSelectionRevealRespectsHostTopInset() throws {
        let (window, scroll, view) = try fixture()
        defer { window.isHidden = true }
        scroll.contentInset = UIEdgeInsets(top: 64, left: 0, bottom: 40, right: 0)
        XCTAssertTrue(view.becomeFirstResponder())
        view.selectedTextRange = DocTextRange(500, 500)
        let before = scroll.contentOffset.y
        view.selectedTextRange = DocTextRange(1, 500)
        XCTAssertLessThan(scroll.contentOffset.y, before)
        XCTAssertGreaterThanOrEqual(scroll.contentOffset.y, -64)
        let caret = view.caretRect(for: DocTextPosition(1))
        let visibleTop = scroll.contentOffset.y + scroll.adjustedContentInset.top
        XCTAssertGreaterThanOrEqual(caret.minY, visibleTop, "the active end must clear host chrome")
        XCTAssertLessThanOrEqual(caret.maxY, scroll.contentOffset.y + scroll.bounds.height - 40)
    }

    func testEscapePreservesRangeAndScrollForHostDismissal() throws {
        let (window, scroll, view) = try fixture()
        defer { window.isHidden = true }
        XCTAssertTrue(view.becomeFirstResponder())
        view.selectedTextRange = DocTextRange(500, 500)
        view.selectedTextRange = DocTextRange(300, 500)
        let selection = view.editor.state.selection
        let offset = scroll.contentOffset.y
        for _ in 0..<3 {
            XCTAssertFalse(view.handle(EditorTextView.KeyEvent(.keyboardEscape)))
            XCTAssertTrue(view.editor.state.selection.eq(selection))
            XCTAssertEqual(scroll.contentOffset.y, offset, accuracy: 0.5)
        }
    }
}

private final class SelectionDragSession: NSObject, UIDragSession {
    let point: CGPoint
    init(point: CGPoint) { self.point = point }
    func location(in view: UIView) -> CGPoint { point }
    var items: [UIDragItem] = []
    var allowsMoveOperation = true
    var isRestrictedToDraggingApplication = false
    var localContext: Any?
    func hasItemsConforming(toTypeIdentifiers typeIdentifiers: [String]) -> Bool { false }
    func canLoadObjects(ofClass aClass: any NSItemProviderReading.Type) -> Bool { false }
}
#endif

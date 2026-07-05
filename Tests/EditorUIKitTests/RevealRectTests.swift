#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

/// Reveal-on-selection must target the caret's position in the enclosing scroll
/// view's *content* coordinates, not raw document coordinates. The two only
/// coincide when the editor is the scroll content sitting at content origin 0;
/// any header above the editor (or deeper nesting) shifts them apart.
@MainActor
final class RevealRectTests: XCTestCase {

    private func makeEditor() throws -> Editor {
        let editor = try Editor(extensions: fullKit())
        let paras = (0..<80).map { i in
            try! editor.schema.node("paragraph", [:], content: Fragment.from([editor.schema.text("paragraph number \(i)")]))
        }
        editor.setContent(try! editor.schema.node("doc", [:], content: Fragment.from(paras)))
        return editor
    }

    /// Regression: the editor is the scroll content but sits below a 200pt
    /// header. Revealing a selection near the document top must scroll to the
    /// caret's content position (document position + 200), not its document
    /// position.
    func testRevealTargetsContentCoordinatesWhenEditorIsOffsetInContent() throws {
        let editor = try makeEditor()
        let headerHeight: CGFloat = 200

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        let scroll = UIScrollView(frame: window.bounds)
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: headerHeight, width: 320, height: 400)
        scroll.addSubview(view)
        window.addSubview(scroll)
        window.makeKeyAndVisible()

        let docHeight = view.documentHeight
        XCTAssertGreaterThan(docHeight, 400, "doc should be taller than the viewport")
        view.frame = CGRect(x: 0, y: headerHeight, width: 320, height: docHeight)
        scroll.contentSize = CGSize(width: 320, height: docHeight + headerHeight)
        XCTAssertTrue(view.becomeFirstResponder())

        // The user has scrolled far down; a selection lands near the top.
        scroll.contentOffset = CGPoint(x: 0, y: 600)
        view.editor.dispatch(view.editor.state.tr.setSelection(TextSelection.create(view.editor.doc, 1)))

        // contentOffsetY == 0 here, so the caret layer's rect is the document rect.
        let caret = try XCTUnwrap(view.caretViewRectForTesting)
        let expected = max(0, caret.minY + headerHeight - 8)
        XCTAssertEqual(scroll.contentOffset.y, expected, accuracy: 1,
                       "reveal must target the caret's content position, not its document position")
    }

    /// Compat: when the editor IS the scroll content at origin 0, document and
    /// content coordinates coincide and the reveal target is unchanged.
    func testRevealUnchangedWhenEditorIsTheScrollContentAtOrigin() throws {
        let editor = try makeEditor()

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        let scroll = UIScrollView(frame: window.bounds)
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 400)
        scroll.addSubview(view)
        window.addSubview(scroll)
        window.makeKeyAndVisible()

        let docHeight = view.documentHeight
        view.frame = CGRect(x: 0, y: 0, width: 320, height: docHeight)
        scroll.contentSize = CGSize(width: 320, height: docHeight)
        XCTAssertTrue(view.becomeFirstResponder())

        scroll.contentOffset = CGPoint(x: 0, y: 600)
        view.editor.dispatch(view.editor.state.tr.setSelection(TextSelection.create(view.editor.doc, 1)))

        let caret = try XCTUnwrap(view.caretViewRectForTesting)
        XCTAssertEqual(scroll.contentOffset.y, max(0, caret.minY - 8), accuracy: 1,
                       "flat embedding must keep today's reveal target")
    }

    /// Compat: pinned-viewport mode — the view's frame origin tracks the scroll
    /// offset while `contentOffsetY` mirrors it, so the two shifts cancel and
    /// the reveal target equals the document-coordinate one.
    func testRevealUnchangedInPinnedViewportMode() throws {
        let editor = try makeEditor()

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        let scroll = UIScrollView(frame: window.bounds)
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 400)
        scroll.addSubview(view)
        window.addSubview(scroll)
        window.makeKeyAndVisible()

        scroll.contentSize = CGSize(width: 320, height: view.documentHeight)
        XCTAssertTrue(view.becomeFirstResponder())

        // Host has scrolled to 600: it repositions the viewport slice and
        // feeds the offset.
        scroll.contentOffset = CGPoint(x: 0, y: 600)
        view.frame = CGRect(x: 0, y: 600, width: 320, height: 400)
        view.contentOffsetY = 600

        view.editor.dispatch(view.editor.state.tr.setSelection(TextSelection.create(view.editor.doc, 1)))

        // Caret layer is in viewport coords: document rect = layer rect + contentOffsetY.
        let caret = try XCTUnwrap(view.caretViewRectForTesting)
        let docMinY = caret.minY + view.contentOffsetY
        XCTAssertEqual(scroll.contentOffset.y, max(0, docMinY - 8), accuracy: 1,
                       "pinned-viewport embedding must keep today's reveal target")
    }

    /// A selection at the document end never scrolls past
    /// contentSize.height − viewportHeight.
    func testRevealClampsToContentSize() throws {
        let editor = try makeEditor()

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        let scroll = UIScrollView(frame: window.bounds)
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 400)
        scroll.addSubview(view)
        window.addSubview(scroll)
        window.makeKeyAndVisible()

        let docHeight = view.documentHeight
        view.frame = CGRect(x: 0, y: 0, width: 320, height: docHeight)
        scroll.contentSize = CGSize(width: 320, height: docHeight)
        XCTAssertTrue(view.becomeFirstResponder())

        let end = view.editor.doc.content.size - 1
        view.editor.dispatch(view.editor.state.tr.setSelection(TextSelection.create(view.editor.doc, end)))

        XCTAssertGreaterThan(scroll.contentOffset.y, 0, "reveal should have scrolled down")
        XCTAssertLessThanOrEqual(scroll.contentOffset.y, docHeight - 400 + 0.5,
                                 "reveal must not scroll past contentSize.height − viewportHeight")
    }
}
#endif

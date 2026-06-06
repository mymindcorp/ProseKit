#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

/// Virtualized scrolling: feeding the scroll offset must reposition the rendered
/// window, NOT scroll the view back to the caret (which froze scrolling).
@MainActor
final class ScrollingTests: XCTestCase {
    func testFeedingScrollOffsetDoesNotSnapBackToCaret() throws {
        let editor = try Editor(extensions: fullKit())
        let paras = (0..<80).map { i in
            try! editor.schema.node("paragraph", [:], content: Fragment.from([editor.schema.text("paragraph number \(i)")]))
        }
        editor.setContent(try! editor.schema.node("doc", [:], content: Fragment.from(paras)))

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        let scroll = UIScrollView(frame: window.bounds)
        let view = EditorTextView(editor: editor)
        view.frame = scroll.bounds
        scroll.addSubview(view)
        window.addSubview(scroll)
        window.makeKeyAndVisible()
        XCTAssertTrue(view.becomeFirstResponder())

        // Caret at the very top.
        view.editor.dispatch(view.editor.state.tr.setSelection(TextSelection.create(view.editor.doc, 1)))
        scroll.contentSize = CGSize(width: 320, height: view.documentHeight)
        XCTAssertGreaterThan(view.documentHeight, 400, "doc should be taller than the viewport")

        // The user scrolls far down; the host feeds the new offset.
        scroll.contentOffset = CGPoint(x: 0, y: 600)
        view.contentOffsetY = 600
        XCTAssertEqual(scroll.contentOffset.y, 600, accuracy: 0.5, "scrolling must not snap back to the caret")
    }
}
#endif

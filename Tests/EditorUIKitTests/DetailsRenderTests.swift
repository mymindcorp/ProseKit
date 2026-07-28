#if canImport(UIKit)
import XCTest
import DocumentModel
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

@MainActor
final class DetailsRenderTests: XCTestCase {
    private func detailsView(open: Bool) throws -> EditorTextView {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        func para(_ text: String) -> Node {
            try! s.node("paragraph", [:], content: Fragment.from([s.text(text)]))
        }
        let details = try s.node("details", ["open": .bool(open)], content: Fragment.from([
            try s.node("detailsSummary", [:], content: Fragment.from([s.text("Summary")])),
            try s.node("detailsContent", [:], content: Fragment.from([para("hidden body")])),
        ]))
        editor.setContent(try s.node("doc", [:], content: Fragment.from([details, para("after")])))
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        view.layoutIfNeeded()
        return view
    }

    private func laidOutText(_ view: EditorTextView) -> [String] {
        view.ensureLayout().blocks.map { $0.attributed.string }
    }

    func testOpenSectionLaysOutSummaryAndBody() throws {
        let view = try detailsView(open: true)
        let text = laidOutText(view)
        XCTAssertTrue(text.contains { $0.contains("Summary") })
        XCTAssertTrue(text.contains { $0.contains("hidden body") }, "an open section shows its content")
    }

    func testClosedSectionLaysOutOnlyTheSummary() throws {
        let view = try detailsView(open: false)
        let text = laidOutText(view)
        XCTAssertTrue(text.contains { $0.contains("Summary") })
        XCTAssertFalse(text.contains { $0.contains("hidden body") }, "a closed section hides its content")
        XCTAssertTrue(text.contains { $0.contains("after") }, "blocks after it still lay out")
    }

    func testDisclosureTriangleIsHitTestableAndTogglesTheDocument() throws {
        let view = try detailsView(open: true)
        let layout = view.ensureLayout()
        XCTAssertEqual(layout.disclosures.count, 1)
        let hit = try XCTUnwrap(layout.disclosure(at: layout.disclosures[0].rect.center))
        XCTAssertTrue(hit.open)
        view.toggleDetailsForTesting(at: hit.pos)
        XCTAssertEqual(view.editor.doc.child(0).attrs["open"], .bool(false), "the tap closed the section")
        XCTAssertFalse(laidOutText(view).contains { $0.contains("hidden body") })
        // And back open again.
        view.toggleDetailsForTesting(at: hit.pos)
        XCTAssertEqual(view.editor.doc.child(0).attrs["open"], .bool(true))
        XCTAssertTrue(laidOutText(view).contains { $0.contains("hidden body") })
    }

    func testClosingMovesACaretOutOfTheHiddenBody() throws {
        let view = try detailsView(open: true)
        let details = view.editor.doc.child(0)
        // Put the caret inside the body.
        let bodyPos = 1 + details.child(0).nodeSize + 2
        view.editor.dispatch(view.editor.state.tr.setSelection(TextSelection.create(view.editor.doc, bodyPos)))
        view.toggleDetailsForTesting(at: 0)
        let head = view.editor.state.selection.head
        XCTAssertLessThanOrEqual(head, details.child(0).nodeSize, "the caret moved back into the summary")
        XCTAssertNotNil(view.ensureLayout().caretRect(at: head))
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
#endif

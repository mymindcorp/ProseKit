#if canImport(UIKit)
import XCTest
import DocumentModel
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

@MainActor
final class LinkEditingTests: XCTestCase {
    private func view(_ text: String) throws -> EditorTextView {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        editor.setContent(try s.node("doc", [:], content: Fragment.from([
            try s.node("paragraph", [:], content: Fragment.from([s.text(text)])),
        ])))
        let v = EditorTextView(editor: editor)
        v.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        v.layoutIfNeeded()
        return v
    }

    private func select(_ v: EditorTextView, _ from: Int, _ to: Int) {
        v.editor.dispatch(v.editor.state.tr.setSelection(TextSelection.create(v.editor.doc, from, to)))
    }

    private func linkType(_ v: EditorTextView) -> MarkType { v.editor.schema.marks["link"]! }

    func testCurrentLinkTargetFromSelection() throws {
        let v = try view("hello world")
        select(v, 1, 6)
        let target = try XCTUnwrap(v.currentLinkTarget())
        XCTAssertEqual(target.from, 1)
        XCTAssertEqual(target.to, 6)
        XCTAssertNil(target.href)
    }

    func testCurrentLinkTargetFromCaretInsideLink() throws {
        let v = try view("hello world")
        select(v, 1, 6)
        v.applyLinkForTesting("https://example.com", from: 1, to: 6)
        // Collapsed caret inside the linked word → targets the whole link.
        select(v, 3, 3)
        let target = try XCTUnwrap(v.currentLinkTarget())
        XCTAssertEqual(target.from, 1)
        XCTAssertEqual(target.to, 6)
        XCTAssertEqual(target.href, "https://example.com")
    }

    func testOpenLinkEditorShowsPopupWhenLinkable() throws {
        let v = try view("hello world")
        select(v, 1, 6)
        v.openLinkEditor()
        XCTAssertTrue(v.isLinkEditorVisible)
        XCTAssertTrue(v.subviews.contains { $0 is LinkPopupView })
    }

    func testOpenLinkEditorDoesNothingWithoutATarget() throws {
        let v = try view("hello world")
        select(v, 3, 3) // collapsed, not in a link
        v.openLinkEditor()
        XCTAssertFalse(v.isLinkEditorVisible)
    }

    func testApplyLinkAddsAndRemoves() throws {
        let v = try view("hello world")
        v.applyLinkForTesting("https://example.com", from: 1, to: 6)
        XCTAssertTrue(v.editor.doc.rangeHasMark(1, 6, linkType(v)))
        XCTAssertEqual(v.linkInfo(at: 3)?.href, "https://example.com")
        // Empty URL removes it.
        v.applyLinkForTesting("", from: 1, to: 6)
        XCTAssertFalse(v.editor.doc.rangeHasMark(1, 6, linkType(v)))
    }

    func testPasteURLOverSelectionLinksIt() throws {
        let v = try view("hello world")
        select(v, 1, 6)
        let pb = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pb.name) }
        pb.string = "https://example.com"
        XCTAssertTrue(v.pasteURLOverSelection(pb))
        XCTAssertEqual(v.linkInfo(at: 3)?.href, "https://example.com")
    }

    func testPasteBareDomainGetsHTTPS() throws {
        let v = try view("hello world")
        select(v, 1, 6)
        let pb = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pb.name) }
        pb.string = "example.com/page"
        XCTAssertTrue(v.pasteURLOverSelection(pb))
        XCTAssertEqual(v.linkInfo(at: 3)?.href, "https://example.com/page")
    }

    func testPasteNonURLOverSelectionIsNotALink() throws {
        let v = try view("hello world")
        select(v, 1, 6)
        let pb = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pb.name) }
        pb.string = "just some text"
        XCTAssertFalse(v.pasteURLOverSelection(pb))
    }

    func testFormatBoldAppliesBold() throws {
        let v = try view("hello world")
        select(v, 1, 6)
        v.formatBold(nil)
        let bold = v.editor.schema.marks["bold"]!
        XCTAssertTrue(v.editor.doc.rangeHasMark(1, 6, bold))
    }

    func testFormatActionsEnabledOnlyWithSelection() throws {
        let v = try view("hello world")
        select(v, 3, 3)
        XCTAssertFalse(v.canPerformAction(#selector(EditorTextView.formatBold(_:)), withSender: nil))
        select(v, 1, 6)
        XCTAssertTrue(v.canPerformAction(#selector(EditorTextView.formatBold(_:)), withSender: nil))
    }

    func testHighlightActionAppliesHighlight() throws {
        let v = try view("hello world")
        select(v, 1, 6)
        XCTAssertTrue(v.canPerformAction(#selector(EditorTextView.toggleHighlightAction(_:)), withSender: nil))
        v.toggleHighlightAction(nil)
        let highlight = v.editor.schema.marks["highlight"]!
        XCTAssertTrue(v.editor.doc.rangeHasMark(1, 6, highlight))
        // Off with an empty selection.
        select(v, 3, 3)
        XCTAssertFalse(v.canPerformAction(#selector(EditorTextView.toggleHighlightAction(_:)), withSender: nil))
    }
}
#endif

#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

/// The find / replace bar wiring (the search engine itself is covered in
/// SchemaKitTests).
@MainActor
final class FindBarTests: XCTestCase {
    private func makeView(_ text: String = "the cat sat on the mat") throws -> EditorTextView {
        let editor = try Editor(extensions: fullKit())
        editor.setContent(try! editor.schema.node("doc", [:], content: Fragment.from([
            try! editor.schema.node("paragraph", [:], content: Fragment.from([editor.schema.text(text)])),
        ])))
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        view.layoutIfNeeded()
        return view
    }

    func testShowSeedsQueryFromSelectionAndHighlights() throws {
        let view = try makeView()
        // Select the first "the".
        view.editor.dispatch(view.editor.state.tr.setSelection(TextSelection.create(view.editor.doc, 1, 4)))
        view.showFindBar()
        XCTAssertTrue(view.isFindBarVisible)
        XCTAssertEqual(view.editor.searchQuery?.search, "the")
        XCTAssertEqual(view.editor.searchMatches.count, 2, "'the' occurs twice")
    }

    func testEscapeClosesAndClearsSearch() throws {
        let view = try makeView()
        view.showFindBar()
        view.editor.setSearch("cat")
        XCTAssertEqual(view.editor.searchMatches.count, 1)
        _ = view.handle(EditorTextView.KeyEvent(.keyboardEscape))
        XCTAssertFalse(view.isFindBarVisible)
        XCTAssertTrue(view.editor.searchMatches.isEmpty, "closing the bar clears the search")
    }

    func testFindNextSelectsMatches() throws {
        let view = try makeView()
        view.editor.setSearch("the")
        view.editor.findNext()
        let sel1 = view.editor.state.selection
        XCTAssertEqual(view.editor.doc.textBetween(sel1.from, sel1.to), "the")
        let first = sel1.from
        view.editor.findNext()
        let sel2 = view.editor.state.selection
        XCTAssertEqual(view.editor.doc.textBetween(sel2.from, sel2.to), "the")
        XCTAssertNotEqual(sel2.from, first, "advances to the second occurrence")
    }

    func testReplaceAllThroughEditor() throws {
        let view = try makeView()
        view.editor.setSearch("the")
        let n = view.editor.replaceAllMatches(with: "THE")
        XCTAssertEqual(n, 2)
        XCTAssertEqual(view.editor.doc.textContent, "THE cat sat on THE mat")
    }
}
#endif

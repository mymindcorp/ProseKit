#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

/// The `/` slash menu and `[[` wiki-link suggestion popup, driven through the
/// view the way typing does.
@MainActor
final class SuggestionMenuTests: XCTestCase {
    private func makeView(wikiLinks: (@Sendable (String) -> [String])? = nil) throws -> EditorTextView {
        let editor = try Editor(extensions: fullKit(wikiLinkSuggestions: wikiLinks))
        editor.setContent(try! editor.schema.node("doc", [:], content: Fragment.from([
            try! editor.schema.node("paragraph", [:], content: Fragment.empty),
        ])))
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        view.layoutIfNeeded()
        _ = view.becomeFirstResponder()
        return view
    }
    private func type(_ view: EditorTextView, _ text: String) { for ch in text { view.insertText(String(ch)) } }

    func testSlashMenuShowsAndFilters() throws {
        let view = try makeView()
        type(view, "/")
        XCTAssertNotNil(view.suggestionTitles, "popup should appear on /")
        XCTAssertEqual(view.suggestionTitles?.first, "Heading 1")
        type(view, "code")
        XCTAssertEqual(view.suggestionTitles, ["Code Block"], "query filters to matching commands")
    }

    func testSlashMenuClosesOnSpace() throws {
        let view = try makeView()
        type(view, "/head")
        XCTAssertNotNil(view.suggestionTitles)
        type(view, " ")
        XCTAssertNil(view.suggestionTitles, "a space dismisses the slash menu")
    }

    func testSlashMenuEnterAppliesAndRemovesQuery() throws {
        let view = try makeView()
        type(view, "/h1")
        XCTAssertEqual(view.suggestionTitles?.first, "Heading 1")
        _ = view.handle(EditorTextView.KeyEvent(.keyboardReturnOrEnter)) // accept
        XCTAssertNil(view.suggestionTitles)
        XCTAssertTrue(view.editor.isActive(node: "heading", attrs: ["level": .int(1)]))
        XCTAssertEqual(view.editor.doc.textContent, "", "the /query text is removed")
    }

    func testEnterViaInsertTextAcceptsSuggestion() throws {
        // On a real keyboard, Return arrives as insertText("\n"), not through
        // `handle` — it must still choose the highlighted item, not break the line.
        let view = try makeView()
        type(view, "/h1")
        XCTAssertNotNil(view.suggestionTitles)
        view.insertText("\n")
        XCTAssertNil(view.suggestionTitles)
        XCTAssertTrue(view.editor.isActive(node: "heading", attrs: ["level": .int(1)]))
        XCTAssertEqual(view.editor.doc.textContent, "")
    }

    func testSlashMenuArrowMovesSelection() throws {
        let view = try makeView()
        type(view, "/")
        _ = view.handle(EditorTextView.KeyEvent(.keyboardDownArrow)) // select 2nd item
        _ = view.handle(EditorTextView.KeyEvent(.keyboardReturnOrEnter))
        XCTAssertTrue(view.editor.isActive(node: "heading", attrs: ["level": .int(2)]), "down then Enter picks Heading 2")
    }

    func testWikiLinkPopupFromProvider() throws {
        let view = try makeView(wikiLinks: { q in
            ["Home", "Architecture", "Releases"].filter { q.isEmpty || $0.range(of: q, options: .caseInsensitive) != nil }
        })
        type(view, "[[Arch")
        XCTAssertEqual(view.suggestionTitles, ["Architecture"])
        _ = view.handle(EditorTextView.KeyEvent(.keyboardReturnOrEnter))
        XCTAssertNil(view.suggestionTitles)
        var wikiTarget: String?
        view.editor.doc.descendants { n, _, _, _ in
            if n.type.name == "wikiLink" { wikiTarget = n.attrs["target"]?.stringValue }
            return true
        }
        XCTAssertEqual(wikiTarget, "Architecture")
    }

    /// The second link in a paragraph. An atom renders as its whole label but
    /// occupies one position, so a trigger located by character offsets landed
    /// past the cursor once one was already there — and resolving it trapped.
    /// The first link worked, which is exactly why it took a second to find.
    func testWikiLinkPopupAfterAnExistingLink() throws {
        let view = try makeView(wikiLinks: { q in
            ["Soccer Training Session", "Architecture"].filter { q.isEmpty || $0.range(of: q, options: .caseInsensitive) != nil }
        })
        type(view, "[[Soccer")
        _ = view.handle(EditorTextView.KeyEvent(.keyboardReturnOrEnter))
        type(view, " then [[Arch")
        XCTAssertEqual(view.suggestionTitles, ["Architecture"], "the popup should reopen after an atom")
        _ = view.handle(EditorTextView.KeyEvent(.keyboardReturnOrEnter))
        var targets: [String] = []
        view.editor.doc.descendants { n, _, _, _ in
            if n.type.name == "wikiLink" { targets.append(n.attrs["target"]?.stringValue ?? "") }
            return true
        }
        XCTAssertEqual(targets, ["Soccer Training Session", "Architecture"])
        XCTAssertEqual(view.editor.doc.textBetween(0, view.editor.doc.content.size,
                                                   blockSeparator: nil, leafText: "*"), "* then *",
                       "the accepted query replaced the trigger and nothing else")
    }

    func testNoWikiPopupWithoutProvider() throws {
        let view = try makeView() // no wiki provider configured
        type(view, "[[Arch")
        XCTAssertNil(view.suggestionTitles, "no provider → no wiki popup")
    }

    func testEscapeDismissesSlashMenu() throws {
        let view = try makeView()
        type(view, "/head")
        XCTAssertNotNil(view.suggestionTitles)
        _ = view.handle(EditorTextView.KeyEvent(.keyboardEscape))
        XCTAssertNil(view.suggestionTitles)
    }
}
#endif

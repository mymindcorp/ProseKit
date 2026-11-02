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
            if n.type.name == "wikiLink" { wikiTarget = n.attrs["text"]?.stringValue }
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
            if n.type.name == "wikiLink" { targets.append(n.attrs["text"]?.stringValue ?? "") }
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

    // MARK: Appearance

    func testSlashMenuGroupsSectionsUnderHeaders() throws {
        let view = try makeView()
        type(view, "/")
        XCTAssertEqual(view.suggestionSectionHeaders, ["Text", "Lists", "Blocks", "Math"])
        type(view, "head")
        XCTAssertEqual(view.suggestionTitles, ["Heading 1", "Heading 2", "Heading 3"])
        XCTAssertEqual(view.suggestionSectionHeaders, [], "one section needs no header")
    }

    func testArrowKeysStepOverSectionHeaders() throws {
        // Headers sit between rows in the list but are not rows: four steps
        // down from Heading 1 cross the "Lists" header to land on Bullet List.
        let view = try makeView()
        type(view, "/")
        for _ in 0..<4 { _ = view.handle(EditorTextView.KeyEvent(.keyboardDownArrow)) }
        _ = view.handle(EditorTextView.KeyEvent(.keyboardReturnOrEnter))
        XCTAssertTrue(view.editor.isActive(node: "bulletList"))
    }

    func testSectionHeadersCanBeTurnedOff() throws {
        let view = try makeView()
        view.theme.suggestionMenu.showsSectionHeaders = false
        type(view, "/")
        XCTAssertEqual(view.suggestionSectionHeaders, [])
    }

    func testHeadersAddToTheCardsHeight() throws {
        // Fewer rows than the cap, so the card is sized to its content and the
        // only difference is the headers.
        let view = try makeView()
        view.theme.suggestionMenu.maxVisibleRows = 20
        type(view, "/")
        let headed = try XCTUnwrap(view.suggestionPopupView).frame.height
        view.theme.suggestionMenu.showsSectionHeaders = false
        let plain = try XCTUnwrap(view.suggestionPopupView).frame.height
        XCTAssertGreaterThan(headed, plain)
    }

    func testCardSizeFollowsTheTheme() throws {
        let view = try makeView()
        type(view, "/")
        let popup = try XCTUnwrap(view.suggestionPopupView)
        XCTAssertEqual(popup.frame.width, 280, "the default width")
        let tall = popup.frame.height

        // Changing the theme rebuilds the open popup rather than waiting for the next one.
        view.theme.suggestionMenu.width = 220
        view.theme.suggestionMenu.maxVisibleRows = 3
        let restyled = try XCTUnwrap(view.suggestionPopupView)
        XCTAssertEqual(restyled.frame.width, 220)
        XCTAssertLessThan(restyled.frame.height, tall)
        XCTAssertEqual(view.suggestionTitles?.first, "Heading 1", "still the same rows")
    }

    func testCardShowsExactlyItsVisibleRows() throws {
        // In a real window, where the caret near the top puts the card across
        // the safe area: insetting the list for it once pushed the last row
        // half out of the card. A header after the last row mustn't be sized
        // in either — the card ends with its last whole row.
        let view = try makeView()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.addSubview(view)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for (cap, compact) in [(7, false), (9, true), (3, false)] {
            view.theme.suggestionMenu.maxVisibleRows = cap
            view.theme.suggestionMenu.showsSubtitles = !compact
            if view.suggestionTitles == nil { type(view, "/") }
            let popup = try XCTUnwrap(view.suggestionPopupView)
            XCTAssertEqual(popup.fullyVisibleTitles, Array(popup.items.map(\.title).prefix(cap)), "cap \(cap)")
        }
    }

    func testCompactRowsAreShorter() throws {
        let view = try makeView()
        view.theme.suggestionMenu.maxVisibleRows = 3
        type(view, "/head")
        let full = try XCTUnwrap(view.suggestionPopupView).frame.height
        view.theme.suggestionMenu.showsSubtitles = false
        let compact = try XCTUnwrap(view.suggestionPopupView).frame.height
        XCTAssertLessThan(compact, full, "dropping subtitles makes each row one line")
    }

    func testRowIconsResolveSymbolsAndFallBack() {
        XCTAssertNotNil(SuggestionPopupView.icon("list.bullet", pointSize: 15))
        let fallback = SuggestionPopupView.icon("no-such-image", pointSize: 15)
        XCTAssertNotNil(fallback, "an unknown name still draws a glyph")
        XCTAssertEqual(fallback?.pngData(), SuggestionPopupView.icon(nil, pointSize: 15)?.pngData())
    }

    func testEscapeDismissesSlashMenu() throws {
        let view = try makeView()
        type(view, "/head")
        XCTAssertNotNil(view.suggestionTitles)
        XCTAssertTrue(view.handle(EditorTextView.KeyEvent(.keyboardEscape)))
        XCTAssertNil(view.suggestionTitles)
        let selection = view.editor.state.selection
        XCTAssertFalse(view.handle(EditorTextView.KeyEvent(.keyboardEscape)), "the next Escape belongs to the host")
        XCTAssertTrue(view.editor.state.selection.eq(selection))
    }
}
/// A presenter that draws nothing and remembers what it was asked to do.
@MainActor
private final class RecordingPresenter: SuggestionMenuPresenter {
    var accepts: (SuggestionMenu) -> Bool = { _ in true }
    var presented: [SuggestionMenu] = []
    var dismissals = 0
    var current: SuggestionMenu? { presented.last }

    func present(_ menu: SuggestionMenu, in textView: EditorTextView) -> Bool {
        guard accepts(menu) else { return false }
        presented.append(menu)
        return true
    }
    func dismissSuggestions(in textView: EditorTextView) { dismissals += 1 }
}

/// A host drawing the whole menu itself through `suggestionPresenter`.
@MainActor
final class SuggestionPresenterTests: XCTestCase {
    private var presenter = RecordingPresenter()

    private func makeView(wikiLinks: (@Sendable (String) -> [String])? = nil,
                          mentions: (@Sendable (String) -> [String])? = nil) throws -> EditorTextView {
        let editor = try Editor(extensions: fullKit(wikiLinkSuggestions: wikiLinks, mentionSuggestions: mentions))
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        view.layoutIfNeeded()
        _ = view.becomeFirstResponder()
        view.suggestionPresenter = presenter
        return view
    }
    private func type(_ view: EditorTextView, _ text: String) { for ch in text { view.insertText(String(ch)) } }
    private func key(_ view: EditorTextView, _ code: UIKeyboardHIDUsage) -> Bool {
        view.handle(EditorTextView.KeyEvent(code))
    }

    func testThePresenterGetsTheMenuInsteadOfThePopup() throws {
        let view = try makeView()
        type(view, "/")
        let menu = try XCTUnwrap(presenter.current)
        XCTAssertNil(view.suggestionTitles, "the built-in popup stays down")
        XCTAssertEqual(menu.trigger, "/")
        XCTAssertEqual(menu.query, "")
        XCTAssertEqual(menu.entries.first?.title, "Heading 1")
        XCTAssertEqual(menu.entries.first?.section, "Text")
        XCTAssertEqual(menu.highlightedIndex, 0)
        XCTAssertGreaterThan(menu.caretRect.height, 0, "a caret to place the menu by")
    }

    func testTypingUpdatesTheSameMenu() throws {
        let view = try makeView()
        type(view, "/")
        let opened = try XCTUnwrap(presenter.current)
        type(view, "head")
        XCTAssertTrue(presenter.current === opened, "one menu object for as long as it's open")
        XCTAssertEqual(opened.query, "head")
        XCTAssertEqual(opened.entries.map(\.title), ["Heading 1", "Heading 2", "Heading 3"])
        XCTAssertEqual(presenter.dismissals, 0)
    }

    func testArrowKeysMoveTheHighlightAndReturnChoosesIt() throws {
        let view = try makeView()
        type(view, "/head")
        let menu = try XCTUnwrap(presenter.current)
        let before = presenter.presented.count
        XCTAssertTrue(key(view, .keyboardDownArrow))
        XCTAssertEqual(menu.highlightedIndex, 1)
        XCTAssertEqual(presenter.presented.count, before + 1, "moving the highlight presents again")
        XCTAssertTrue(key(view, .keyboardUpArrow))
        XCTAssertTrue(key(view, .keyboardUpArrow))
        XCTAssertEqual(menu.highlightedIndex, 2, "it wraps")
        XCTAssertTrue(key(view, .keyboardReturnOrEnter))
        XCTAssertTrue(view.editor.isActive(node: "heading", attrs: ["level": .int(3)]))
        XCTAssertEqual(view.editor.doc.textContent, "")
        XCTAssertEqual(presenter.dismissals, 1)
    }

    func testReturnFromTheSoftwareKeyboardChoosesToo() throws {
        let view = try makeView()
        type(view, "/h1")
        view.insertText("\n")
        XCTAssertTrue(view.editor.isActive(node: "heading", attrs: ["level": .int(1)]))
        XCTAssertEqual(presenter.dismissals, 1)
    }

    func testAHighlightThePresenterSetsIsWhatReturnChooses() throws {
        let view = try makeView()
        type(view, "/head")
        presenter.current?.highlightedIndex = 1 // the pointer moved over Heading 2
        XCTAssertTrue(key(view, .keyboardReturnOrEnter))
        XCTAssertTrue(view.editor.isActive(node: "heading", attrs: ["level": .int(2)]))
    }

    func testChoosingFromThePresentersOwnView() throws {
        let view = try makeView()
        type(view, "/code")
        let menu = try XCTUnwrap(presenter.current)
        menu.choose(0)
        XCTAssertTrue(view.editor.isActive(node: "codeBlock"))
        XCTAssertEqual(presenter.dismissals, 1)
        menu.choose(5) // out of range
        XCTAssertEqual(presenter.dismissals, 1)
    }

    func testEscapeAndDismissCloseWithoutChoosing() throws {
        let view = try makeView()
        type(view, "/head")
        XCTAssertTrue(key(view, .keyboardEscape))
        XCTAssertEqual(presenter.dismissals, 1)
        XCTAssertEqual(view.editor.doc.textContent, "/head", "the query stays")
        XCTAssertFalse(key(view, .keyboardEscape), "nothing open: the next Escape belongs to the host")

        let closed = try XCTUnwrap(presenter.current)
        closed.dismiss() // no longer open: nothing to take down
        XCTAssertEqual(presenter.dismissals, 1)
        view.deleteBackward() // "/hea" — the menu opens again, as a new one
        let reopened = try XCTUnwrap(presenter.current)
        XCTAssertFalse(reopened === closed)
        reopened.dismiss()
        XCTAssertEqual(presenter.dismissals, 2)
    }

    func testAChoiceStillLandsAfterATapMovedTheCaret() throws {
        // A tap on the presenter's view can reach the text view first and move
        // the caret, which closes the menu. The row was built for the trigger
        // it came from, so choosing it afterwards still applies there.
        let view = try makeView()
        type(view, "/h1")
        let menu = try XCTUnwrap(presenter.current)
        view.editor.dispatch(view.editor.state.tr.setSelection(TextSelection.create(view.editor.doc, 1, 1)))
        XCTAssertEqual(presenter.dismissals, 1, "the caret left the query")
        menu.choose(0)
        XCTAssertTrue(view.editor.isActive(node: "heading", attrs: ["level": .int(1)]))
        XCTAssertEqual(view.editor.doc.textContent, "")
    }

    func testAChoiceOutlivedByAnEditDoesNothing() throws {
        let view = try makeView()
        type(view, "/h1")
        let menu = try XCTUnwrap(presenter.current)
        try view.editor.setContent(html: "<p>other text</p>")
        let before = view.editor.doc
        menu.choose(0)
        XCTAssertEqual(view.editor.doc, before)
    }

    func testDecliningHandsTheMenuBackToTheBuiltInPopup() throws {
        // Take over only the `[[` menu.
        presenter.accepts = { $0.trigger == "[[" }
        let view = try makeView(wikiLinks: { _ in ["Home", "Architecture"] })
        type(view, "/")
        XCTAssertTrue(presenter.presented.isEmpty)
        XCTAssertEqual(view.suggestionTitles?.first, "Heading 1", "the slash menu is drawn as before")
        XCTAssertTrue(key(view, .keyboardEscape))
        type(view, " [[Ar")
        XCTAssertEqual(presenter.current?.trigger, "[[")
        XCTAssertEqual(presenter.current?.entries.map(\.title), ["Home", "Architecture"])
        XCTAssertNil(view.suggestionTitles)
    }

    func testEachMenuNamesItsTrigger() throws {
        let view = try makeView(mentions: { _ in ["Ada Lovelace"] })
        type(view, "@Ad")
        XCTAssertEqual(presenter.current?.trigger, "@")
    }

    func testRemovingThePresenterWhileOpenFallsBackToThePopup() throws {
        let view = try makeView()
        type(view, "/head")
        view.suggestionPresenter = nil
        XCTAssertEqual(presenter.dismissals, 1)
        XCTAssertEqual(view.suggestionTitles, ["Heading 1", "Heading 2", "Heading 3"])
        // And back: the popup comes down and the presenter takes it.
        view.suggestionPresenter = presenter
        XCTAssertNil(view.suggestionTitles)
        XCTAssertEqual(presenter.current?.query, "head")
    }

    func testScrollingRepresentsWithANewCaretOnly() throws {
        let view = try makeView()
        type(view, "/head")
        let menu = try XCTUnwrap(presenter.current)
        let caret = menu.caretRect
        let count = presenter.presented.count
        view.contentOffsetY += 30
        XCTAssertEqual(presenter.presented.count, count + 1)
        XCTAssertEqual(menu.caretRect.minY, caret.minY - 30, accuracy: 0.5)
        XCTAssertEqual(menu.query, "head")
    }
}
#endif

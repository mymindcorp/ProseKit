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
        view.frame.size.height = 2000 // with nothing to clamp the card to
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

    // MARK: The keyboard

    /// A view in a window, with the caret `lines` paragraphs down.
    private func makeWindowedView(lines: Int, windowHeight: CGFloat = 844) throws -> (EditorTextView, UIWindow) {
        let view = try makeView()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: windowHeight))
        view.frame = window.bounds
        window.addSubview(view)
        window.makeKeyAndVisible()
        view.layoutIfNeeded()
        for _ in 0..<lines { view.insertText("\n") }
        return (view, window)
    }

    private func showKeyboard(top: CGFloat, in window: UIWindow) {
        NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil, userInfo: [
            UIResponder.keyboardFrameEndUserInfoKey:
                CGRect(x: 0, y: top, width: window.bounds.width, height: window.bounds.height - top),
        ])
    }

    func testThePopupStaysAboveTheKeyboard() throws {
        let (view, window) = try makeWindowedView(lines: 0)
        defer { window.isHidden = true; showKeyboard(top: window.bounds.height, in: window) }
        showKeyboard(top: 300, in: window)
        type(view, "/")
        let popup = try XCTUnwrap(view.suggestionPopupView)
        XCTAssertLessThanOrEqual(popup.frame.maxY, 300)
        XCTAssertLessThan(popup.frame.height, popup.fittingSize().height, "shorter than it wanted: it scrolls")
        XCTAssertGreaterThan(popup.frame.minY, 0)
        XCTAssertFalse(popup.fullyVisibleTitles.isEmpty)
    }

    func testThePopupFlipsAboveTheCaretWhenThereIsRoom() throws {
        let (view, window) = try makeWindowedView(lines: 8)
        defer { window.isHidden = true; showKeyboard(top: window.bounds.height, in: window) }
        showKeyboard(top: 500, in: window)
        view.theme.suggestionMenu.maxVisibleRows = 2
        type(view, "/")
        let popup = try XCTUnwrap(view.suggestionPopupView)
        let overlay = UIView()
        let anchor = CGRect(x: 20, y: 440, width: 2, height: 20)
        let frame = view.placeOverlay(overlay, viewportAnchor: anchor, size: CGSize(width: 200, height: 100))
        XCTAssertEqual(frame.maxY, anchor.minY - 4, "no room below the anchor, so above it")
        XCTAssertEqual(frame.height, 100, "at full height: it fits there")
        XCTAssertLessThanOrEqual(popup.frame.maxY, 500)
    }

    func testAnOpenPopupMovesWhenTheKeyboardDoes() throws {
        let (view, window) = try makeWindowedView(lines: 0)
        defer { window.isHidden = true; showKeyboard(top: window.bounds.height, in: window) }
        type(view, "/")
        let popup = try XCTUnwrap(view.suggestionPopupView)
        let tall = popup.frame.height
        showKeyboard(top: 400, in: window)
        XCTAssertLessThanOrEqual(popup.frame.maxY, 400)
        showKeyboard(top: window.bounds.height, in: window) // it went away
        XCTAssertEqual(popup.frame.height, tall, "and the room comes back")
    }

    func testThePopupMovesOnTheKeyboardsOwnAnimation() throws {
        // Jumping to where the keyboard will end up, while it is still on its
        // way, is a frame or more of the menu and keyboard out of step.
        let (view, window) = try makeWindowedView(lines: 0)
        defer { window.isHidden = true; showKeyboard(top: window.bounds.height, in: window) }
        type(view, "/")
        let popup = try XCTUnwrap(view.suggestionPopupView)
        NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil, userInfo: [
            UIResponder.keyboardFrameEndUserInfoKey: CGRect(x: 0, y: 400, width: 390, height: 444),
            UIResponder.keyboardAnimationDurationUserInfoKey: 0.25,
            // Ease-in-out, whose duration UIKit reports as given; the keyboard's
            // own private curve (7) becomes a spring that reports its own.
            UIResponder.keyboardAnimationCurveUserInfoKey: UInt(UIView.AnimationCurve.easeInOut.rawValue),
        ])
        let animation = popup.layer.animation(forKey: "bounds.size") ?? popup.layer.animation(forKey: "position")
        XCTAssertNotNil(animation, "the move rides an animation: \(popup.layer.animationKeys() ?? [])")
        XCTAssertEqual(animation?.duration ?? 0, 0.25, accuracy: 0.001, "the keyboard's own duration")
        XCTAssertLessThanOrEqual(popup.frame.maxY, 400, "and ends clear of it")
    }

    func testAPresentersViewRidesTheKeyboardAnimationToo() throws {
        let presenter = PlacingPresenter()
        let (view, window) = try makeWindowedView(lines: 0)
        defer { window.isHidden = true; showKeyboard(top: window.bounds.height, in: window) }
        view.suggestionPresenter = presenter
        type(view, "/")
        NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil, userInfo: [
            UIResponder.keyboardFrameEndUserInfoKey: CGRect(x: 0, y: 300, width: 390, height: 544),
            UIResponder.keyboardAnimationDurationUserInfoKey: 0.25,
            UIResponder.keyboardAnimationCurveUserInfoKey: UInt(7),
        ])
        XCTAssertFalse(presenter.card.layer.animationKeys()?.isEmpty ?? true)
        XCTAssertLessThanOrEqual(presenter.card.frame.maxY, 300)
    }

    func testAKeyboardThatIsntDockedIsLeftAlone() throws {
        let (view, window) = try makeWindowedView(lines: 0)
        defer { window.isHidden = true; showKeyboard(top: window.bounds.height, in: window) }
        type(view, "/")
        let popup = try XCTUnwrap(view.suggestionPopupView)
        let tall = popup.frame.height
        NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil, userInfo: [
            UIResponder.keyboardFrameEndUserInfoKey: CGRect(x: 40, y: 200, width: 300, height: 250), // floating
        ])
        XCTAssertEqual(popup.frame.height, tall)
    }

    func testPlaceOverlayReportsTheFrameItGave() throws {
        let (view, window) = try makeWindowedView(lines: 0)
        defer { window.isHidden = true; showKeyboard(top: window.bounds.height, in: window) }
        showKeyboard(top: 300, in: window)
        let overlay = UIView()
        let frame = view.placeOverlay(overlay, viewportAnchor: CGRect(x: 20, y: 40, width: 2, height: 20),
                                      size: CGSize(width: 200, height: 600))
        XCTAssertEqual(frame, overlay.frame)
        XCTAssertLessThanOrEqual(frame.maxY, 300)
        XCTAssertLessThan(frame.height, 600)
        XCTAssertGreaterThan(frame.minY, 60, "below the anchor, the roomier side")
    }

    func testRowIconsResolveSymbolsAndFallBack() {
        XCTAssertNotNil(SuggestionPopupView.icon("list.bullet", pointSize: 15))
        let fallback = SuggestionPopupView.icon("no-such-image", pointSize: 15)
        XCTAssertNotNil(fallback, "an unknown name still draws a glyph")
        XCTAssertEqual(fallback?.pngData(), SuggestionPopupView.icon(nil, pointSize: 15)?.pngData())
    }

    func testEscapeKeepsTheSlashMenuClosedWhileTyping() throws {
        let view = try makeView()
        type(view, "/head")
        XCTAssertTrue(view.handle(EditorTextView.KeyEvent(.keyboardEscape)))
        type(view, "ing")
        XCTAssertNil(view.suggestionTitles, "still closed: Escape meant it")
        XCTAssertEqual(view.editor.doc.textContent, "/heading", "the text is just text now")
        // Leaving the trigger and coming back to a fresh one opens it again.
        for _ in 0..<8 { view.deleteBackward() }
        type(view, "/")
        XCTAssertEqual(view.suggestionTitles?.first, "Heading 1")
    }

    func testEscapeKeepsTheWikiMenuClosedWhileTyping() throws {
        let view = try makeView(wikiLinks: { q in
            ["Home", "Architecture"].filter { q.isEmpty || $0.localizedCaseInsensitiveContains(q) }
        })
        type(view, "see [[A")
        XCTAssertEqual(view.suggestionTitles, ["Architecture"])
        XCTAssertTrue(view.handle(EditorTextView.KeyEvent(.keyboardEscape)))
        type(view, "r")
        XCTAssertNil(view.suggestionTitles)
        type(view, " and [[Ho") // a second trigger is a new menu
        XCTAssertEqual(view.suggestionTitles, ["Home"])
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
    var presentsEmptyMenus = false
    var current: SuggestionMenu? { presented.last }
    /// What `menu.changes` said at each present.
    var changes: [SuggestionMenu.Changes] = []
    /// The keys offered, and which to take.
    var keys: [SuggestionMenuKey] = []
    var takes: (SuggestionMenuKey, SuggestionMenu) -> Bool = { _, _ in false }
    /// What it shows, and how big that is.
    let view = UIView()
    var size = CGSize(width: 200, height: 100)
    var anchor: SuggestionMenu.Anchor = .trigger
    var position: SuggestionMenu.Position = .auto
    /// Each `didPlace`: the frame, side and anchor rect at the time.
    var placed: [(frame: CGRect, placement: SuggestionMenu.Placement, anchor: CGRect)] = []

    func present(_ menu: SuggestionMenu, in textView: EditorTextView) -> UIView? {
        guard accepts(menu) else { return nil }
        menu.anchor = anchor
        menu.position = position
        presented.append(menu)
        changes.append(menu.changes)
        return view
    }
    func preferredSize(for menu: SuggestionMenu, of view: UIView, maxWidth: CGFloat) -> CGSize { size }
    func didPlace(_ menu: SuggestionMenu, in textView: EditorTextView) {
        placed.append((menu.frame, menu.placement, menu.anchorRect))
    }
    func handleKey(_ key: SuggestionMenuKey, in menu: SuggestionMenu) -> Bool {
        keys.append(key)
        return takes(key, menu)
    }
    func close(_ menu: SuggestionMenu, in textView: EditorTextView) {
        dismissals += 1
        XCTAssertNil(view.superview, "the editor takes the view down before close")
    }
}

/// Records which menu each close names.
@MainActor
private final class ClosingPresenter: SuggestionMenuPresenter {
    var shown: SuggestionMenu?
    var closed: [SuggestionMenu] = []
    func present(_ menu: SuggestionMenu, in textView: EditorTextView) -> UIView? { shown = menu; return UIView() }
    func close(_ menu: SuggestionMenu, in textView: EditorTextView) { closed.append(menu) }
}

/// Writes down, at every callback, what the menu said about its editor and the
/// typed text: which callback, the editor, the text in `from..<to`, and the
/// on-screen start and end of it.
@MainActor
private final class InspectingPresenter: SuggestionMenuPresenter {
    struct Seen {
        let callback: String
        let editor: Editor?
        let text: String
        let from: Int
        let to: Int
        let origin: CGRect
        let caret: CGRect
    }
    var seen: [Seen] = []
    var onKey: (SuggestionMenuKey, SuggestionMenu) -> Bool = { _, _ in false }
    var presentsEmptyMenus = false

    private func note(_ callback: String, _ menu: SuggestionMenu) {
        let text = menu.editor.map { $0.doc.textBetween(menu.from, min(menu.to, $0.doc.content.size)) } ?? ""
        seen.append(Seen(callback: callback, editor: menu.editor, text: text, from: menu.from, to: menu.to,
                         origin: menu.originRect, caret: menu.caretRect))
    }
    func present(_ menu: SuggestionMenu, in textView: EditorTextView) -> UIView? { note("present", menu); return UIView() }
    func didPlace(_ menu: SuggestionMenu, in textView: EditorTextView) { note("place", menu) }
    func handleKey(_ key: SuggestionMenuKey, in menu: SuggestionMenu) -> Bool {
        note("key", menu)
        return onKey(key, menu)
    }
    func close(_ menu: SuggestionMenu, in textView: EditorTextView) { note("close", menu) }
}

/// Hands over a tall plain view, for the editor to place.
@MainActor
private final class PlacingPresenter: SuggestionMenuPresenter {
    let card = UIView()
    func present(_ menu: SuggestionMenu, in textView: EditorTextView) -> UIView? { card }
    func preferredSize(for menu: SuggestionMenu, of view: UIView, maxWidth: CGFloat) -> CGSize {
        CGSize(width: 200, height: 600)
    }
    func close(_ menu: SuggestionMenu, in textView: EditorTextView) {}
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
        let count = presenter.presented.count
        view.deleteBackward() // "/hea"
        type(view, "d")
        XCTAssertEqual(presenter.presented.count, count, "Escape meant it: still closed while typing on")
        XCTAssertNil(view.presentedSuggestionView)
        XCTAssertFalse(key(view, .keyboardEscape), "and Escape still goes to the host")

        // A new trigger opens a new menu; dismissing it in code keeps it shut too.
        for _ in 0..<5 { view.deleteBackward() } // the whole `/head`, still closed throughout
        XCTAssertEqual(presenter.presented.count, count)
        type(view, "/")
        let reopened = try XCTUnwrap(presenter.current)
        XCTAssertFalse(reopened === closed)
        reopened.dismiss()
        XCTAssertEqual(presenter.dismissals, 2)
        type(view, "h")
        XCTAssertTrue(presenter.current === reopened, "dismiss() keeps it shut the same way")
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

    func testRowsCarryAStableIDAndMetadata() throws {
        let item = SlashCommandItem(title: "Sign", keywords: ["sig"], id: "signature", metadata: ["hint": "⌘S"]) { _, _, _ in true }
        let editor = try Editor(extensions: starterKit() + [SlashMenuExtension(commands: [item] + defaultSlashCommands())])
        let view = EditorTextView(editor: editor, frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        view.layoutIfNeeded()
        view.suggestionPresenter = presenter
        type(view, "/")
        let first = try XCTUnwrap(presenter.current?.entries.first)
        XCTAssertEqual(first.id, "signature")
        XCTAssertEqual(first.metadata, ["hint": "⌘S"])
        XCTAssertEqual(presenter.current?.entries[1].id, "toggleHeading1", "a named command's id is its name")
    }

    func testWikiAndMentionRowsAreIdentifiedByWhatTheyInsert() throws {
        let view = try makeView(wikiLinks: { _ in ["Home"] }, mentions: { _ in ["Ada"] })
        type(view, "[[Ho")
        XCTAssertEqual(presenter.current?.entries.first?.id, "Home")
        XCTAssertTrue(key(view, .keyboardEscape))
        let other = try makeView(mentions: { _ in ["Ada"] })
        type(other, "@A")
        XCTAssertEqual(presenter.current?.entries.first?.title, "@Ada")
        XCTAssertEqual(presenter.current?.entries.first?.id, "Ada", "the name, without the @ it's drawn with")
    }

    func testTheHighlightFollowsTheRowsNotTheirTitles() throws {
        // Same ids → same rows, so the highlight stays; a different set resets it.
        let view = try makeView()
        type(view, "/head")
        let menu = try XCTUnwrap(presenter.current)
        menu.highlightedIndex = 2
        type(view, "i")
        XCTAssertEqual(menu.highlightedIndex, 2, "still Heading 1–3")
        view.deleteBackward(); view.deleteBackward(); view.deleteBackward(); view.deleteBackward()
        XCTAssertEqual(menu.highlightedIndex, 0, "the list changed")
    }

    func testAnUnmatchedQueryClosesTheMenuByDefault() throws {
        let view = try makeView()
        type(view, "/h")
        type(view, "zzz")
        XCTAssertEqual(presenter.dismissals, 1)
    }

    func testAPresenterCanShowNoResults() throws {
        presenter.presentsEmptyMenus = true
        let view = try makeView()
        type(view, "/h")
        let menu = try XCTUnwrap(presenter.current)
        type(view, "zzz")
        XCTAssertTrue(presenter.current === menu, "the same menu, still open")
        XCTAssertEqual(menu.entries.count, 0)
        XCTAssertEqual(menu.query, "hzzz")
        XCTAssertEqual(presenter.dismissals, 0)
        view.deleteBackward(); view.deleteBackward(); view.deleteBackward()
        XCTAssertEqual(menu.entries.first?.title, "Heading 1", "and it recovers as the query shortens")
    }

    func testAnEmptyMenuLeavesReturnToTheDocument() throws {
        presenter.presentsEmptyMenus = true
        let view = try makeView()
        type(view, "/zzz")
        view.insertText("\n")
        XCTAssertEqual(view.editor.doc.childCount, 2, "the line broke: there's nothing to choose")
        XCTAssertEqual(view.editor.doc.child(0).textContent, "/zzz")
        XCTAssertEqual(presenter.dismissals, 1, "the caret left the trigger")

        let other = try makeView()
        type(other, "/zzz")
        XCTAssertTrue(key(other, .keyboardReturnOrEnter))
        XCTAssertEqual(other.editor.doc.childCount, 2, "from a hardware keyboard too")
    }

    func testEscapeClosesAnEmptyMenu() throws {
        presenter.presentsEmptyMenus = true
        let view = try makeView()
        type(view, "/zzz")
        XCTAssertTrue(key(view, .keyboardEscape))
        XCTAssertEqual(presenter.dismissals, 1)
    }

    func testDecliningAnEmptyMenuDoesNotOpenThePopup() throws {
        presenter.presentsEmptyMenus = true
        presenter.accepts = { !$0.entries.isEmpty }
        let view = try makeView()
        type(view, "/h")
        type(view, "zzz")
        XCTAssertNil(view.suggestionTitles)
        XCTAssertEqual(presenter.dismissals, 1)
    }

    // MARK: Full control

    func testTheMenuKnowsItsRangeOriginAndEditor() throws {
        let view = try makeView()
        type(view, "/head")
        let menu = try XCTUnwrap(presenter.current)
        XCTAssertTrue(menu.editor === view.editor)
        XCTAssertTrue(menu.textView === view)
        XCTAssertEqual(view.editor.doc.textBetween(menu.from, menu.to), "/head", "the trigger and its query")
        XCTAssertLessThan(menu.originRect.minX, menu.caretRect.minX, "the origin is where the / is")
        XCTAssertEqual(menu.originRect.minY, menu.caretRect.minY, accuracy: 0.5)
    }

    func testReplaceQueryRunsThePresentersOwnCommand() throws {
        let view = try makeView(wikiLinks: { _ in ["Home"] })
        type(view, "see [[Arch")
        let menu = try XCTUnwrap(presenter.current)
        XCTAssertTrue(menu.replaceQuery(with: insertWikiLink(text: "Architecture", targetId: "p-7", targetType: "page")))
        var link: Node?
        view.editor.doc.descendants { node, _, _, _ in
            if node.type.name == "wikiLink" { link = node }
            return link == nil
        }
        XCTAssertEqual(link?.attrs["text"]?.stringValue, "Architecture")
        XCTAssertEqual(link?.attrs["targetId"]?.stringValue, "p-7")
        XCTAssertEqual(link?.attrs["targetType"]?.stringValue, "page")
        XCTAssertEqual(view.editor.doc.textContent.hasPrefix("see "), true)
        XCTAssertFalse(view.editor.doc.textContent.contains("[["), "the query went with it")
        XCTAssertEqual(presenter.dismissals, 1)
    }

    func testReplaceQueryWithAFailingCommandChangesNothing() throws {
        let view = try makeView()
        type(view, "/head")
        let menu = try XCTUnwrap(presenter.current)
        let before = view.editor.doc
        XCTAssertFalse(menu.replaceQuery(with: { _, _, _ in false }))
        XCTAssertEqual(view.editor.doc, before)
        XCTAssertEqual(presenter.dismissals, 0, "still open")
    }

    func testReplaceQueryAfterAnEditIsRefused() throws {
        let view = try makeView()
        type(view, "/h1")
        let menu = try XCTUnwrap(presenter.current)
        try view.editor.setContent(html: "<p>other text</p>")
        let before = view.editor.doc
        XCTAssertFalse(menu.replaceQuery(with: insertWikiLink(text: "X")))
        XCTAssertEqual(view.editor.doc, before)
    }

    func testEveryCallbackCarriesTheEditorAndTheTypedTextsPosition() throws {
        // The slash menu, end to end: open, type, a key, and the close a
        // choice brings, each told the editor and where `/hea` is.
        let inspector = InspectingPresenter()
        inspector.onKey = { key, menu in
            guard key == .enter else { return false }
            menu.choose(0) // Heading 1
            return true
        }
        let view = try makeView()
        view.suggestionPresenter = inspector
        type(view, "/")
        type(view, "hea")
        XCTAssertTrue(key(view, .keyboardReturnOrEnter))

        let callbacks = inspector.seen.map(\.callback)
        XCTAssertEqual(callbacks.first, "present")
        XCTAssertTrue(callbacks.contains("key"))
        XCTAssertEqual(callbacks.last, "close")
        for seen in inspector.seen {
            XCTAssertTrue(seen.editor === view.editor, "\(seen.callback) is given the editor")
            XCTAssertEqual(seen.from, 1, "\(seen.callback): the / is where the menu starts")
            XCTAssertLessThanOrEqual(seen.origin.minX, seen.caret.minX, "\(seen.callback): the origin is the /")
        }
        // While the text is there to read, `from..<to` is exactly what was typed.
        let open = inspector.seen.filter { $0.callback != "close" }
        XCTAssertEqual(open.filter { $0.callback != "place" }.map(\.text), ["/", "/h", "/he", "/hea", "/hea"])
        XCTAssertTrue(open.contains { $0.callback == "place" })
        XCTAssertEqual(open.last?.to, 5)
        XCTAssertGreaterThan(open.last!.caret.minX, open.first!.caret.minX, "the caret end follows the typing")
        XCTAssertEqual(inspector.seen.last?.to, 5, "and close still says where it was")
        XCTAssertTrue(view.editor.isActive(node: "heading", attrs: ["level": .int(1)]))
        XCTAssertEqual(view.editor.doc.textContent, "")
    }

    func testASlashPresenterCanActOverTheQueryItself() throws {
        // Not a row at all: the presenter's own command, over `/sig`.
        let inspector = InspectingPresenter()
        inspector.presentsEmptyMenus = true // `/sig` matches no command
        inspector.onKey = { key, menu in
            guard key == .enter, let editor = menu.editor else { return false }
            XCTAssertEqual(editor.doc.textBetween(menu.from, menu.to), "/sig")
            return menu.replaceQuery { state, dispatch, _ in
                guard let tr = try? state.tr.insertText("— signed") else { return false }
                dispatch?(tr)
                return true
            }
        }
        let view = try makeView()
        view.suggestionPresenter = inspector
        type(view, "/sig")
        XCTAssertTrue(key(view, .keyboardReturnOrEnter))
        XCTAssertEqual(view.editor.doc.textContent, "— signed")
        XCTAssertEqual(inspector.seen.last?.callback, "close")
    }

    func testThePresenterHasFirstSayOverKeys() throws {
        presenter.takes = { key, _ in key == .down || key == .left }
        let view = try makeView()
        type(view, "/head")
        let menu = try XCTUnwrap(presenter.current)
        XCTAssertTrue(key(view, .keyboardDownArrow))
        XCTAssertEqual(menu.highlightedIndex, 0, "taken: the editor didn't move the highlight")
        XCTAssertTrue(key(view, .keyboardUpArrow))
        XCTAssertEqual(menu.highlightedIndex, 2, "left to the editor: it wrapped")
        XCTAssertTrue(key(view, .keyboardLeftArrow))
        XCTAssertEqual(view.editor.state.selection.from, menu.to, "taken: the caret stayed put")
        XCTAssertEqual(presenter.keys, [.down, .up, .left])
    }

    func testAPresenterCanTakeReturnFromEitherKeyboard() throws {
        presenter.presentsEmptyMenus = true
        var entered = 0
        presenter.takes = { key, menu in
            guard key == .enter else { return false }
            entered += 1
            return menu.replaceQuery(with: insertWikiLink(text: menu.query))
        }
        let view = try makeView()
        type(view, "x [[New page")
        view.insertText("\n") // the on-screen keyboard
        XCTAssertEqual(entered, 1)
        XCTAssertEqual(view.editor.doc.childCount, 1, "no line break")
        XCTAssertEqual(view.editor.doc.textContent, "x New page")

        let other = try makeView()
        type(other, "x [[Other")
        XCTAssertTrue(key(other, .keyboardReturnOrEnter))
        XCTAssertEqual(entered, 2)
    }

    func testKeysThePresenterDeclinesBehaveAsBefore() throws {
        let view = try makeView()
        type(view, "/h1")
        XCTAssertTrue(key(view, .keyboardTab))
        XCTAssertTrue(view.editor.isActive(node: "heading", attrs: ["level": .int(1)]))
        XCTAssertEqual(presenter.keys, [.tab])
    }

    func testClosingNamesTheMenuThatClosed() throws {
        let closing = ClosingPresenter()
        let view = try makeView()
        view.suggestionPresenter = closing
        type(view, "/head")
        let menu = try XCTUnwrap(closing.shown)
        XCTAssertTrue(key(view, .keyboardEscape))
        XCTAssertEqual(closing.closed.count, 1)
        XCTAssertTrue(closing.closed.first === menu)
    }

    func testTheRawSourceOffersEverythingToSiftYourself() throws {
        // A presenter that filters its own way: ask the source for every row,
        // then rank by its own rule — here, titles that start with the query.
        let view = try makeView()
        type(view, "/list")
        let menu = try XCTUnwrap(presenter.current)
        XCTAssertEqual(menu.entries.map(\.title), ["Bullet List", "Numbered List", "Task List"],
                       "the editor's filter: keywords match too")
        let everything = menu.source.entries("", view.editor)
        XCTAssertGreaterThan(everything.count, menu.entries.count)
        let mine = everything.filter { $0.title.lowercased().hasPrefix("t") }
        XCTAssertEqual(mine.map(\.title), ["Task List"])
        mine[0].apply(view.editor)
        XCTAssertTrue(view.editor.isActive(node: "taskList"), "a raw row still applies over the menu's range")
        XCTAssertFalse(view.editor.doc.textContent.contains("/list"))
    }

    func testChangesSayWhatMoved() throws {
        let view = try makeView()
        type(view, "/")
        XCTAssertEqual(presenter.changes.last, .opened)
        type(view, "h")
        XCTAssertTrue(presenter.changes.last!.contains(.query))
        XCTAssertTrue(presenter.changes.last!.contains(.entries))
        XCTAssertTrue(key(view, .keyboardDownArrow))
        XCTAssertEqual(presenter.changes.last, .highlight)
        let count = presenter.presented.count
        view.contentOffsetY += 10
        XCTAssertEqual(presenter.presented.count, count, "a scroll re-places; nothing to present")
    }

    func testAPresenterHearsEveryQueryWithoutAProvider() throws {
        // No `[[` suggestions configured: the built-in popup never opens, but a
        // presenter searching for itself is still told what's typed.
        presenter.presentsEmptyMenus = true
        let view = try makeView()
        type(view, "[[Ro")
        XCTAssertEqual(presenter.current?.trigger, "[[")
        XCTAssertEqual(presenter.current?.query, "Ro")
        XCTAssertEqual(presenter.current?.entries.count, 0)
        type(view, "ad")
        XCTAssertEqual(presenter.current?.query, "Road")

        let plain = try makeView()
        plain.suggestionPresenter = nil
        type(plain, "[[Ro")
        XCTAssertNil(plain.suggestionTitles, "and without a presenter, still nothing")
    }

    func testLoadingIsReportedWhileAnAsyncSearchRuns() throws {
        presenter.presentsEmptyMenus = true
        let editor = try Editor(extensions: fullKit(wikiLinkAsyncSuggestions: { query in
            try? await Task.sleep(for: .milliseconds(20))
            return ["Roadmap"].filter { $0.localizedCaseInsensitiveContains(query) }
        }))
        let view = EditorTextView(editor: editor, frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        view.layoutIfNeeded()
        view.suggestionPresenter = presenter
        type(view, "[[Ro")
        let menu = try XCTUnwrap(presenter.current)
        XCTAssertTrue(menu.isLoading, "searching, not \"no results\"")
        XCTAssertEqual(menu.entries.count, 0)
        let done = expectation(description: "results arrive")
        Task { @MainActor in
            while menu.isLoading { try? await Task.sleep(for: .milliseconds(10)) }
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(menu.entries.map(\.title), ["Roadmap"])
        XCTAssertTrue(presenter.changes.last!.contains(.loading))
    }

    func testScrollingMovesTheViewWithoutPresentingAgain() throws {
        let view = try makeView()
        type(view, "/head")
        let menu = try XCTUnwrap(presenter.current)
        let frame = presenter.view.frame
        let count = presenter.presented.count, places = presenter.placed.count
        view.contentOffsetY += 30
        XCTAssertEqual(presenter.presented.count, count)
        XCTAssertEqual(presenter.placed.count, places + 1, "didPlace says where it went")
        XCTAssertEqual(presenter.view.frame.minY, frame.minY - 30, accuracy: 0.5)
        XCTAssertEqual(menu.frame, presenter.view.frame)
    }

    // MARK: The editor places the presenter's view

    /// A view in a window of its own, `lines` paragraphs down.
    private func windowed(_ frame: CGRect = CGRect(x: 0, y: 0, width: 390, height: 844),
                          lines: Int = 0) throws -> (EditorTextView, UIWindow) {
        let view = try makeView()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        view.frame = frame
        window.addSubview(view)
        window.makeKeyAndVisible()
        view.layoutIfNeeded()
        for _ in 0..<lines { view.insertText("\n") }
        return (view, window)
    }

    func testTheEditorShowsSizesAndPlacesTheView() throws {
        let (view, window) = try windowed()
        defer { window.isHidden = true }
        type(view, "/")
        let menu = try XCTUnwrap(presenter.current)
        XCTAssertTrue(presenter.view.superview === view.overlayHost, "above everything, unclipped")
        XCTAssertEqual(presenter.view.frame.size, CGSize(width: 200, height: 100), "the size it asked for")
        let caret = view.convert(menu.caretRect, to: window), origin = view.convert(menu.originRect, to: window)
        XCTAssertEqual(presenter.view.frame.minY, caret.maxY + 4, accuracy: 0.5, "just below the line")
        XCTAssertEqual(presenter.view.frame.minX, max(origin.minX, 4), accuracy: 0.5, "under the /")
        XCTAssertEqual(menu.placement, .below)
        XCTAssertEqual(menu.anchorRect.minX, menu.originRect.minX)
        XCTAssertEqual(menu.frame, presenter.view.frame)
        XCTAssertTrue(key(view, .keyboardEscape))
        XCTAssertNil(presenter.view.superview, "and takes it down")
    }

    func testEveryEventCarriesTheAnchor() throws {
        // `present` sees where the menu will hang from; `didPlace` sees where it went.
        let (view, window) = try windowed()
        defer { window.isHidden = true }
        type(view, "/he")
        let menu = try XCTUnwrap(presenter.current)
        XCTAssertEqual(menu.anchorRect.minX, menu.originRect.minX, "the / …")
        XCTAssertEqual(menu.anchorRect.minY, menu.caretRect.minY, "… on the caret's line")
        XCTAssertFalse(presenter.placed.isEmpty)
        for place in presenter.placed { XCTAssertGreaterThan(place.anchor.height, 0) }
        XCTAssertEqual(presenter.placed.last?.anchor, menu.anchorRect)
    }

    func testTheMenuStaysPutWhileTyping() throws {
        // Hung from the trigger (the default), the menu doesn't slide along
        // with every character; hung from the caret, it does.
        let (view, window) = try windowed()
        defer { window.isHidden = true }
        type(view, "/")
        let x = presenter.view.frame.minX
        type(view, "hea")
        XCTAssertEqual(presenter.view.frame.minX, x, "still under the /")

        presenter.anchor = .caret
        let (other, otherWindow) = try windowed()
        defer { otherWindow.isHidden = true }
        other.suggestionPresenter = presenter
        type(other, "/")
        let start = presenter.view.frame.minX
        type(other, "hea")
        XCTAssertGreaterThan(presenter.view.frame.minX, start, "with .caret, it follows")
    }

    func testAWrappedQueryHangsFromTheCaretsLine() throws {
        // Once a `[[` query wraps, the trigger is a line up: a menu under it
        // would sit on top of the text being typed.
        presenter.presentsEmptyMenus = true
        let (view, window) = try windowed(CGRect(x: 0, y: 0, width: 180, height: 844))
        defer { window.isHidden = true }
        type(view, "see [[")
        var menu = try XCTUnwrap(presenter.current)
        for word in ["alpha ", "bravo ", "charlie ", "delta ", "echo ", "foxtrot "] {
            type(view, word)
            menu = try XCTUnwrap(presenter.current)
            if menu.caretRect.minY > menu.originRect.maxY { break }
        }
        XCTAssertGreaterThan(menu.caretRect.minY, menu.originRect.maxY, "the query wrapped")
        XCTAssertEqual(menu.anchorRect, menu.caretRect)
        XCTAssertGreaterThan(presenter.view.frame.minY, view.convert(menu.caretRect, to: window).maxY)
    }

    func testTheMenuCanHangFromTheTrigger() throws {
        presenter.anchor = .trigger
        presenter.presentsEmptyMenus = true // no `[[` provider: hear the query anyway
        let (view, window) = try windowed()
        defer { window.isHidden = true }
        type(view, "x [[Arch")
        let menu = try XCTUnwrap(presenter.current)
        XCTAssertEqual(menu.anchorRect.minX, menu.originRect.minX)
        let origin = view.convert(menu.originRect, to: window)
        XCTAssertEqual(presenter.view.frame.minX, origin.minX, accuracy: 0.5, "under the [[, not the caret")
        XCTAssertLessThan(menu.originRect.minX, menu.caretRect.minX)
    }

    func testAutoFlipsAboveWhenThereIsNoRoomBelow() throws {
        presenter.size = CGSize(width: 200, height: 300)
        let (view, window) = try windowed(lines: 18) // the caret low in the window
        defer { window.isHidden = true }
        type(view, "/")
        let menu = try XCTUnwrap(presenter.current)
        XCTAssertEqual(menu.placement, .above)
        XCTAssertEqual(presenter.view.frame.maxY, view.convert(menu.caretRect, to: window).minY - 4, accuracy: 0.5)
        XCTAssertEqual(presenter.view.frame.height, 300, "it fits there whole")
    }

    func testAutoPrefersTheTextViewsOwnVisibleArea() throws {
        // A text view in the middle of the window, under the host's own bars,
        // and a caret where the menu fits below only by hanging past the text
        // view's bottom, but fits above inside it: above. Line heights vary by
        // device, so walk the caret down to that spot rather than guess.
        presenter.size = CGSize(width: 200, height: 300)
        let (view, window) = try windowed(CGRect(x: 0, y: 100, width: 390, height: 600))
        defer { window.isHidden = true }
        var found: (menu: SuggestionMenu, caret: CGRect)?
        for _ in 0..<40 {
            type(view, "/")
            let menu = try XCTUnwrap(presenter.current)
            let caret = view.convert(menu.caretRect, to: window)
            if caret.minY - 4 - 300 >= 104 { found = (menu, caret); break }
            view.deleteBackward()
            view.insertText("\n")
        }
        let (menu, caret) = try XCTUnwrap(found)
        XCTAssertLessThanOrEqual(caret.maxY + 4 + 300, 840, "the case: room below in the window…")
        XCTAssertGreaterThan(caret.maxY + 4 + 300, 696, "…but not inside the text view…")
        XCTAssertGreaterThanOrEqual(caret.minY - 4 - 300, 104, "…and room above inside it")
        XCTAssertEqual(menu.placement, .above)
        XCTAssertGreaterThanOrEqual(presenter.view.frame.minY, 104, "inside the text view")
    }

    func testAutoLeavesTheVisibleAreaRatherThanBeCutShort() throws {
        // A short text view: the menu fits nowhere inside it, so it uses the window.
        presenter.size = CGSize(width: 200, height: 300)
        let (view, window) = try windowed(CGRect(x: 0, y: 300, width: 390, height: 120))
        defer { window.isHidden = true }
        type(view, "/")
        XCTAssertEqual(presenter.current?.placement, .below)
        XCTAssertEqual(presenter.view.frame.height, 300, "whole, past the text view's bottom")
        XCTAssertGreaterThan(presenter.view.frame.maxY, 420)
    }

    func testPositionCanBeForced() throws {
        presenter.position = .above
        let (view, window) = try windowed(lines: 2)
        defer { window.isHidden = true }
        type(view, "/")
        let menu = try XCTUnwrap(presenter.current)
        XCTAssertEqual(menu.placement, .above, "above, though there's room below")
        XCTAssertLessThan(presenter.view.frame.height, 100, "shortened to the room up there")
        XCTAssertGreaterThanOrEqual(presenter.view.frame.minY, window.safeAreaInsets.top + 4)

        presenter.position = .below
        let (low, other) = try windowed(lines: 18)
        defer { other.isHidden = true }
        presenter.size = CGSize(width: 200, height: 400)
        low.suggestionPresenter = presenter
        type(low, "/")
        XCTAssertEqual(presenter.current?.placement, .below, "below, though there's room above")
        XCTAssertLessThanOrEqual(presenter.view.frame.maxY, 840 + 0.5) // window-space rounding
    }

    func testInvalidateSizeMeasuresAgain() throws {
        let (view, window) = try windowed()
        defer { window.isHidden = true }
        type(view, "/")
        let menu = try XCTUnwrap(presenter.current)
        presenter.size = CGSize(width: 240, height: 160)
        XCTAssertEqual(presenter.view.frame.height, 100, "not until asked")
        menu.invalidateSize()
        XCTAssertEqual(presenter.view.frame.size, CGSize(width: 240, height: 160))
    }
}
#endif

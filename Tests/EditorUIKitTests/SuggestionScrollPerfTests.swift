#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

/// Scrolling with a suggestion popup open.
///
/// A suggestion source's `entries` is a synchronous host call — a wiki-link
/// source searches the host's notes for the query. Scrolling changes neither
/// the document nor the selection, so the answer cannot change; the scroll path
/// used to ask anyway, once per tick, and re-solve the popup card's Auto Layout
/// for a size that hadn't changed either. The popup still has to *move* with the
/// content, so what's asserted here is that it moves without re-pulling.
@MainActor
final class SuggestionScrollPerfTests: XCTestCase {
    /// Counts how many times the host's suggestion closure is asked. A class
    /// because the closure is `@Sendable` and the counting is main-actor only.
    private final class QueryCount: @unchecked Sendable {
        var n = 0
        var queries: [String] = []
    }

    private func makeView(_ count: QueryCount, paragraphs: Int = 200) throws -> EditorTextView {
        let editor = try Editor(extensions: fullKit(wikiLinkSuggestions: { query in
            count.n += 1
            count.queries.append(query)
            // A host source does its own filtering — that is the work this
            // test is counting, and the reason a per-frame pull is not free.
            return ["Alpha", "Alphabet", "Alpine"]
                .filter { query.isEmpty || $0.lowercased().hasPrefix(query.lowercased()) }
        }))
        let s = editor.schema
        let words = Array(repeating: "lorem ipsum dolor sit amet", count: 12).joined(separator: " ")
        let paras = (0 ..< paragraphs).map { i in
            try! s.node("paragraph", [:], content: Fragment.from([s.text("Para \(i): \(words)")]))
        }
        editor.setContent(try s.node("doc", [:], content: Fragment.from(paras)))
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        view.layoutIfNeeded()
        _ = view.becomeFirstResponder()
        return view
    }

    private func type(_ view: EditorTextView, _ text: String) {
        for ch in text { view.insertText(String(ch)) }
    }

    func testScrollingWithAnOpenMenuNeverRePullsTheSource() throws {
        let count = QueryCount()
        let view = try makeView(count)
        type(view, "[[Al")
        XCTAssertNotNil(view.suggestionTitles, "the popup should be open")

        let afterTyping = count.n
        XCTAssertGreaterThan(afterTyping, 0, "typing the query must pull the source")

        for i in 1 ... 60 { view.contentOffsetY = CGFloat(i) * 8 }

        XCTAssertEqual(count.n, afterTyping, "scrolling must not ask the host for entries again")
        XCTAssertNotNil(view.suggestionTitles, "and the popup must stay open")
    }

    func testScrollingWithNoMenuOpenNeverPullsTheSource() throws {
        let count = QueryCount()
        let view = try makeView(count)
        type(view, "plain text")
        let afterTyping = count.n

        for i in 1 ... 60 { view.contentOffsetY = CGFloat(i) * 8 }

        XCTAssertEqual(count.n, afterTyping, "no trigger is active; nothing to ask about")
        XCTAssertNil(view.suggestionTitles)
    }

    /// The popup is anchored to the caret in *viewport* coordinates, so it has
    /// to travel with the content — not re-pulling must not mean not moving.
    func testThePopupStillFollowsTheContentAsItScrolls() throws {
        let count = QueryCount()
        let view = try makeView(count)
        type(view, "[[Al")
        let popup = try XCTUnwrap(view.subviews.compactMap { $0 as? SuggestionPopupView }.first
            ?? view.overlayHost.subviews.compactMap { $0 as? SuggestionPopupView }.first)

        let before = popup.frame
        view.contentOffsetY = 120
        let after = popup.frame

        XCTAssertEqual(after.height, before.height, accuracy: 0.5, "the card is unchanged")
        XCTAssertEqual(after.minY, before.minY - 120, accuracy: 0.5,
                       "it moves up with the content it is anchored to")
    }

    /// Not re-pulling on scroll must not leak into the paths that *should*
    /// pull: after a scroll, typing another character still refilters.
    func testTypingAfterAScrollStillRePullsAndRefilters() throws {
        let count = QueryCount()
        let view = try makeView(count)
        type(view, "[[Al")
        for i in 1 ... 20 { view.contentOffsetY = CGFloat(i) * 8 }
        let afterScroll = count.n

        type(view, "pi")

        XCTAssertGreaterThan(count.n, afterScroll, "an edit pulls the source again")
        XCTAssertEqual(count.queries.last, "Alpi", "with the query as typed")
        XCTAssertEqual(view.suggestionTitles, ["Alpine"], "and the popup refilters")
    }
}
#endif

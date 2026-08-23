#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

/// `theme.wikiLink.trigger`: the `[[…` still being typed — set apart from the
/// prose it sits in, and optionally closed by brackets that aren't in the
/// document.
///
/// Inert by default: an unstyled theme leaves the typed text exactly as it was,
/// and never reaches the layout at all.
@MainActor
final class WikiLinkTriggerTests: XCTestCase {
    private func makeView(_ configure: (inout DocumentTheme) -> Void = { _ in }) throws -> EditorTextView {
        let editor = try Editor(extensions: fullKit())
        editor.setContent(try editor.schema.node("doc", [:], content: Fragment.from([
            try editor.schema.node("paragraph", [:], content: Fragment.empty),
        ])))
        let view = EditorTextView(editor: editor)
        var theme = DocumentTheme()
        configure(&theme)
        view.theme = theme
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        view.layoutIfNeeded()
        _ = view.becomeFirstResponder()
        return view
    }

    private func type(_ view: EditorTextView, _ text: String) { for ch in text { view.insertText(String(ch)) } }

    /// Type `[[Page` in the middle of a line, leaving " after" past the cursor —
    /// the shape that has the ghost sit inside the text rather than at the end
    /// of it.
    private func typeMidLine(_ view: EditorTextView) {
        type(view, "before  after")
        let editor = view.editor
        let tr = editor.state.tr
        tr.setSelection(TextSelection.near(editor.doc.resolve(8)))
        editor.dispatch(tr)
        type(view, "[[Page")
    }

    private func moveCaret(_ view: EditorTextView, to pos: Int) {
        let editor = view.editor
        editor.dispatch(editor.state.tr.setSelection(TextSelection.near(editor.doc.resolve(pos))))
    }

    private func rendered(_ view: EditorTextView) throws -> NSAttributedString {
        try XCTUnwrap(view.ensureLayout().blocks.first).attributed
    }

    /// The alpha the label is actually painted with at the given character.
    private func alpha(_ text: NSAttributedString, at index: Int) -> CGFloat {
        let color = unsafe text.attribute(.foregroundColor, at: index, effectiveRange: nil) as? UIColor
        let resolved = (color ?? .label).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        return resolved.cgColor.alpha
    }

    func testDefaultThemeLeavesTheTypedTextAlone() throws {
        let view = try makeView()
        type(view, "a [[Page")
        XCTAssertNotNil(view.editor.wikiLinkSuggestion, "the popup's query should be open")
        let text = try rendered(view)
        XCTAssertEqual(text.string, "a [[Page", "no ghost brackets, no substitutions")
        XCTAssertEqual(alpha(text, at: 2), alpha(text, at: 0), accuracy: 0.01)
    }

    /// Only the brackets fade by default — the query is what you're reading
    /// while you type it.
    func testOpacityFadesTheBracketsAndNotTheQuery() throws {
        let view = try makeView { $0.wikiLink.trigger.opacity = 0.4 }
        type(view, "a [[Page")
        let text = try rendered(view)
        let plain = alpha(text, at: 0)
        XCTAssertEqual(alpha(text, at: 2), plain * 0.4, accuracy: 0.02, "the opening bracket should fade")
        XCTAssertEqual(alpha(text, at: 3), plain * 0.4, accuracy: 0.02)
        XCTAssertEqual(alpha(text, at: 4), plain, accuracy: 0.02, "the query should not")
    }

    func testIncludesQueryFadesTheWholeTrigger() throws {
        let view = try makeView {
            $0.wikiLink.trigger.opacity = 0.4
            $0.wikiLink.trigger.includesQuery = true
        }
        type(view, "a [[Page")
        let text = try rendered(view)
        XCTAssertEqual(alpha(text, at: 4), alpha(text, at: 0) * 0.4, accuracy: 0.02)
    }

    func testColorOverridesTheTextsOwn() throws {
        let view = try makeView { $0.wikiLink.trigger.color = .systemPink }
        type(view, "[[Page")
        let text = try rendered(view)
        let color = unsafe text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        XCTAssertEqual(color, .systemPink)
        XCTAssertNotEqual(unsafe text.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? UIColor, .systemPink,
                          "the query keeps its own colour unless asked for")
    }

    /// The closing brackets are drawn, not typed: the document still holds only
    /// what the reader wrote.
    func testGhostBracketsAreDrawnButNotInTheDocument() throws {
        let view = try makeView { $0.wikiLink.trigger.showsClosingBrackets = true }
        type(view, "[[Page")
        XCTAssertEqual(view.editor.doc.textContent, "[[Page")
        XCTAssertEqual(try rendered(view).string, "[[Page]]")
    }

    /// A space after the opening brackets is mirrored before the closing ones —
    /// and not doubled once the reader types it themselves.
    func testGhostBracketsMirrorTheSpacesAfterTheOpening() throws {
        for (typed, expected) in [("[[Page", "[[Page]]"),
                                  ("[[ Page", "[[ Page ]]"),
                                  ("[[  Page", "[[  Page  ]]"),
                                  ("[[   Page", "[[   Page   ]]"),
                                  // The brackets hug the word, so a space typed
                                  // after it stays outside them.
                                  ("[[ Page ", "[[ Page ]] "),
                                  ("[[", "[[]]"),
                                  ("[[ ", "[[ ]]")] {
            let view = try makeView { $0.wikiLink.trigger.showsClosingBrackets = true }
            type(view, typed)
            XCTAssertEqual(try rendered(view).string, expected, "typed \(typed)")
        }
    }

    /// The brackets hold the end of the word, not the caret: arrowing back
    /// through a query mustn't drag them — and the text after them — along.
    func testGhostBracketsStayPutAsTheCaretMovesThroughTheQuery() throws {
        let view = try makeView { $0.wikiLink.trigger.showsClosingBrackets = true }
        typeMidLine(view)
        XCTAssertEqual(try rendered(view).string, "before [[Page]] after")
        let end = try XCTUnwrap(view.editor.wikiLinkSuggestion).to

        // Left through "Page", one position at a time, then back out to the end.
        for caret in stride(from: end - 1, through: end - 4, by: -1) {
            moveCaret(view, to: caret)
            XCTAssertNotNil(view.editor.wikiLinkSuggestion, "the trigger should stay open at \(caret)")
            XCTAssertEqual(try rendered(view).string, "before [[Page]] after",
                           "the brackets moved with the caret at \(caret)")
        }
        // And out the far side: past the space, the word it hugs is behind it.
        moveCaret(view, to: end + 1)
        XCTAssertEqual(try rendered(view).string, "before [[Page]] after",
                       "the brackets moved when the caret left the word")
    }

    /// Pressing right at the end of the query is the case that gave this away:
    /// the brackets followed the caret, so every keypress shifted the line.
    func testPressingRightDoesNotMoveTheGhost() throws {
        let view = try makeView { $0.wikiLink.trigger.showsClosingBrackets = true }
        typeMidLine(view)
        let layout = view.ensureLayout()
        let tail = try XCTUnwrap(layout.caretRect(at: layout.blocks.first!.contentEnd))
        let end = try XCTUnwrap(view.editor.wikiLinkSuggestion).to
        moveCaret(view, to: end + 1)
        let after = view.ensureLayout()
        XCTAssertEqual(try XCTUnwrap(after.caretRect(at: after.blocks.first!.contentEnd)).minX,
                       tail.minX, accuracy: 0.5, "the line reflowed when the caret moved")
    }

    /// The ghost sits at the cursor, so text after it reflows rather than being
    /// painted over — and the caret stays in front of it.
    func testGhostPushesTheTextAfterItAlong() throws {
        let plain = try makeView()
        let view = try makeView { $0.wikiLink.trigger.showsClosingBrackets = true }
        for v in [plain, view] { typeMidLine(v) }
        XCTAssertNotNil(view.editor.wikiLinkSuggestion)
        XCTAssertEqual(try rendered(view).string, "before [[Page]] after")

        let end = try XCTUnwrap(view.ensureLayout().blocks.first).contentEnd
        let caret = try XCTUnwrap(view.ensureLayout().caretRect(at: end))
        XCTAssertGreaterThan(caret.minX, try XCTUnwrap(plain.ensureLayout().caretRect(at: end)).minX,
                             "the ghost takes real space on the line")
        // The cursor is before the ghost.
        let cursor = try XCTUnwrap(view.editor.wikiLinkSuggestion).to
        let ghost = try XCTUnwrap(view.ensureLayout().caretRect(at: cursor))
        XCTAssertEqual(ghost.minX, try XCTUnwrap(plain.ensureLayout().caretRect(at: cursor)).minX, accuracy: 0.5,
                       "the caret should draw in front of the brackets it hasn't typed")
    }

    /// Nothing in the document may map into the ghost: every position round
    /// trips through the attributed string it isn't part of.
    func testEveryPositionStillMapsAcrossTheGhost() throws {
        let view = try makeView { $0.wikiLink.trigger.showsClosingBrackets = true }
        typeMidLine(view)
        XCTAssertEqual(try rendered(view).string, "before [[Page]] after")
        let block = try XCTUnwrap(view.ensureLayout().blocks.first)
        for pos in block.contentStart...block.contentEnd {
            XCTAssertEqual(block.docPos(forAttrIndex: block.attrIndex(forDocPos: pos)), pos, "position \(pos)")
        }
    }

    /// Moving the cursor out closes the trigger without touching the document —
    /// the layout has to notice a change that isn't an edit.
    func testMovingTheCursorAwayClearsTheGhost() throws {
        let view = try makeView {
            $0.wikiLink.trigger.showsClosingBrackets = true
            $0.wikiLink.trigger.opacity = 0.4
        }
        type(view, "before [[Page")
        XCTAssertEqual(try rendered(view).string, "before [[Page]]")
        let editor = view.editor
        let tr = editor.state.tr
        tr.setSelection(TextSelection.near(editor.doc.resolve(1)))
        editor.dispatch(tr)
        XCTAssertNil(editor.wikiLinkSuggestion)
        let text = try rendered(view)
        XCTAssertEqual(text.string, "before [[Page", "the ghost should go with the trigger")
        XCTAssertEqual(alpha(text, at: 8), alpha(text, at: 0), accuracy: 0.02, "and so should the fade")
    }

    /// Accepting the suggestion is what actually writes the link: the ghost was
    /// never content, so nothing of it survives into the chip.
    func testAcceptingLeavesNoGhostBehind() throws {
        let view = try makeView { $0.wikiLink.trigger.showsClosingBrackets = true }
        type(view, "[[Page")
        XCTAssertTrue(view.editor.acceptWikiLinkSuggestion(text: "Page"))
        XCTAssertNil(view.editor.wikiLinkSuggestion)
        XCTAssertEqual(try rendered(view).string, "Page", "the chip's label, and nothing else")
    }
}
#endif

#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

/// Exercises the `UITextInput` conformance the way the system text-input engine
/// does: reading text, replacing ranges, IME marked-text composition, and
/// geometry/position arithmetic.
@MainActor
final class UITextInputTests: XCTestCase {
    private func makeView(_ text: String = "hello world") throws -> EditorTextView {
        let editor = try Editor(extensions: fullKit())
        let para = try! editor.schema.node("paragraph", [:], content: Fragment.from(text.isEmpty ? [] : [editor.schema.text(text)]))
        editor.setContent(try! editor.schema.node("doc", [:], content: Fragment.from([para])))
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        view.layoutIfNeeded()
        return view
    }
    private func range(_ from: Int, _ to: Int) -> DocTextRange { DocTextRange(from, to) }

    func testTextInRange() throws {
        let view = try makeView("hello world")
        XCTAssertEqual(view.text(in: range(1, 6)), "hello")
        XCTAssertEqual(view.text(in: range(7, 12)), "world")
    }

    /// Replacing a (double-tap) selection must collapse to a caret *after* the
    /// inserted text, so the next keystroke appends instead of replacing it —
    /// otherwise typed characters get "eaten".
    func testReplaceCollapsesCaretSoTypingDoesNotEat() throws {
        let view = try makeView("hello world")
        view.replace(range(1, 6), withText: "Hi") // replace the selected word "hello"
        XCTAssertEqual(view.editor.doc.textContent, "Hi world")
        let caret = try XCTUnwrap(view.selectedTextRange as? DocTextRange)
        XCTAssertTrue(caret.isEmpty, "selection should collapse to a caret")
        XCTAssertEqual(caret.from, 3, "caret sits right after the inserted text")
        // The next system edit (typing) must append, not replace the new text.
        view.replace(view.selectedTextRange!, withText: "!")
        XCTAssertEqual(view.editor.doc.textContent, "Hi! world")
    }

    /// The reported bug: double-tap a word, then type. The first character must
    /// replace the whole word; each subsequent character appends (no eating).
    func testTypingOverDoubleTappedWordReplacesThenAppends() throws {
        let view = try makeView("hello world")
        view.selectedTextRange = range(1, 6) // double-tap selects "hello"
        view.insertText("X")
        XCTAssertEqual(view.editor.doc.textContent, "X world", "first char replaces the word")
        let caret = try XCTUnwrap(view.selectedTextRange as? DocTextRange)
        XCTAssertTrue(caret.isEmpty)
        XCTAssertEqual(caret.from, 2, "caret after the inserted character")
        view.insertText("Y")
        view.insertText("Z")
        XCTAssertEqual(view.editor.doc.textContent, "XYZ world", "subsequent chars append")
    }

    /// Regression (crash): deleting a selection that runs from inside a nested
    /// block out to a shallower position used to trap (out-of-bounds) in the
    /// model's `deleteRange`. This is the exact path the system's autocorrect
    /// "delete-and-reinsert" hit.
    func testDeleteBackwardOverCrossDepthSelectionDoesNotCrash() throws {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        editor.setContent(try! s.node("doc", [:], content: Fragment.from([
            try! s.node("blockquote", [:], content: Fragment.from([
                try! s.node("paragraph", [:], content: Fragment.from([s.text("hello")])),
            ])),
            try! s.node("paragraph", [:], content: Fragment.from([s.text("world")])),
        ])))
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        view.layoutIfNeeded()
        let end = editor.doc.content.size
        // Inside the quoted paragraph (deep) → the document end (shallow).
        editor.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.doc, 4, end)))
        view.deleteBackward()
        XCTAssertLessThan(editor.doc.content.size, end)
        XCTAssertTrue(editor.state.selection.empty)
    }

    /// Even replacing an empty (zero-width) selection must not leave the inserted
    /// character selected.
    func testReplaceEmptySelectionInsertsAndAdvancesCaret() throws {
        let view = try makeView("ab")
        view.replace(range(2, 2), withText: "X") // insert between a and b
        XCTAssertEqual(view.editor.doc.textContent, "aXb")
        let caret = try XCTUnwrap(view.selectedTextRange as? DocTextRange)
        XCTAssertTrue(caret.isEmpty)
        XCTAssertEqual(caret.from, 3)
    }

    /// The invariant UIKit relies on: text length must equal the position offset
    /// difference, even across block boundaries (otherwise inserts land on the
    /// wrong line during fast typing).
    func testTextLengthMatchesOffsetAcrossBlocks() throws {
        let editor = try Editor(extensions: fullKit())
        func para(_ s: String) -> Node {
            try! editor.schema.node("paragraph", [:], content: Fragment.from([editor.schema.text(s)]))
        }
        editor.setContent(try! editor.schema.node("doc", [:], content: Fragment.from([para("alpha"), para("bravo"), para("charlie")])))
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        let size = editor.doc.content.size
        // Whole document: char count == position span.
        let whole = view.text(in: DocTextRange(0, size))
        XCTAssertEqual(whole?.count, size)
        XCTAssertEqual(view.offset(from: view.beginningOfDocument, to: view.endOfDocument), size)
        // Every sub-range too.
        for from in 0...size {
            for to in from...size {
                XCTAssertEqual(view.text(in: DocTextRange(from, to))?.count, to - from, "text length must equal offset for [\(from),\(to)]")
            }
        }
        // Within a block, the projection is the real text.
        let bravoStart = editor.doc.content.size // locate "bravo"
        var pos = 0
        editor.doc.descendants { n, p, _, _ in if n.isText, n.text == "bravo" { pos = p }; return true }
        _ = bravoStart
        XCTAssertEqual(view.text(in: DocTextRange(pos, pos + 5)), "bravo")
    }

    func testReplaceRangeEditsDocument() throws {
        let view = try makeView("hello world")
        view.replace(range(1, 6), withText: "HELLO")
        XCTAssertEqual(view.editor.doc.textContent, "HELLO world")
    }

    func testSelectedTextRangeRoundTrips() throws {
        let view = try makeView("hello world")
        view.selectedTextRange = range(1, 6)
        let sel = try XCTUnwrap(view.selectedTextRange as? DocTextRange)
        XCTAssertEqual(sel.from, 1)
        XCTAssertEqual(sel.to, 6)
        XCTAssertEqual(view.editor.state.selection.from, 1)
        XCTAssertEqual(view.editor.state.selection.to, 6)
    }

    func testMarkedTextCompositionThenCommit() throws {
        let view = try makeView("")
        // Compose "n" → "ni" → "ní" (as an IME would), then commit "你".
        view.setMarkedText("n", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertNotNil(view.markedTextRange)
        XCTAssertEqual(view.editor.doc.textContent, "n")
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertEqual(view.editor.doc.textContent, "ni")
        let marked = try XCTUnwrap(view.markedTextRange as? DocTextRange)
        XCTAssertEqual(view.text(in: marked), "ni")
        // Commit.
        view.insertText("你")
        XCTAssertEqual(view.editor.doc.textContent, "你")
        XCTAssertNil(view.markedTextRange, "committing clears the marked range")
    }

    func testUnmarkTextClearsComposition() throws {
        let view = try makeView("")
        view.setMarkedText("abc", selectedRange: NSRange(location: 3, length: 0))
        XCTAssertNotNil(view.markedTextRange)
        view.unmarkText()
        XCTAssertNil(view.markedTextRange)
        XCTAssertEqual(view.editor.doc.textContent, "abc", "unmark keeps the text, just ends composing")
    }

    func testPositionArithmetic() throws {
        let view = try makeView("hello world")
        let start = view.beginningOfDocument
        let p5 = try XCTUnwrap(view.position(from: start, offset: 5))
        XCTAssertEqual(view.offset(from: start, to: p5), 5)
        XCTAssertEqual(view.compare(start, to: p5), .orderedAscending)
        // Out of range returns nil.
        XCTAssertNil(view.position(from: view.endOfDocument, offset: 1))
    }

    func testScrollResyncsSelectionGeometry() throws {
        // The system draws the selection from our (view-coordinate) UITextInput
        // geometry; our virtualized scroll changes it without moving the view, so
        // scrolling with a selection must re-notify the input delegate.
        let view = try makeView("hello world")
        let delegate = CountingInputDelegate()
        view.inputDelegate = delegate
        view.editor.dispatch(view.editor.state.tr.setSelection(TextSelection.create(view.editor.doc, 1, 6)))
        let withSelection = delegate.selectionChanges
        view.contentOffsetY = 120
        XCTAssertGreaterThan(delegate.selectionChanges, withSelection, "scroll with a selection re-syncs geometry")
        // A collapsed caret must re-sync too: the system draws its OWN native
        // caret from this geometry, which otherwise strands a second, motionless
        // cursor on scroll (we draw our caret layer; the system draws another).
        view.editor.dispatch(view.editor.state.tr.setSelection(TextSelection.create(view.editor.doc, 3)))
        let withCaret = delegate.selectionChanges
        view.contentOffsetY = 240
        XCTAssertGreaterThan(delegate.selectionChanges, withCaret, "scroll with a caret re-syncs the native caret")
    }

    func testTypingDoesNotEchoSelectionNotifications() throws {
        // Regression: a selectionDidChange fired during UIKit's own insertText
        // makes UIKit re-sync mid-stream, which broke words during fast typing.
        let view = try makeView("")
        let delegate = CountingInputDelegate()
        view.inputDelegate = delegate
        for ch in "hello" { view.insertText(String(ch)) }
        XCTAssertEqual(view.editor.doc.textContent, "hello")
        XCTAssertEqual(delegate.selectionChanges, 0, "typing must not echo selectionDidChange")
        XCTAssertEqual(delegate.textChanges, 0)
        // A caret move the system didn't initiate SHOULD notify it.
        view.editor.dispatch(view.editor.state.tr.setSelection(TextSelection.create(view.editor.doc, 1)))
        XCTAssertGreaterThan(delegate.selectionChanges, 0, "a non-UIKit caret move should notify the input delegate")
    }

    func testGeometryIsNonZero() throws {
        let view = try makeView("hello world")
        let caret = view.caretRect(for: DocTextPosition(3))
        XCTAssertGreaterThan(caret.height, 0)
        let rects = view.selectionRects(for: range(1, 6))
        XCTAssertFalse(rects.isEmpty)
        XCTAssertTrue(rects.first?.containsStart ?? false)
        // Hit-testing maps a point back to a position.
        XCTAssertNotNil(view.closestPosition(to: CGPoint(x: caret.midX, y: caret.midY)))
    }

    /// A range the system sets that exactly spans one leaf atom (the U+FFFC
    /// "word" a double-tap on an image yields) becomes a node selection, so
    /// delete/copy address the node. Anything wider stays a text selection.
    func testRangeExactlySpanningAnAtomBecomesANodeSelection() throws {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        editor.setContent(try! s.node("doc", [:], content: Fragment.from([
            try! s.node("paragraph", [:], content: Fragment.from([s.text("ab")])),
            try! s.node("image", ["src": .string("https://example.com/a.png")]),
            try! s.node("paragraph", [:], content: Fragment.from([s.text("cd")])),
        ])))
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        view.layoutIfNeeded()

        view.selectedTextRange = range(4, 5) // exactly the image
        let sel = try XCTUnwrap(view.editor.state.selection as? NodeSelection)
        XCTAssertEqual(sel.node.type.name, "image")

        view.selectedTextRange = range(2, 8) // text on both sides: a text drag
        XCTAssertTrue(view.editor.state.selection is TextSelection,
                      "a wider range is not promoted")

        view.selectedTextRange = range(1, 3) // "ab": plain text stays plain
        XCTAssertTrue(view.editor.state.selection is TextSelection)
    }
}

@MainActor
private final class CountingInputDelegate: NSObject, UITextInputDelegate {
    var selectionChanges = 0
    var textChanges = 0
    func selectionWillChange(_ textInput: (any UITextInput)?) {}
    func selectionDidChange(_ textInput: (any UITextInput)?) { selectionChanges += 1 }
    func textWillChange(_ textInput: (any UITextInput)?) {}
    func textDidChange(_ textInput: (any UITextInput)?) { textChanges += 1 }
    @available(iOS 18.4, *)
    func conversationContext(_ context: UIConversationContext?, didChange textInput: (any UITextInput)?) {}
}
#endif

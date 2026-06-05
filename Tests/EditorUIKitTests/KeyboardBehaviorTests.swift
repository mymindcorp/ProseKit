#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import DocumentTransform
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

/// Drives the full keyboard-behavior matrix through a real `EditorTextView`,
/// from key event → handler → command → dispatched transaction → new state.
/// Only the UIKey→KeyEvent translation (trivial) is not exercised here.
@MainActor
final class KeyboardBehaviorTests: XCTestCase {
    private func count(_ view: EditorTextView, _ name: String) -> Int {
        var n = 0
        view.editor.doc.descendants { node, _, _, _ in if node.type.name == name { n += 1 }; return true }
        return n
    }
    private func makeView(_ paragraphs: [String] = [""]) throws -> EditorTextView {
        let editor = try Editor(extensions: fullKit())
        let paras = paragraphs.map { line in
            try! editor.schema.node("paragraph", [:], content: Fragment.from(line.isEmpty ? [] : [editor.schema.text(line)]))
        }
        editor.setContent(try! editor.schema.node("doc", [:], content: Fragment.from(paras)))
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        view.layoutIfNeeded()
        return view
    }

    private func cursor(_ view: EditorTextView, _ pos: Int) {
        view.editor.dispatch(view.editor.state.tr.setSelection(TextSelection.create(view.editor.doc, pos)))
    }
    private func select(_ view: EditorTextView, _ from: Int, _ to: Int) {
        view.editor.dispatch(view.editor.state.tr.setSelection(TextSelection.create(view.editor.doc, from, to)))
    }
    private func key(_ view: EditorTextView, _ code: UIKeyboardHIDUsage, _ mods: UIKeyModifierFlags = [], _ chars: String = "") {
        _ = view.handle(EditorTextView.KeyEvent(code, modifiers: mods, characters: chars))
    }
    private var text: (EditorTextView) -> String { { $0.editor.doc.textContent } }
    private func headPos(_ view: EditorTextView) -> Int { view.editor.state.selection.head }

    // MARK: - Typing & deletion

    func testInsertTextAtCursor() throws {
        let view = try makeView(["ad"])
        cursor(view, 2) // between a|d
        view.insertText("bc")
        XCTAssertEqual(text(view), "abcd")
    }

    func testTypingReplacesSelection() throws {
        let view = try makeView(["hello"])
        select(view, 1, 6)
        view.insertText("X")
        XCTAssertEqual(text(view), "X")
    }

    func testBackspaceDeletesPreviousCharacter() throws {
        let view = try makeView(["hello"])
        cursor(view, 4) // hel|lo
        key(view, .keyboardDeleteOrBackspace)
        XCTAssertEqual(text(view), "helo")
    }

    func testBackspaceJoinsParagraphs() throws {
        let view = try makeView(["foo", "bar"])
        cursor(view, 6) // start of "bar"
        key(view, .keyboardDeleteOrBackspace)
        XCTAssertEqual(text(view), "foobar")
    }

    func testOptionBackspaceDeletesWord() throws {
        let view = try makeView(["foo bar"])
        cursor(view, 8) // end of "bar"
        key(view, .keyboardDeleteOrBackspace, .alternate)
        XCTAssertEqual(text(view), "foo ")
    }

    func testForwardDeleteRemovesNextCharacter() throws {
        let view = try makeView(["hello"])
        cursor(view, 1)
        key(view, .keyboardDeleteForward)
        XCTAssertEqual(text(view), "ello")
    }

    func testBackspaceDeletesSelection() throws {
        let view = try makeView(["hello"])
        select(view, 1, 4)
        key(view, .keyboardDeleteOrBackspace)
        XCTAssertEqual(text(view), "lo")
    }

    // MARK: - Enter

    func testEnterSplitsParagraph() throws {
        let view = try makeView(["hello"])
        cursor(view, 3) // he|llo
        key(view, .keyboardReturnOrEnter)
        XCTAssertEqual(view.editor.doc.childCount, 2)
        XCTAssertEqual(view.editor.doc.child(0).textContent, "he")
        XCTAssertEqual(view.editor.doc.child(1).textContent, "llo")
    }

    func testEnterInCodeBlockInsertsNewline() throws {
        let editor = try Editor(extensions: fullKit())
        let cb = try! editor.schema.node("codeBlock", [:], content: Fragment.from([editor.schema.text("ab")]))
        editor.setContent(try! editor.schema.node("doc", [:], content: Fragment.from([cb])))
        let view = EditorTextView(editor: editor)
        cursor(view, 3) // end of "ab"
        key(view, .keyboardReturnOrEnter)
        XCTAssertEqual(view.editor.doc.textContent, "ab\n")
    }

    func testShiftEnterInsertsHardBreak() throws {
        let view = try makeView(["ab"])
        cursor(view, 2) // a|b
        key(view, .keyboardReturnOrEnter, .shift)
        var breaks = 0
        view.editor.doc.descendants { n, _, _, _ in if n.type.name == "hardBreak" { breaks += 1 }; return true }
        XCTAssertEqual(breaks, 1)
    }

    // MARK: - Navigation

    func testArrowMovesByCharacter() throws {
        let view = try makeView(["hello"])
        cursor(view, 3)
        key(view, .keyboardRightArrow)
        XCTAssertEqual(headPos(view), 4)
        key(view, .keyboardLeftArrow)
        XCTAssertEqual(headPos(view), 3)
    }

    func testOptionArrowMovesByWord() throws {
        let view = try makeView(["foo bar"])
        cursor(view, 1)
        key(view, .keyboardRightArrow, .alternate)
        XCTAssertEqual(headPos(view), 4) // after "foo"
    }

    func testCommandArrowMovesToLineEdge() throws {
        let view = try makeView(["hello world"])
        cursor(view, 5)
        key(view, .keyboardRightArrow, .command)
        XCTAssertEqual(headPos(view), 12) // end of textblock content
        key(view, .keyboardLeftArrow, .command)
        XCTAssertEqual(headPos(view), 1)
    }

    func testShiftArrowExtendsSelection() throws {
        let view = try makeView(["hello"])
        cursor(view, 1)
        key(view, .keyboardRightArrow, .shift)
        key(view, .keyboardRightArrow, .shift)
        XCTAssertEqual(view.editor.state.selection.from, 1)
        XCTAssertEqual(view.editor.state.selection.to, 3)
        XCTAssertFalse(view.editor.state.selection.empty)
    }

    func testShiftRightSelectsOneGraphemeClusterAtATime() throws {
        // The flag is a single grapheme made of two Unicode scalars (and four
        // UTF-16 units) — a scalar/UTF-16 model would select half of it.
        let view = try makeView(["a🇺🇸b"])
        cursor(view, 1)
        key(view, .keyboardRightArrow, .shift)
        XCTAssertEqual(view.editor.state.selection.from, 1)
        XCTAssertEqual(view.editor.state.selection.to, 2) // selected "a"
        key(view, .keyboardRightArrow, .shift)
        XCTAssertEqual(view.editor.state.selection.to, 3) // one more press = the whole flag
        let selected = view.editor.doc.textBetween(view.editor.state.selection.from, view.editor.state.selection.to)
        XCTAssertEqual(selected, "a🇺🇸")
        key(view, .keyboardRightArrow, .shift)
        XCTAssertEqual(view.editor.state.selection.to, 4) // then "b"
    }

    func testShiftLeftShrinksByOneGrapheme() throws {
        let view = try makeView(["x🇺🇸y"])
        select(view, 1, 4) // whole thing
        key(view, .keyboardLeftArrow, .shift) // head was at 4, shrink to 3
        XCTAssertEqual(view.editor.state.selection.head, 3)
        let selected = view.editor.doc.textBetween(1, view.editor.state.selection.head)
        XCTAssertEqual(selected, "x🇺🇸") // the flag is intact, not split
    }

    func testArrowCollapsesSelectionToEdge() throws {
        let view = try makeView(["hello"])
        select(view, 2, 4)
        key(view, .keyboardLeftArrow)
        XCTAssertTrue(view.editor.state.selection.empty)
        XCTAssertEqual(headPos(view), 2)
    }

    func testDownArrowMovesToNextParagraph() throws {
        let view = try makeView(["alpha", "bravo"])
        cursor(view, 3)
        key(view, .keyboardDownArrow)
        XCTAssertEqual(view.editor.state.selection.resolvedHead.parent.textContent, "bravo")
    }

    func testShiftDownExtendsAcrossParagraphs() throws {
        let view = try makeView(["alpha", "bravo"])
        cursor(view, 3) // inside "alpha"
        key(view, .keyboardDownArrow, .shift)
        let sel = view.editor.state.selection
        XCTAssertFalse(sel.empty)
        XCTAssertEqual(sel.anchor, 3)                 // anchor stays put
        XCTAssertEqual(sel.resolvedHead.parent.textContent, "bravo") // head moved down
    }

    func testShiftUpExtendsAcrossParagraphs() throws {
        let view = try makeView(["alpha", "bravo"])
        // start inside "bravo"
        var bravo = 0
        view.editor.doc.descendants { n, p, _, _ in if n.isText, n.text == "bravo" { bravo = p + 1 }; return true }
        cursor(view, bravo)
        key(view, .keyboardUpArrow, .shift)
        let sel = view.editor.state.selection
        XCTAssertFalse(sel.empty)
        XCTAssertEqual(sel.resolvedHead.parent.textContent, "alpha")
    }

    func testShiftHomeEndExtendToLineEdges() throws {
        let view = try makeView(["hello world"])
        cursor(view, 6)
        key(view, .keyboardEnd, .shift)
        XCTAssertEqual(view.editor.state.selection.from, 6)
        XCTAssertEqual(view.editor.state.selection.to, 12)
        cursor(view, 6)
        key(view, .keyboardHome, .shift)
        XCTAssertEqual(view.editor.state.selection.from, 1)
        XCTAssertEqual(view.editor.state.selection.to, 6)
    }

    func testShiftCommandDownExtendsToDocumentEnd() throws {
        let view = try makeView(["alpha", "bravo", "charlie"])
        cursor(view, 3)
        key(view, .keyboardDownArrow, [.shift, .command])
        let sel = view.editor.state.selection
        XCTAssertFalse(sel.empty)
        XCTAssertEqual(sel.anchor, 3)
        XCTAssertEqual(sel.resolvedHead.parent.textContent, "charlie") // extended to last block
    }

    // MARK: - Mod shortcuts

    func testModBTogglesBold() throws {
        let view = try makeView(["hello"])
        select(view, 1, 6)
        key(view, .keyboardB, .command, "b")
        XCTAssertTrue(view.editor.isActive(mark: "bold"))
    }

    func testModAltOneMakesHeading() throws {
        let view = try makeView(["Title"])
        cursor(view, 3)
        key(view, .keyboard1, [.command, .alternate], "1")
        XCTAssertTrue(view.editor.isActive(node: "heading", attrs: ["level": .int(1)]))
    }

    func testModASelectsAll() throws {
        let view = try makeView(["a", "b"])
        key(view, .keyboardA, .command, "a")
        XCTAssertTrue(view.editor.state.selection is AllSelection)
    }

    func testUndoRedoViaKeyboard() throws {
        let view = try makeView(["hello"])
        cursor(view, 6)
        view.insertText("!")
        XCTAssertEqual(text(view), "hello!")
        key(view, .keyboardZ, .command, "z")
        XCTAssertEqual(text(view), "hello")
        key(view, .keyboardZ, [.command, .shift], "z")
        XCTAssertEqual(text(view), "hello!")
    }

    // MARK: - Previously-uncovered behaviors

    func testGoalColumnPreservedAcrossRaggedLines() throws {
        let view = try makeView(["longline", "x", "longline"])
        cursor(view, 8) // column 7 within "longline"
        key(view, .keyboardDownArrow) // lands in "x" (only 1 char)
        key(view, .keyboardDownArrow) // should return to ~column 7 in line 3, not column 0
        let head = view.editor.state.selection.resolvedHead
        XCTAssertEqual(head.parent.textContent, "longline")
        XCTAssertGreaterThan(head.parentOffset, 4, "goal column should be preserved through the short line")
    }

    func testWordForwardDelete() throws {
        let view = try makeView(["foo bar"])
        cursor(view, 1)
        key(view, .keyboardDeleteForward, .alternate)
        XCTAssertEqual(text(view), " bar")
    }

    func testCommandBackspaceDeletesToLineStart() throws {
        let view = try makeView(["hello world"])
        cursor(view, 12) // end
        key(view, .keyboardDeleteOrBackspace, .command)
        XCTAssertEqual(text(view), "")
    }

    func testBackspaceDeletesInlineAtom() throws {
        let editor = try Editor(extensions: fullKit())
        let img = try! editor.schema.nodes["image"]!.create(["src": .string("c.png")])
        let para = try! editor.schema.node("paragraph", [:], content: Fragment.from([editor.schema.text("a"), img, editor.schema.text("b")]))
        editor.setContent(try! editor.schema.node("doc", [:], content: Fragment.from([para])))
        let view = EditorTextView(editor: editor)
        XCTAssertEqual(count(view, "image"), 1)
        cursor(view, 3) // right after the image (a=1..2, image=2..3)
        key(view, .keyboardDeleteOrBackspace)
        XCTAssertEqual(count(view, "image"), 0, "backspace should delete the inline image")
        XCTAssertEqual(text(view), "ab")
    }

    func testEnterInEmptyListItemExitsList() throws {
        let view = try makeView(["item"])
        XCTAssertTrue(view.editor.run("toggleBulletList"))
        var textEnd = 0
        view.editor.doc.descendants { n, p, _, _ in if n.isText { textEnd = p + n.nodeSize }; return true }
        cursor(view, textEnd)
        key(view, .keyboardReturnOrEnter) // new empty item
        key(view, .keyboardReturnOrEnter) // Enter in empty item should leave the list
        // After exiting, there should be a paragraph that is NOT inside a list item.
        var paragraphOutsideList = false
        view.editor.doc.descendants { node, _, parent, _ in
            if node.type.name == "paragraph", parent?.type.name == "doc" { paragraphOutsideList = true }
            return true
        }
        XCTAssertTrue(paragraphOutsideList, "Enter in an empty list item should exit the list")
    }

    func testTypingOverSelectAllReplacesDocument() throws {
        let view = try makeView(["alpha", "bravo"])
        key(view, .keyboardA, .command, "a") // select all
        XCTAssertTrue(view.editor.state.selection is AllSelection)
        view.insertText("Z")
        XCTAssertEqual(text(view), "Z")
        XCTAssertEqual(view.editor.doc.childCount, 1)
    }

    func testEscapeSelectsParentNode() throws {
        let editor = try Editor(extensions: fullKit())
        let bq = try! editor.schema.node("blockquote", [:], content: Fragment.from([
            try! editor.schema.node("paragraph", [:], content: Fragment.from([editor.schema.text("quoted")])),
        ]))
        editor.setContent(try! editor.schema.node("doc", [:], content: Fragment.from([bq])))
        let view = EditorTextView(editor: editor)
        cursor(view, 3) // inside "quoted"
        key(view, .keyboardEscape)
        XCTAssertTrue(view.editor.state.selection is NodeSelection, "Escape should select the enclosing node")
    }

    func testCommandDownMovesToDocumentEnd() throws {
        let view = try makeView(["a", "b", "c"])
        cursor(view, 1)
        key(view, .keyboardDownArrow, .command)
        // Document end is the end of the last textblock (not past its closing token).
        let head = view.editor.state.selection.resolvedHead
        XCTAssertEqual(head.parent.textContent, "c")
        XCTAssertEqual(head.parentOffset, 1) // after "c"
        XCTAssertTrue(view.editor.state.selection.empty)
    }

    func testRedoViaCommandY() throws {
        let view = try makeView(["x"])
        cursor(view, 2)
        view.insertText("!")
        key(view, .keyboardZ, .command, "z")
        XCTAssertEqual(text(view), "x")
        key(view, .keyboardY, .command, "y")
        XCTAssertEqual(text(view), "x!")
    }

    func testModEnterExitsCodeBlock() throws {
        let editor = try Editor(extensions: fullKit())
        let cb = try! editor.schema.node("codeBlock", [:], content: Fragment.from([editor.schema.text("code")]))
        editor.setContent(try! editor.schema.node("doc", [:], content: Fragment.from([cb])))
        let view = EditorTextView(editor: editor)
        cursor(view, 5) // end of "code"
        key(view, .keyboardReturnOrEnter, .command) // Mod-Enter → exit code
        // A paragraph should now follow the code block.
        XCTAssertEqual(view.editor.doc.childCount, 2)
        XCTAssertEqual(view.editor.doc.child(1).type.name, "paragraph")
    }

    func testBackspaceAtStartOfFirstListItemLiftsOut() throws {
        let view = try makeView(["a"])
        XCTAssertTrue(view.editor.run("toggleBulletList"))
        var start = 0
        view.editor.doc.descendants { n, p, _, _ in if n.isText, n.text == "a" { start = p }; return true }
        cursor(view, start) // start of "a"
        key(view, .keyboardDeleteOrBackspace)
        XCTAssertEqual(count(view, "bulletList"), 0, "Backspace at the start of the only item should lift it out of the list")
        XCTAssertEqual(text(view), "a")
    }

    func testBackspaceAtStartOfSecondListItemMerges() throws {
        let view = try makeView(["a"])
        XCTAssertTrue(view.editor.run("toggleBulletList"))
        var end = 0
        view.editor.doc.descendants { n, p, _, _ in if n.isText, n.text == "a" { end = p + n.nodeSize }; return true }
        cursor(view, end)
        key(view, .keyboardReturnOrEnter) // second item
        view.insertText("b")
        var bStart = 0
        view.editor.doc.descendants { n, p, _, _ in if n.isText, n.text == "b" { bStart = p }; return true }
        cursor(view, bStart)
        key(view, .keyboardDeleteOrBackspace)
        XCTAssertEqual(text(view), "ab", "Backspace at the start of a later item should merge with the previous item")
        XCTAssertEqual(count(view, "listItem"), 1)
    }

    func testTabIndentsInCodeBlock() throws {
        let editor = try Editor(extensions: fullKit())
        let cb = try! editor.schema.node("codeBlock", [:], content: Fragment.from([editor.schema.text("x")]))
        editor.setContent(try! editor.schema.node("doc", [:], content: Fragment.from([cb])))
        let view = EditorTextView(editor: editor)
        cursor(view, 1) // start of code content
        key(view, .keyboardTab, [], "\t")
        XCTAssertEqual(text(view), "  x")
        // Shift-Tab removes the indentation again.
        key(view, .keyboardTab, .shift, "\t")
        XCTAssertEqual(text(view), "x")
    }

    func testTabStillSinksListItemNotInCodeBlock() throws {
        // Ensure the code-block Tab binding falls through outside code blocks.
        let view = try makeView(["one"])
        XCTAssertTrue(view.editor.run("toggleBulletList"))
        var textEnd = 0
        view.editor.doc.descendants { n, p, _, _ in if n.isText { textEnd = p + n.nodeSize }; return true }
        cursor(view, textEnd)
        key(view, .keyboardReturnOrEnter)
        view.insertText("two")
        let before = count(view, "bulletList")
        key(view, .keyboardTab, [], "\t")
        XCTAssertGreaterThan(count(view, "bulletList"), before)
    }

    // MARK: - Tab in lists

    func testTabSinksListItem() throws {
        let view = try makeView(["one"])
        XCTAssertTrue(view.editor.run("toggleBulletList"))
        // place the cursor inside the (now only) list item, then add a sibling
        var textEnd = 0
        view.editor.doc.descendants { n, p, _, _ in if n.isText { textEnd = p + n.nodeSize }; return true }
        cursor(view, textEnd)
        key(view, .keyboardReturnOrEnter)        // new empty item
        view.insertText("two")
        // cursor now in the second item; Tab should sink it into a sublist.
        let before = count(view, "bulletList")
        key(view, .keyboardTab, [], "\t")
        XCTAssertGreaterThan(count(view, "bulletList"), before, "Tab should nest the item in a sublist")
    }
}
#endif

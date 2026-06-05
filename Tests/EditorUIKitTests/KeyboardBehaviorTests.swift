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

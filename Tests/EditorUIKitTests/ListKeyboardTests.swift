#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

/// Tests the view's Tab routing as well as the document command it reaches.
@MainActor
final class ListKeyboardTests: XCTestCase {
    private func make(_ kind: String, table: Bool = false, code: Bool = false) throws -> EditorTextView {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        func p(_ text: String) throws -> Node { try s.node("paragraph", content: .from(s.text(text))) }
        func item(_ text: String, extra: [Node] = []) throws -> Node {
            try s.node(kind == "taskList" ? "taskItem" : "listItem",
                kind == "taskList" ? ["checked": .bool(true)] : [:], content: .from([p(text)] + extra))
        }
        let extra = code ? [try s.node("codeBlock", content: .from(s.text("code")))] : []
        let list = try s.node(kind, kind == "orderedList" ? ["order": .int(4)] : [:],
            content: .from([item("one"), item("two", extra: extra), item("three")]))
        let root = table ? try s.node("table", content: .from(s.node("tableRow", content: .from([
            s.node("tableCell", content: .from(list)), s.node("tableCell", content: .from(p("other")))
        ])))) : list
        editor.setContent(try s.node("doc", content: .from(root)))
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 500, height: 700)
        view.layoutIfNeeded()
        return view
    }
    private func position(_ view: EditorTextView, _ text: String, offset: Int = 0) -> Int {
        var result = -1
        view.editor.doc.descendants { node, pos, _, _ in
            if node.text == text { result = pos + offset }
            return true
        }
        return result
    }
    private func cursor(_ view: EditorTextView, _ text: String, offset: Int = 0) {
        let pos = position(view, text, offset: offset)
        view.editor.dispatch(view.editor.state.tr.setSelection(TextSelection.create(view.editor.doc, pos)))
    }
    @discardableResult
    private func tab(_ view: EditorTextView, shift: Bool = false) -> Bool {
        view.handle(EditorTextView.KeyEvent(.keyboardTab, modifiers: shift ? .shift : [], characters: "\t"))
    }
    private func assertCaret(_ view: EditorTextView, _ text: String, _ offset: Int, file: StaticString = #filePath, line: UInt = #line) {
        let selection = view.editor.state.selection
        XCTAssertTrue(selection.empty, file: file, line: line)
        XCTAssertEqual(selection.resolvedHead.parent.textContent, text, file: file, line: line)
        XCTAssertEqual(selection.resolvedHead.parentOffset, offset, file: file, line: line)
    }

    func testTabAndShiftTabRoundTripEveryListTypeWithUndoRedo() throws {
        for kind in ["bulletList", "orderedList", "taskList"] {
            let view = try make(kind), editor = view.editor
            cursor(view, "two", offset: 1)
            let original = editor.state
            let list = original.doc.firstChild!
            XCTAssertTrue(tab(view), kind)
            let indented = editor.state
            let parent = try editor.schema.node(list.child(0).type.name, list.child(0).attrs,
                content: list.child(0).content.append(.from(editor.schema.node(kind, content: .from(list.child(1))))))
            let expected = try editor.schema.node("doc", content: .from(editor.schema.node(kind, list.attrs, content: .from([parent, list.child(2)]))))
            XCTAssertEqual(editor.doc, expected, kind)
            assertCaret(view, "two", 1)
            XCTAssertTrue(view.handle(EditorTextView.KeyEvent(.keyboardZ, modifiers: .command, characters: "z")))
            XCTAssertEqual(editor.doc, original.doc)
            XCTAssertTrue(editor.state.selection.eq(original.selection))
            XCTAssertTrue(view.handle(EditorTextView.KeyEvent(.keyboardZ, modifiers: [.command, .shift], characters: "z")))
            XCTAssertEqual(editor.doc, indented.doc)
            XCTAssertTrue(editor.state.selection.eq(indented.selection))
            XCTAssertTrue(tab(view, shift: true), kind)
            XCTAssertEqual(editor.doc, original.doc, kind)
            assertCaret(view, "two", 1)
            try editor.doc.check()
        }
    }

    func testShiftTabLiftsTopLevelItemForEveryListType() throws {
        for kind in ["bulletList", "orderedList", "taskList"] {
            let view = try make(kind), editor = view.editor
            cursor(view, "one", offset: 2)
            let list = editor.doc.firstChild!
            XCTAssertTrue(tab(view, shift: true), kind)
            XCTAssertEqual(editor.doc.child(0), list.child(0).firstChild)
            XCTAssertEqual(editor.doc.child(1), try editor.schema.node(kind, list.attrs, content: .from([list.child(1), list.child(2)])))
            assertCaret(view, "one", 2)
        }
    }

    func testBackwardsMultiItemSelectionSurvivesTabAndShiftTab() throws {
        for kind in ["bulletList", "orderedList", "taskList"] {
            let view = try make(kind), editor = view.editor
            let anchor = position(view, "three", offset: 3), head = position(view, "two", offset: 1)
            editor.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.doc, anchor, head)))
            let original = editor.state
            XCTAssertTrue(tab(view))
            XCTAssertEqual(editor.doc.firstChild?.childCount, 1)
            XCTAssertEqual(editor.doc.firstChild?.firstChild?.lastChild?.childCount, 2)
            XCTAssertEqual(editor.state.selection.resolvedAnchor.parent.textContent, "three")
            XCTAssertEqual(editor.state.selection.resolvedAnchor.parentOffset, 3)
            XCTAssertEqual(editor.state.selection.resolvedHead.parent.textContent, "two")
            XCTAssertEqual(editor.state.selection.resolvedHead.parentOffset, 1)
            XCTAssertTrue(tab(view, shift: true))
            XCTAssertEqual(editor.doc, original.doc)
            XCTAssertTrue(editor.state.selection.eq(original.selection))
        }
    }

    func testListsInTableCellsIndentBeforeNavigatingToAnotherCell() throws {
        for kind in ["bulletList", "orderedList", "taskList"] {
            let view = try make(kind, table: true), editor = view.editor
            cursor(view, "two", offset: 1)
            let original = editor.state
            XCTAssertTrue(tab(view), kind)
            XCTAssertEqual(editor.doc.firstChild?.firstChild?.firstChild?.firstChild?.childCount, 2)
            assertCaret(view, "two", 1)
            XCTAssertTrue(tab(view, shift: true), kind)
            XCTAssertEqual(editor.doc, original.doc)
            XCTAssertTrue(editor.state.selection.eq(original.selection))
            cursor(view, "one")
            XCTAssertTrue(tab(view))
            XCTAssertEqual(editor.doc, original.doc)
            XCTAssertEqual(editor.state.selection.resolvedAnchor.parent.textContent, "other")
            XCTAssertEqual(editor.state.selection.resolvedAnchor.parentOffset, 0)
            XCTAssertEqual(editor.state.selection.resolvedHead.parent.textContent, "other")
            XCTAssertEqual(editor.state.selection.resolvedHead.parentOffset, 5)
        }
    }

    func testMixedListTypesTargetTheNearestItem() throws {
        for outer in ["bulletList", "orderedList", "taskList"] {
            for inner in ["bulletList", "orderedList", "taskList"] where inner != outer {
                let view = try make(inner), editor = view.editor, s = editor.schema
                let nested = editor.doc.firstChild!
                let paragraph = try s.node("paragraph", content: .from(s.text("parent")))
                let item = try s.node(outer == "taskList" ? "taskItem" : "listItem", content: .from([paragraph, nested]))
                editor.setContent(try s.node("doc", content: .from(s.node(outer, content: .from(item)))))
                cursor(view, "two", offset: 1)
                let original = editor.state
                XCTAssertTrue(tab(view))
                XCTAssertNotEqual(editor.doc, original.doc)
                assertCaret(view, "two", 1)
                XCTAssertTrue(tab(view, shift: true))
                XCTAssertEqual(editor.doc, original.doc, "\(outer) containing \(inner)")
                XCTAssertTrue(editor.state.selection.eq(original.selection))
            }
        }
    }

    func testNodeSelectedItemsFollowTabAndShiftTab() throws {
        for kind in ["bulletList", "orderedList", "taskList"] {
            let view = try make(kind), editor = view.editor
            let first = editor.doc.firstChild!.child(0), second = editor.doc.firstChild!.child(1)
            editor.dispatch(editor.state.tr.setSelection(NodeSelection.create(editor.doc, 1 + first.nodeSize)))
            let original = editor.state
            XCTAssertTrue(tab(view))
            XCTAssertEqual((editor.state.selection as? NodeSelection)?.node, second)
            XCTAssertTrue(tab(view, shift: true))
            XCTAssertEqual(editor.doc, original.doc)
            XCTAssertTrue(editor.state.selection.eq(original.selection))
        }
    }

    func testCodeOutdentWithCRLFLeavesThePreviousLineUnchanged() throws {
        let editor = try Editor(extensions: fullKit()), source = "  first\r\n  second"
        let s = editor.schema
        editor.setContent(try s.node("doc", content: .from(s.node("codeBlock", content: .from(s.text(source))))))
        let view = EditorTextView(editor: editor)
        let prefix = "  first\r\n"
        cursor(view, source, offset: prefix.count + 3)
        let original = editor.state
        XCTAssertTrue(tab(view, shift: true))
        XCTAssertEqual(editor.doc.textContent, prefix + "second")
        assertCaret(view, prefix + "second", prefix.count + 1)
        XCTAssertTrue(view.handle(EditorTextView.KeyEvent(.keyboardZ, modifiers: .command, characters: "z")))
        XCTAssertEqual(editor.doc, original.doc)
        XCTAssertTrue(editor.state.selection.eq(original.selection))
    }

    func testCodeInsideEveryListTypeHandlesIndentationFirst() throws {
        for kind in ["bulletList", "orderedList", "taskList"] {
            let view = try make(kind, code: true), editor = view.editor
            cursor(view, "code")
            let original = editor.state
            XCTAssertTrue(tab(view))
            XCTAssertEqual(editor.doc.firstChild?.childCount, 3)
            assertCaret(view, "  code", 2)
            XCTAssertTrue(tab(view, shift: true))
            XCTAssertEqual(editor.doc, original.doc)
            XCTAssertTrue(editor.state.selection.eq(original.selection))
        }
    }
}
#endif

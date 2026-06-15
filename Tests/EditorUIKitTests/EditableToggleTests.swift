#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

/// The `isEditable` read-only toggle: when off, mutations (typing, deletes, key
/// bindings, drops, edit-menu actions, handles) are suppressed while selection,
/// copy, and select-all keep working.
@MainActor
final class EditableToggleTests: XCTestCase {
    private func makeView(_ text: String = "hello") throws -> EditorTextView {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        editor.setContent(try s.node("doc", [:], content: Fragment.from([
            try s.node("paragraph", [:], content: Fragment.from([s.text(text)])),
        ])))
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        view.layoutIfNeeded()
        return view
    }

    private func selectAll(_ view: EditorTextView) {
        let doc = view.editor.doc
        view.editor.dispatch(view.editor.state.tr.setSelection(
            TextSelection.create(doc, 1, max(1, doc.content.size - 1))))
    }

    func testReadOnlyIgnoresTextInputAndDeletes() throws {
        let view = try makeView("hello")
        view.isEditable = false
        view.insertText("X")
        view.deleteBackward()
        view.replace(view.textRange(from: view.beginningOfDocument, to: view.endOfDocument)!, withText: "z")
        XCTAssertEqual(view.editor.doc.textContent, "hello", "read-only suppresses all text mutation")
    }

    func testReadOnlyIgnoresKeyboardMutations() throws {
        let view = try makeView("hello")
        view.isEditable = false
        XCTAssertFalse(view.handle(EditorTextView.KeyEvent(.keyboardDeleteOrBackspace)))
        XCTAssertFalse(view.handle(EditorTextView.KeyEvent(.keyboardReturnOrEnter)))
        XCTAssertEqual(view.editor.doc.textContent, "hello")
        XCTAssertEqual(view.editor.doc.childCount, 1, "Enter didn't split the paragraph")
    }

    func testToggleBackRestoresEditing() throws {
        let view = try makeView("hi")
        view.isEditable = false
        view.insertText("X")
        XCTAssertEqual(view.editor.doc.textContent, "hi")
        view.isEditable = true
        view.insertText("X")
        XCTAssertEqual(view.editor.doc.textContent, "Xhi", "editing works again after re-enabling")
    }

    func testReadOnlySuppressesHandles() throws {
        let view = try makeView("hi")
        view.blockReorderingEnabled = true
        view.isEditable = false
        XCTAssertNil(view.blockHandleHit(at: CGPoint(x: 5, y: 5)), "no reorder handle when read-only")
        XCTAssertNil(view.imageResizeHit(at: CGPoint(x: 5, y: 5)), "no resize handle when read-only")
        // Re-enabling brings the reorder handle back (the doc has one block).
        view.isEditable = true
        let rect = try XCTUnwrap(view.blockHandleRect(forEntryAt: 0))
        XCTAssertNotNil(view.blockHandleHit(at: CGPoint(x: rect.midX, y: rect.midY)),
                        "handle returns when editable")
    }

    func testFocusAndBlurCallbacks() throws {
        let view = try makeView("hi")
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        window.addSubview(view)
        window.makeKeyAndVisible()
        var focused = 0, blurred = 0
        view.onFocus = { focused += 1 }
        view.onBlur = { blurred += 1 }
        XCTAssertFalse(view.isFocused)
        XCTAssertTrue(view.focus())
        XCTAssertTrue(view.isFocused, "isFocused tracks first-responder state")
        XCTAssertEqual(focused, 1, "onFocus fires when becoming first responder")
        XCTAssertTrue(view.resignFirstResponder())
        XCTAssertFalse(view.isFocused)
        XCTAssertEqual(blurred, 1, "onBlur fires when resigning")
    }

    func testReadOnlyBlocksCheckboxToggle() throws {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        let item = try s.node("taskItem", ["checked": .bool(false)],
                              content: Fragment.from([try s.node("paragraph", [:], content: Fragment.from([s.text("todo")]))]))
        editor.setContent(try s.node("doc", [:], content: Fragment.from([
            try s.node("taskList", [:], content: Fragment.from([item])),
        ])))
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        view.layoutIfNeeded()
        var pos = -1
        editor.doc.descendants { node, p, _, _ in
            if node.type.name == "taskItem" { pos = p }
            return true
        }
        XCTAssertGreaterThanOrEqual(pos, 0, "found the taskItem")
        view.isEditable = false
        view.toggleCheckboxForTesting(at: pos)
        try checked(editor, pos, is: false, "read-only must not toggle the checkbox")
        view.isEditable = true
        view.toggleCheckboxForTesting(at: pos)
        try checked(editor, pos, is: true, "toggling works when editable")
    }

    func testReadOnlyBlocksColumnResize() throws {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        let cell = try s.node("tableCell", [:], content: Fragment.from([try s.node("paragraph", [:], content: .empty)]))
        let row = try s.node("tableRow", [:], content: Fragment.from([cell, cell]))
        editor.setContent(try s.node("doc", [:], content: Fragment.from([
            try s.node("table", [:], content: Fragment.from([row])),
        ])))
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        view.layoutIfNeeded()
        view.isEditable = false
        // Scan the table's border band; no column border should be hittable read-only.
        for x in stride(from: CGFloat(0), through: 320, by: 4) {
            XCTAssertNil(view.columnBorderHit(at: CGPoint(x: x, y: 12)), "no column resize when read-only")
        }
    }

    private func checked(_ editor: Editor, _ pos: Int, is value: Bool, _ message: String) throws {
        XCTAssertEqual(editor.doc.nodeAt(pos)?.attrs["checked"]?.boolValue, value, message)
    }

    func testReadOnlyMenuDisablesEditingButKeepsCopy() throws {
        let view = try makeView("hello")
        selectAll(view)
        view.isEditable = false
        XCTAssertFalse(view.canPerformAction(#selector(UIResponderStandardEditActions.cut(_:)), withSender: nil))
        XCTAssertFalse(view.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil))
        XCTAssertFalse(view.canPerformAction(#selector(EditorTextView.formatBold(_:)), withSender: nil))
        XCTAssertTrue(view.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil),
                      "copy stays available read-only")
        XCTAssertTrue(view.canPerformAction(#selector(UIResponderStandardEditActions.selectAll(_:)), withSender: nil))
    }
}
#endif

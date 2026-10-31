#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import DocumentTransform
import EditorHistory
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

@MainActor
final class MergedGraphemeInputTests: XCTestCase {
    func view(_ build: (Schema) throws -> [Node]) throws -> EditorTextView {
        let editor = try Editor(extensions: fullKit())
        editor.setContent(try editor.schema.node("doc", [:], content: Fragment.from(try build(editor.schema))))
        let v = EditorTextView(editor: editor)
        v.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        v.layoutIfNeeded()
        return v
    }
    nonisolated func para(_ s: Schema, _ t: String) throws -> Node { try s.node("paragraph", [:], content: Fragment.from([s.text(t)])) }
    func caret(_ v: EditorTextView, _ p: Int) { v.editor.dispatch(v.editor.state.tr.setSelection(TextSelection.create(v.editor.doc, p))) }

    func testCombiningInsertMidText() throws {
        let v = try view { [try para($0, "\u{915}bc")] }
        caret(v, 2)
        v.insertText("\u{93E}")   // Devanagari vowel sign merges with क
        XCTAssertEqual(v.editor.state.selection.head, 2)
        v.insertText("x")
        XCTAssertEqual(v.editor.doc.textContent, "\u{915}\u{93E}xbc")
    }
    func testCombiningInsertAtParagraphEnd() throws {
        let v = try view { [try para($0, "\u{915}"), try para($0, "next")] }
        caret(v, 2)
        v.insertText("\u{93E}")
        let sel = v.editor.state.selection
        XCTAssertEqual(sel.head, 2)
        XCTAssertTrue(sel.resolvedHead.parent.isTextblock)
        v.insertText("x")
    }
    func testMarkedMergingEatsNext() throws {
        let v = try view { [try para($0, "\u{915}bc")] }
        caret(v, 2)
        v.setMarkedText("\u{93E}", selectedRange: NSRange(location: 1, length: 0))
        v.setMarkedText("\u{93E}y", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertTrue(v.editor.doc.textContent.hasSuffix("bc"), "following text eaten: \(v.editor.doc.textContent)")
    }
    func testGapCursorTyping() throws {
        let v = try view { s in [try s.node("horizontalRule"), try s.node("horizontalRule")] }
        v.editor.dispatch(v.editor.state.tr.setSelection(GapCursor(v.editor.doc.resolve(1))))
        v.insertText("a")
        v.insertText("b")
        XCTAssertEqual(v.editor.doc.textContent, "ab")
    }
    func testNodeSelectionTyping() throws {
        let v = try view { s in [try self.para(s, "x"), try s.node("horizontalRule"), try self.para(s, "y")] }
        v.editor.dispatch(v.editor.state.tr.setSelection(NodeSelection(v.editor.doc.resolve(3))))
        v.insertText("a")
        v.insertText("b")
        XCTAssertTrue(v.editor.doc.textContent.contains("ab"), v.editor.doc.textContent)
    }
    func testUndoAfterMerge() throws {
        let v = try view { [try self.para($0, "\u{915}bc")] }
        caret(v, 2)
        v.insertText("\u{93E}")
        _ = v.editor.run { s, d, _ in EditorHistory.undo(s, d) }
        XCTAssertEqual(v.editor.doc.textContent, "\u{915}bc")
    }
    func testThaiTypingSequence() throws {
        let v = try view { [try $0.node("paragraph")] }
        for ch in ["ก", "ิ", "น", "ข", "้", "า", "ว"] { v.insertText(ch) }
        XCTAssertEqual(v.editor.doc.textContent, "กินข้าว")
    }
    func testFlagTyping() throws {
        let v = try view { s in [try self.para(s, "z"), try self.para(s, "next")] }
        caret(v, 2)
        v.insertText("🇺")
        v.insertText("🇸")
        v.insertText("x")
        XCTAssertEqual(v.editor.doc.child(0).textContent, "z🇺🇸x")
    }
    func testColspanTable() throws {
        let v = try view { s in
            let c: (String, Attrs) throws -> Node = { t, attrs in
                try s.node("tableCell", attrs, content: Fragment.from([try s.node("paragraph", [:], content: Fragment.from([s.text(t)]))]))
            }
            return [try s.node("table", [:], content: Fragment.from([
                try s.node("tableRow", [:], content: Fragment.from([try c("merged", ["colspan": .int(2)])])),
                try s.node("tableRow", [:], content: Fragment.from([try c("a", [:]), try c("b", [:])])),
            ]))]
        }
        let l = v.ensureLayout()
        XCTAssertTrue(l.blocks.allSatisfy { $0.frame.minX < l.width - l.theme.pageInsets.right }, "cell drawn off the page")
    }
    func testRowspan() throws {
        let v = try view { s in
            let c: (String, Attrs) throws -> Node = { t, attrs in
                try s.node("tableCell", attrs, content: Fragment.from([try s.node("paragraph", [:], content: Fragment.from([s.text(t)]))]))
            }
            return [try s.node("table", [:], content: Fragment.from([
                try s.node("tableRow", [:], content: Fragment.from([try c("tall", ["rowspan": .int(2)]), try c("r", [:])])),
                try s.node("tableRow", [:], content: Fragment.from([try c("below-r", [:])])),
            ]))]
        }
        let l = v.ensureLayout()
        XCTAssertEqual(l.blocks[2].frame.minX, l.blocks[1].frame.minX, accuracy: 1, "second-row cell belongs in column 1")
    }
}
#endif

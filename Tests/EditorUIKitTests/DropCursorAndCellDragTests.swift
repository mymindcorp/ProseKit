#if canImport(UIKit)
import XCTest
import DocumentModel
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

@MainActor
final class DropCursorAndCellDragTests: XCTestCase {
    private func tableEditor() throws -> Editor {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        func cell(_ text: String) -> Node {
            try! s.node("tableCell", [:], content: Fragment.from([
                try! s.node("paragraph", [:], content: Fragment.from([s.text(text)])),
            ]))
        }
        let table = try! s.node("table", [:], content: Fragment.from([
            try! s.node("tableRow", [:], content: Fragment.from([cell("A"), cell("B")])),
            try! s.node("tableRow", [:], content: Fragment.from([cell("C"), cell("D")])),
        ]))
        editor.setContent(try! s.node("doc", [:], content: Fragment.from([
            try! s.node("paragraph", [:], content: Fragment.from([s.text("intro")])), table,
        ])))
        return editor
    }

    private func makeView(_ editor: Editor) -> EditorTextView {
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        view.layoutIfNeeded()
        return view
    }

    func testDropCursorRectInsideTextIsAVerticalCaret() throws {
        let editor = try tableEditor()
        let view = makeView(editor)
        let layout = DocumentLayout(doc: editor.doc, width: 320, theme: TextTheme())
        let firstBlock = try XCTUnwrap(layout.blocks.first)
        let rect = try XCTUnwrap(view.dropCursorRect(at: CGPoint(x: firstBlock.frame.midX, y: firstBlock.frame.midY)))
        XCTAssertGreaterThan(rect.height, rect.width, "text drop cursor is a vertical caret")
    }

    func testDropCursorRectInAGapIsAHorizontalBar() throws {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        func table(_ text: String) -> Node {
            try! s.node("table", [:], content: Fragment.from([
                try! s.node("tableRow", [:], content: Fragment.from([
                    try! s.node("tableCell", [:], content: Fragment.from([
                        try! s.node("paragraph", [:], content: Fragment.from([s.text(text)])),
                    ])),
                ])),
            ]))
        }
        editor.setContent(try! s.node("doc", [:], content: Fragment.from([table("A"), table("B")])))
        let view = makeView(editor)
        let layout = DocumentLayout(doc: editor.doc, width: 320, theme: TextTheme())
        let midY = (layout.tables[0].bottom + layout.tables[1].top) / 2
        let rect = try XCTUnwrap(view.dropCursorRect(at: CGPoint(x: 40, y: midY)))
        XCTAssertGreaterThan(rect.width, rect.height, "gap drop cursor is a horizontal bar")
    }

    func testRangedSelectionAcrossCellsBecomesACellSelection() throws {
        let editor = try tableEditor()
        let view = makeView(editor)
        // Positions inside cell A and cell D's text.
        var aPos = 0, dPos = 0
        editor.doc.descendants { node, pos, _, _ in
            if node.isText, node.text == "A" { aPos = pos + 1 }
            if node.isText, node.text == "D" { dPos = pos + 1 }
            return true
        }
        view.selectedTextRange = DocTextRange(aPos, dPos)
        XCTAssertTrue(editor.state.selection is CellSelection, "got \(type(of: editor.state.selection))")
        // All four cells covered (A top-left → D bottom-right).
        XCTAssertEqual(editor.state.selection.ranges.count, 4)
    }

    func testRangedSelectionInsideOneCellStaysTextSelection() throws {
        let editor = try tableEditor()
        let view = makeView(editor)
        var aPos = 0
        editor.doc.descendants { node, pos, _, _ in
            if node.isText, node.text == "intro" { aPos = pos }
            return true
        }
        view.selectedTextRange = DocTextRange(aPos, aPos + 3)
        XCTAssertTrue(editor.state.selection is TextSelection)
    }
}
#endif

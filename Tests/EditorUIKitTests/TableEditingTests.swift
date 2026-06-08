#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

/// Clicking into a table cell and editing its contents. Cells are laid out as
/// real text blocks, so hit-testing must land in the correct cell (by x), and
/// typing must edit that cell.
@MainActor
final class TableEditingTests: XCTestCase {
    private func tableEditor() throws -> Editor {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        func cell(_ name: String, _ text: String) -> Node {
            try! s.node(name, [:], content: Fragment.from([
                try! s.node("paragraph", [:], content: Fragment.from([s.text(text)])),
            ]))
        }
        func row(_ cells: [Node]) -> Node { try! s.node("tableRow", [:], content: Fragment.from(cells)) }
        let table = try! s.node("table", [:], content: Fragment.from([
            row([cell("tableHeader", "A"), cell("tableHeader", "B")]),
            row([cell("tableCell", "C"), cell("tableCell", "D")]),
        ]))
        editor.setContent(try! s.node("doc", [:], content: Fragment.from([table])))
        return editor
    }

    private func makeView(_ editor: Editor) -> EditorTextView {
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        view.layoutIfNeeded()
        return view
    }

    /// The document position whose resolved text content is the given cell text.
    private func cellTextPosition(_ editor: Editor, _ text: String) -> Int {
        var pos = 0
        editor.doc.descendants { node, p, _, _ in
            if node.isText, node.text == text { pos = p + 1 }
            return true
        }
        return pos
    }

    /// The text content of the cell containing `pos` (or nil if not in a cell).
    private func cellText(at pos: Int, _ editor: Editor) -> String? {
        let r = editor.doc.resolve(min(max(pos, 0), editor.doc.content.size))
        for d in stride(from: r.depth, through: 1, by: -1) where r.node(d).type.name == "tableCell" || r.node(d).type.name == "tableHeader" {
            return r.node(d).textContent
        }
        return nil
    }

    func testArrowUpDownStaysInTableColumn() throws {
        let editor = try tableEditor() // col 0 = A / C, col 1 = B / D
        let view = makeView(editor)
        // Caret inside cell "A" (column 0, top row).
        let aPos = cellTextPosition(editor, "A")
        editor.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.doc, aPos)))
        XCTAssertEqual(cellText(at: editor.state.selection.head, editor), "A")
        _ = view.handle(EditorTextView.KeyEvent(.keyboardDownArrow))
        XCTAssertEqual(cellText(at: editor.state.selection.head, editor), "C", "down moves within column 0 (A→C), not into B")
        _ = view.handle(EditorTextView.KeyEvent(.keyboardUpArrow))
        XCTAssertEqual(cellText(at: editor.state.selection.head, editor), "A", "up returns within column 0 (C→A)")
    }

    func testArrowDownInSecondColumnStaysInColumn() throws {
        let editor = try tableEditor()
        let view = makeView(editor)
        let bPos = cellTextPosition(editor, "B") // column 1, top row
        editor.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.doc, bPos)))
        _ = view.handle(EditorTextView.KeyEvent(.keyboardDownArrow))
        XCTAssertEqual(cellText(at: editor.state.selection.head, editor), "D", "down moves within column 1 (B→D)")
    }

    func testClickLandsInTheCorrectCellByX() throws {
        let editor = try tableEditor()
        let layout = DocumentLayout(doc: editor.doc, width: 320, theme: TextTheme())
        // The block for cell "D" (second column, second row).
        let dPos = cellTextPosition(editor, "D")
        let dBlock = try XCTUnwrap(layout.blocks.first { $0.contentStart <= dPos && dPos <= $0.contentEnd })
        let center = CGPoint(x: dBlock.frame.midX, y: dBlock.frame.midY)
        let hit = try XCTUnwrap(layout.position(at: center))
        XCTAssertEqual(editor.doc.resolve(hit).parent.textContent, "D", "click in the D cell should map into D, not A/B/C")
    }

    func testTypingEditsTheClickedCell() throws {
        let editor = try tableEditor()
        let view = makeView(editor)
        // Place the caret at the end of cell "C" and type.
        let cPos = cellTextPosition(editor, "C")
        view.editor.dispatch(view.editor.state.tr.setSelection(TextSelection.create(view.editor.doc, cPos + 1)))
        view.insertText("X")
        // The C cell should now read "CX"; the others are untouched.
        var texts: [String] = []
        view.editor.doc.descendants { node, _, _, _ in
            if node.type.name == "tableCell" || node.type.name == "tableHeader" { texts.append(node.textContent) }
            return true
        }
        XCTAssertEqual(texts, ["A", "B", "CX", "D"])
    }

    func testColumnsUseColwidthProportionally() throws {
        let editor = try tableEditor()
        // Give column 0 weight 3, column 1 weight 1 on the first (header) row.
        let s = editor.schema
        func headerCell(_ text: String, _ w: Double) -> Node {
            try! s.node("tableHeader", ["colwidth": .double(w)], content: Fragment.from([
                try! s.node("paragraph", [:], content: Fragment.from([s.text(text)])),
            ]))
        }
        func cell(_ text: String) -> Node {
            try! s.node("tableCell", [:], content: Fragment.from([
                try! s.node("paragraph", [:], content: Fragment.from([s.text(text)])),
            ]))
        }
        let table = try! s.node("table", [:], content: Fragment.from([
            try! s.node("tableRow", [:], content: Fragment.from([headerCell("A", 3), headerCell("B", 1)])),
            try! s.node("tableRow", [:], content: Fragment.from([cell("C"), cell("D")])),
        ]))
        editor.setContent(try! s.node("doc", [:], content: Fragment.from([table])))
        let layout = DocumentLayout(doc: editor.doc, width: 320, theme: TextTheme())
        let info = try XCTUnwrap(layout.tables.first)
        XCTAssertEqual(info.widths.count, 2)
        // 3:1 ratio, normalized to whatever content width the table spans.
        XCTAssertEqual(info.widths[0] / info.widths[1], 3, accuracy: 0.05)
        XCTAssertGreaterThan(info.widths.reduce(0, +), 0)
    }

    func testDraggingAColumnBorderResizesColumns() throws {
        let editor = try tableEditor()
        let view = makeView(editor)
        let info = try XCTUnwrap(DocumentLayout(doc: editor.doc, width: 320, theme: TextTheme()).tables.first)
        let totalBefore = info.widths.reduce(0, +)
        // Border between the two equal columns. Drag it well to the left.
        let borderX = info.borderX(after: 0)
        let y = (info.top + info.bottom) / 2
        view.beginColumnResize(at: CGPoint(x: borderX, y: y))
        view.updateColumnResize(to: CGPoint(x: borderX - 60, y: y))
        view.endColumnResize()
        // Re-read the layout: column 0 should now be narrower than column 1.
        let after = DocumentLayout(doc: view.editor.doc, width: 320, theme: TextTheme())
        let widths = try XCTUnwrap(after.tables.first).widths
        XCTAssertLessThan(widths[0], widths[1], "dragging the border left should shrink column 0")
        XCTAssertEqual(widths.reduce(0, +), totalBefore, accuracy: 1, "total width is preserved")
        // The drag resized columns rather than moving the selection.
        XCTAssertTrue(view.editor.state.selection.empty)
    }

    func testCellsAreLaidOutAsDistinctBlocks() throws {
        let editor = try tableEditor()
        let layout = DocumentLayout(doc: editor.doc, width: 320, theme: TextTheme())
        // Four cells → at least four text blocks with distinct frames.
        let cellTexts = ["A", "B", "C", "D"]
        let frames = cellTexts.map { t -> CGRect in
            let pos = cellTextPosition(editor, t)
            return layout.blocks.first { $0.contentStart <= pos && pos <= $0.contentEnd }?.frame ?? .zero
        }
        // A and B share a row (same y) but differ in x.
        XCTAssertEqual(frames[0].minY, frames[1].minY, accuracy: 1)
        XCTAssertNotEqual(frames[0].minX, frames[1].minX)
        // Row 2 is below row 1.
        XCTAssertGreaterThan(frames[2].minY, frames[0].minY)
    }
}
#endif

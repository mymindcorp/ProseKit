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

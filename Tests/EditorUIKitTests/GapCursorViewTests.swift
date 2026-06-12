#if canImport(UIKit)
import XCTest
import DocumentModel
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

/// View-layer gapcursor behavior: the horizontal gap caret, tap placement via
/// the UITextInput path, and typing materializing a paragraph.
@MainActor
final class GapCursorViewTests: XCTestCase {
    /// An editor whose document is two single-cell tables — gaps exist at the
    /// doc start, between the tables, and at the doc end.
    private func twoTableEditor() throws -> Editor {
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
        return editor
    }

    private func makeView(_ editor: Editor) -> EditorTextView {
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        view.layoutIfNeeded()
        return view
    }

    private func betweenTablesPos(_ editor: Editor) -> Int {
        editor.doc.child(0).nodeSize // boundary after the first table
    }

    func testGapBoundaryPositionFindsTheGapBetweenTables() throws {
        let editor = try twoTableEditor()
        let view = makeView(editor)
        let layout = DocumentLayout(doc: editor.doc, width: 320, theme: TextTheme())
        let t1 = try XCTUnwrap(layout.tables.first)
        let t2 = try XCTUnwrap(layout.tables.last)
        XCTAssertLessThan(t1.bottom, t2.top, "two stacked tables with a margin between them")
        let midY = (t1.bottom + t2.top) / 2
        let gap = view.gapBoundaryPosition(at: CGPoint(x: 40, y: midY))
        XCTAssertEqual(gap, betweenTablesPos(editor))
        // A point inside a cell is not a gap.
        XCTAssertNil(view.gapBoundaryPosition(at: CGPoint(x: 40, y: (t1.top + t1.bottom) / 2)))
    }

    func testTapBetweenTablesPlacesAGapCursorThroughUITextInput() throws {
        let editor = try twoTableEditor()
        let view = makeView(editor)
        let layout = DocumentLayout(doc: editor.doc, width: 320, theme: TextTheme())
        let midY = (layout.tables[0].bottom + layout.tables[1].top) / 2

        // The native caret-placement path: closestPosition → setSelectedTextRange.
        let pos = try XCTUnwrap(view.closestPosition(to: CGPoint(x: 40, y: midY)) as? DocTextPosition)
        XCTAssertEqual(pos.offset, betweenTablesPos(editor))
        view.selectedTextRange = DocTextRange(pos.offset, pos.offset)
        XCTAssertTrue(view.editor.state.selection is GapCursor, "got \(type(of: view.editor.state.selection))")
        XCTAssertEqual(view.editor.state.selection.head, betweenTablesPos(editor))
    }

    func testGapCaretIsAHorizontalBarAtTheBoundary() throws {
        let editor = try twoTableEditor()
        let view = makeView(editor)
        let gapPos = betweenTablesPos(editor)
        editor.dispatch(editor.state.tr.setSelection(GapCursor(editor.doc.resolve(gapPos))))
        let layout = DocumentLayout(doc: editor.doc, width: 320, theme: TextTheme())
        let rect = view.gapCaretRect(at: gapPos, in: view.ensureLayout())
        XCTAssertGreaterThan(rect.width, rect.height, "gap caret is horizontal")
        // It sits at the boundary between the two tables (the neighbor text
        // blocks live inside the tables' borders, so allow a few points).
        XCTAssertGreaterThan(rect.midY, layout.tables[0].bottom - 6)
        XCTAssertLessThan(rect.midY, layout.tables[1].top + 6)
    }

    func testTypingAtTheGapMaterializesAParagraph() throws {
        let editor = try twoTableEditor()
        let view = makeView(editor)
        let gapPos = betweenTablesPos(editor)
        editor.dispatch(editor.state.tr.setSelection(GapCursor(editor.doc.resolve(gapPos))))
        view.insertText("x")
        XCTAssertEqual(editor.doc.childCount, 3)
        XCTAssertEqual(editor.doc.child(1).type.name, "paragraph")
        XCTAssertEqual(editor.doc.child(1).textContent, "x")
        XCTAssertTrue(editor.state.selection is TextSelection)
    }

    func testDocEdgeGapsAreReachable() throws {
        let editor = try twoTableEditor()
        let view = makeView(editor)
        let layout = DocumentLayout(doc: editor.doc, width: 320, theme: TextTheme())
        // Above the first table → gap at 0 (when there's headroom).
        if layout.tables[0].top > 1 {
            XCTAssertEqual(view.gapBoundaryPosition(at: CGPoint(x: 40, y: layout.tables[0].top / 2)), 0)
        }
        // Below the last table → gap at doc end.
        let below = CGPoint(x: 40, y: layout.tables[1].bottom + 10)
        XCTAssertEqual(view.gapBoundaryPosition(at: below), editor.doc.content.size)
    }
}
#endif

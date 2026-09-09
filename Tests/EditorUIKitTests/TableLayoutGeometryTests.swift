#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

/// Geometry queries over a document whose blocks do not run down the page.
///
/// A table lays its cells side by side, so one row's blocks walk down column
/// one and then jump back up to the top of column two: `blocks` is in document
/// order, and document order is not vertical order. Everything here is a
/// question that used to be answered by binary-searching that array by y, or by
/// reading a "row" of side-by-side blocks off the gaps to them — both of which
/// hold only while the page and the document agree on the order.
@MainActor
final class TableLayoutGeometryTests: XCTestCase {
    /// A table whose first row is deliberately lopsided: a cell that wraps to
    /// many lines, then three holding a single word each. That is what puts a
    /// run of blocks with a small `maxY` after one with a large one — enough of
    /// them that a binary search by y lands inside the run and reports the tall
    /// cell as being above the band, rather than the one the band is inside.
    private func lopsidedTableEditor() throws -> Editor {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        func cell(_ name: String, _ text: String) -> Node {
            try! s.node(name, [:], content: Fragment.from([
                try! s.node("paragraph", [:], content: Fragment.from([s.text(text)])),
            ]))
        }
        func row(_ cells: [Node]) -> Node { try! s.node("tableRow", [:], content: Fragment.from(cells)) }
        let long = Array(repeating: "lorem ipsum dolor sit amet", count: 4).joined(separator: " ")
        let table = try! s.node("table", [:], content: Fragment.from([
            row([cell("tableCell", long), cell("tableCell", "b"),
                 cell("tableCell", "x"), cell("tableCell", "y")]),
            row([cell("tableCell", "c"), cell("tableCell", "d"),
                 cell("tableCell", "z"), cell("tableCell", "w")]),
        ]))
        editor.setContent(try! s.node("doc", [:], content: Fragment.from([
            try! s.node("paragraph", [:], content: Fragment.from([s.text("before")])),
            table,
            try! s.node("paragraph", [:], content: Fragment.from([s.text("after")])),
        ])))
        return editor
    }

    private func layout(_ editor: Editor, width: CGFloat = 320) -> DocumentLayout {
        DocumentLayout(doc: editor.doc, width: width, theme: DocumentTheme())
    }

    /// The fixture is only worth anything while it really is out of order.
    func testTheTablePutsBlocksOutOfVerticalOrder() throws {
        let l = layout(try lopsidedTableEditor())
        XCTAssertTrue(zip(l.blocks, l.blocks.dropFirst()).contains { $0.frame.maxY > $1.frame.maxY },
                      "no block sits lower than the one after it — the fixture stopped testing anything")
    }

    /// `selectionRects(clipY:)` promises to change the cost, never the drawing.
    func testClippingASelectionToABandKeepsEveryRectTheBandCovers() throws {
        let editor = try lopsidedTableEditor()
        let l = layout(editor)
        let (from, to) = (0, editor.doc.content.size)
        let all = l.selectionRects(from: from, to: to)
        XCTAssertGreaterThan(all.count, 4, "the fixture should select several lines")
        for rect in all {
            // A band strictly inside one rect: whatever else it catches, it
            // cannot be read as missing this one.
            let band = (rect.minY + 1) ... (rect.maxY - 1)
            let clipped = l.selectionRects(from: from, to: to, clipY: band)
            let expected = all.filter { $0.maxY >= band.lowerBound && $0.minY <= band.upperBound }
            XCTAssertEqual(clipped.count, expected.count,
                           "clipping to \(band) changed which rects are drawn")
            XCTAssertTrue(clipped.contains { abs($0.minY - rect.minY) < 0.001 },
                          "the band inside a rect at y \(rect.minY) dropped that rect")
        }
    }

    /// The same, for a selection that starts and ends inside the tall cell —
    /// the shape a caret drag across one cell makes.
    func testClippingASelectionInsideOneCellKeepsItsRects() throws {
        let editor = try lopsidedTableEditor()
        let l = layout(editor)
        let block = try XCTUnwrap(l.blocks.max(by: { $0.lines.count < $1.lines.count }))
        XCTAssertGreaterThan(block.lines.count, 2, "the wrapping cell should hold several lines")
        let all = l.selectionRects(from: block.contentStart, to: block.contentEnd)
        for line in block.lines {
            let top = line.baselineOrigin.y - line.ascent
            let band = (top + 1) ... (top + line.height - 1)
            let clipped = l.selectionRects(from: block.contentStart, to: block.contentEnd, clipY: band)
            XCTAssertEqual(clipped.count,
                           all.filter { $0.maxY >= band.lowerBound && $0.minY <= band.upperBound }.count,
                           "a band on the line at y \(top) drew the wrong rects")
        }
    }

    /// `positionRange` is the cheap rejection test in front of the mark walk, so
    /// a mark drawn in the band has to survive it.
    func testPositionRangeCoversEveryBlockTheBandTouches() throws {
        // A line at a time, not a block at a time: the band is a viewport, and
        // a cell taller than the screen is exactly the case that used to be
        // searched for in the wrong place.
        let l = layout(try lopsidedTableEditor())
        for block in l.blocks {
            for line in block.lines {
                let top = line.baselineOrigin.y - line.ascent
                let band = (top + 1) ... (top + line.height - 1)
                let range = try XCTUnwrap(l.positionRange(intersecting: band),
                                          "the band on the line at y \(top) is inside the document")
                XCTAssertTrue(block.contentEnd > range.lowerBound && block.contentStart < range.upperBound,
                              "a band on the line at y \(top) rejects the marks of the block drawn there")
            }
        }
    }

    /// ↓ then ↑ comes back to the line it left, in a row whose cells are
    /// different heights: the short cell leaves the row by its own bottom, and
    /// coming back must not land in the tall one just because it reaches higher.
    func testDownThenUpReturnsToTheSameLineInALopsidedRow() throws {
        let editor = try lopsidedTableEditor()
        let l = layout(editor)
        var shortCell = 0
        editor.doc.descendants { node, pos, _, _ in
            if node.isText, node.text == "b" { shortCell = pos + 1 }
            return true
        }
        XCTAssertGreaterThan(shortCell, 0, "didn't find the short cell")
        let here = try XCTUnwrap(l.caretRect(at: shortCell))
        let down = try XCTUnwrap(l.verticalPosition(from: shortCell, up: false, preferredX: here.midX),
                                 "there is a row below to move into")
        XCTAssertEqual(editor.doc.resolve(down).parent.textContent, "d", "↓ left the column")
        let back = try XCTUnwrap(l.verticalPosition(from: down, up: true, preferredX: here.midX))
        let backRect = try XCTUnwrap(l.caretRect(at: back))
        XCTAssertEqual(backRect.minY, here.minY, accuracy: 0.5, "↑ landed on another line")
        XCTAssertEqual(editor.doc.resolve(back).parent.textContent, "b", "↑ came back into the wrong cell")
    }

    /// Moving down out of the tall cell is the other side of the same rule: it
    /// leaves from its own last line, not from the row's.
    func testDownFromTheTallCellStaysInItsColumn() throws {
        let editor = try lopsidedTableEditor()
        let l = layout(editor)
        let block = try XCTUnwrap(l.blocks.max(by: { $0.lines.count < $1.lines.count }))
        let last = try XCTUnwrap(block.lines.last)
        let pos = block.docPos(forAttrIndex: last.stringRange.location)
        let here = try XCTUnwrap(l.caretRect(at: pos))
        let down = try XCTUnwrap(l.verticalPosition(from: pos, up: false, preferredX: here.midX))
        XCTAssertEqual(editor.doc.resolve(down).parent.textContent, "c", "↓ left the column")
    }
}
#endif

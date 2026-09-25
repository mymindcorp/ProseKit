#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

/// Tests for caret up/down movement in the CoreText layout (the bug where
/// moving between paragraphs snapped back into the inter-paragraph gap).
final class VerticalMovementTests: XCTestCase {
    private func editor(_ paragraphs: [String]) throws -> Editor {
        let editor = try Editor(extensions: starterKit())
        let paras = paragraphs.map { line in
            try! editor.schema.node("paragraph", [:], content: Fragment.from(line.isEmpty ? [] : [editor.schema.text(line)]))
        }
        editor.setContent(try! editor.schema.node("doc", [:], content: Fragment.from(paras)))
        return editor
    }

    private func layout(_ editor: Editor, width: CGFloat = 320) -> DocumentLayout {
        DocumentLayout(doc: editor.doc, width: width, theme: DocumentTheme())
    }

    func testDownMovesToNextParagraph() throws {
        let editor = try editor(["alpha", "bravo"])
        let l = layout(editor)
        let caret = try XCTUnwrap(l.caretRect(at: 3)) // inside "alpha"
        let down = try XCTUnwrap(l.verticalPosition(from: 3, up: false, preferredX: caret.midX),
                                 "down arrow should find the next line")
        XCTAssertEqual(editor.doc.resolve(down).parent.textContent, "bravo")
    }

    func testUpMovesToPreviousParagraph() throws {
        let editor = try editor(["alpha", "bravo"])
        let l = layout(editor)
        // Find a position inside "bravo".
        var bravoPos = 0
        editor.doc.descendants { node, pos, _, _ in
            if node.isText, node.text == "bravo" { bravoPos = pos + 1 }
            return true
        }
        let caret = try XCTUnwrap(l.caretRect(at: bravoPos))
        let up = try XCTUnwrap(l.verticalPosition(from: bravoPos, up: true, preferredX: caret.midX),
                               "up arrow should find the previous line")
        XCTAssertEqual(editor.doc.resolve(up).parent.textContent, "alpha")
    }

    func testVisualLineBoundaryWithinWrappedParagraph() throws {
        let editor = try editor([String(repeating: "word ", count: 40)]) // wraps
        let l = layout(editor, width: 160)
        XCTAssertGreaterThan(l.blocks.first?.lines.count ?? 0, 1, "paragraph should wrap to multiple lines")
        // A position on the second visual line.
        let secondLine = try XCTUnwrap(l.blocks.first?.lines[1])
        let midAttr = secondLine.stringRange.location + secondLine.stringRange.length / 2
        let block = try XCTUnwrap(l.blocks.first)
        let pos = block.docPos(forAttrIndex: midAttr)
        let home = try XCTUnwrap(l.lineBoundary(from: pos, toEnd: false))
        let end = try XCTUnwrap(l.lineBoundary(from: pos, toEnd: true))
        // Home/End land on the visual line, not the whole textblock.
        XCTAssertGreaterThan(home, block.contentStart, "Home should not jump to the block start")
        XCTAssertLessThan(end, block.contentEnd, "End should not jump to the block end")
        XCTAssertLessThan(home, pos)
        XCTAssertGreaterThan(end, pos)
    }

    func testNoMovementPastDocumentEdges() throws {
        let editor = try editor(["only"])
        let l = layout(editor)
        XCTAssertNil(l.verticalPosition(from: 3, up: true, preferredX: 0), "no line above the first")
        XCTAssertNil(l.verticalPosition(from: 3, up: false, preferredX: 0), "no line below the last")
    }

    func testDownWithinWrappedParagraph() throws {
        let editor = try editor([String(repeating: "word ", count: 60)])
        let l = layout(editor, width: 180) // narrow → wraps to several lines
        let caret = try XCTUnwrap(l.caretRect(at: 3))
        let down = try XCTUnwrap(l.verticalPosition(from: 3, up: false, preferredX: caret.midX),
                                 "down should move to the next wrapped line")
        XCTAssertGreaterThan(down, 3)
    }

    func testColumnIsPreserved() throws {
        let editor = try editor(["abcdefgh", "ijklmnop"])
        let l = layout(editor)
        let fromPos = 5 // middle of "abcdefgh"
        let caret = try XCTUnwrap(l.caretRect(at: fromPos))
        let down = try XCTUnwrap(l.verticalPosition(from: fromPos, up: false, preferredX: caret.midX))
        // Should land in "ijklmnop" near the same column, not at its start/end.
        let resolved = editor.doc.resolve(down)
        XCTAssertEqual(resolved.parent.textContent, "ijklmnop")
        XCTAssertGreaterThan(resolved.parentOffset, 0)
    }
    // MARK: - An atom that wraps

    // An atom drawn as text — math with no renderer, a wiki link that isn't a
    // chip — is one position wide but can be wider than its column, and then it
    // wraps. The lines in the middle of it hold no caret position of their own.
    // Found by the geometry fuzzer in narrow table cells (seeds 63 and 207 at
    // depth 250); a narrow page is the same shape without the table.

    /// "abc…z" / [x link, math, "Some Page" link] / "after". Math with no
    /// renderer is drawn as its source, in the code font, so a long formula at
    /// a narrow width wraps.
    private func atomLayout(latex: String, width: CGFloat) throws -> (DocumentLayout, atomBlock: TextBlock) {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        let doc = try s.node("doc", [:], content: Fragment.from([
            s.node("paragraph", [:], content: Fragment.from([s.text("abcdefghijklmnopqrstuvwxyz")])),
            s.node("paragraph", [:], content: Fragment.from([
                s.node("wikiLink", ["text": .string("x")]),
                s.node("inlineMath", ["latex": .string(latex)]),
                s.node("wikiLink", ["text": .string("Some Page")]),
            ])),
            s.node("paragraph", [:], content: Fragment.from([s.text("after")])),
        ]))
        editor.setContent(doc)
        XCTAssertEqual(editor.doc, doc)
        let l = DocumentLayout(doc: editor.doc, width: width, theme: DocumentTheme())
        return (l, try XCTUnwrap(l.blocks.first { $0.contentStart == 29 }))
    }

    /// A formula that wraps across lines holding no caret position at all.
    private func wrappedAtomLayout() throws -> DocumentLayout {
        let (l, block) = try atomLayout(latex: "\\frac{abcdefgh}{ijklmnop}", width: 120)
        let drawn = Set((29 ... 32).compactMap { l.caretRect(at: $0)?.minY })
        XCTAssertLessThan(drawn.count, block.lines.count, "every line of the atom's block holds a caret; the atom didn't wrap")
        return l
    }

    func testDownThenUpAroundAWrappedAtomReturnsToTheSameLine() throws {
        // Down from before the atom landed on the line it wraps through, which
        // draws the caret after the atom — and up from there went back into the
        // same line and stayed below where it started.
        let l = try wrappedAtomLayout()
        for pos in 29 ... 32 {
            let here = try XCTUnwrap(l.caretRect(at: pos))
            guard let down = l.verticalPosition(from: pos, up: false, preferredX: here.midX) else { continue }
            let back = try XCTUnwrap(l.verticalPosition(from: down, up: true, preferredX: here.midX))
            XCTAssertEqual(try XCTUnwrap(l.caretRect(at: back)).minY, here.minY, accuracy: 0.5,
                           "down then up from \(pos) went via \(down) to \(back), on another line")
        }
    }

    func testDownOntoAWrappedAtomFromFarRightComesBackUp() throws {
        // The atom's first line holds most of it, so a column right of the
        // middle answers with the index past the atom's midpoint — the position
        // *after* it, drawn on the line below. Down from above skipped the
        // atom's first line, and up from there aimed at that line, got the same
        // answer, and stayed put. (In the fuzzer the caret came from the next
        // table column over, far right of a narrow cell's contents.)
        let (l, block) = try atomLayout(latex: "\\frac{a}{b}", width: 130)
        XCTAssertGreaterThan(block.lines.count, 1, "the atom's block didn't wrap")
        let x = block.frame.maxX - 1
        let from = 27 // the end of "abc…z"
        let here = try XCTUnwrap(l.caretRect(at: from))
        let down = try XCTUnwrap(l.verticalPosition(from: from, up: false, preferredX: x))
        let first = block.lines[0]
        XCTAssertEqual(try XCTUnwrap(l.caretRect(at: down)).minY, first.baselineOrigin.y - first.ascent, accuracy: 0.5,
                       "down from above the atom skipped its first line, to \(down)")
        let back = try XCTUnwrap(l.verticalPosition(from: down, up: true, preferredX: x))
        XCTAssertEqual(try XCTUnwrap(l.caretRect(at: back)).minY, here.minY, accuracy: 0.5,
                       "down then up from \(from) landed on another line (\(back))")
    }

    func testMovingDownPastAWrappedAtomReachesTheEnd() throws {
        // Down from before the atom came back to the position after the x link
        // — drawn on the line it started on — forever, under a held arrow key.
        let l = try wrappedAtomLayout()
        for start in [29, 30] {
            let x = try XCTUnwrap(l.caretRect(at: start)).midX
            var pos = start, steps = 0
            while let next = l.verticalPosition(from: pos, up: false, preferredX: x) {
                XCTAssertGreaterThan(try XCTUnwrap(l.caretRect(at: next)).minY,
                                     try XCTUnwrap(l.caretRect(at: pos)).minY,
                                     "down from \(pos) stalled at \(next)")
                pos = next
                steps += 1
                if steps > 20 { return XCTFail("moving down from \(start) never reached the end") }
            }
            XCTAssertGreaterThanOrEqual(pos, 34, "moving down from \(start) stopped short of the last paragraph, at \(pos)")
        }
    }
    func testALineThatOpensPartwayThroughAnAtomStartsAtItsOwnFirstCaret() throws {
        // Home from the end of a line holding only the tail of a wrapped atom
        // went to the atom's start — the line's first index maps there — which
        // is drawn on the line above. (Seed 506 at depth 1000: two formulas in a
        // details summary, the second breaking after its first character.)
        // Where CoreText breaks depends on the width, so sweep a range of them
        // and check the shape turned up.
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        let doc = try s.node("doc", [:], content: Fragment.from([
            s.node("paragraph", [:], content: Fragment.from([
                s.node("wikiLink", ["text": .string("Some Page")]),
                s.node("inlineMath", ["latex": .string("\\frac{a}{b}")]),
                s.node("inlineMath", ["latex": .string("\\frac{a}{b}")]),
            ])),
        ]))
        editor.setContent(doc)
        XCTAssertEqual(editor.doc, doc)
        var openedMidAtom = 0
        for width in stride(from: CGFloat(200), through: 340, by: 2) {
            let l = DocumentLayout(doc: editor.doc, width: width, theme: DocumentTheme())
            let block = try XCTUnwrap(l.blocks.first)
            openedMidAtom += block.lines.filter { line in
                block.segments.contains { $0.text == nil && $0.attrStart < line.stringRange.location
                    && line.stringRange.location < $0.attrStart + $0.attrLen }
            }.count
            for pos in 1 ... 4 {
                let here = try XCTUnwrap(l.caretRect(at: pos))
                let start = try XCTUnwrap(l.lineBoundary(from: pos, toEnd: false))
                XCTAssertLessThanOrEqual(start, pos, "the line start is after \(pos) at width \(width)")
                XCTAssertEqual(try XCTUnwrap(l.caretRect(at: start)).minY, here.minY, accuracy: 0.5,
                               "the line start of \(pos) is \(start), on another line, at width \(width)")
                XCTAssertEqual(l.lineBoundary(from: start, toEnd: false), start,
                               "going to the line start twice moved again, from \(pos), at width \(width)")
            }
        }
        XCTAssertGreaterThan(openedMidAtom, 0, "no line opened partway through an atom at any width")
    }
}
#endif

#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import SchemaKit
import EditorStateKit
import DocumentTransform
@testable import EditorUIKit

/// Tapping the end of a soft-wrapped line.
///
/// A soft wrap is one document position with two places on screen: the end of
/// the line that wrapped, and the start of the line it wrapped onto. Tapping
/// past the last glyph of the first one resolves to that position, and with
/// nothing recording which side was meant, the caret is drawn at the start of
/// the next line — so the end of a wrapped line cannot be reached by tapping.
@MainActor
final class CaretLineWrapAffinityTests: XCTestCase {
    /// A paragraph long enough to wrap several times at this width.
    private func wrappedView() -> EditorTextView {
        let editor = try! Editor(extensions: fullKit())
        let s = editor.schema
        let text = Array(repeating: "lorem ipsum dolor sit amet consectetur adipiscing", count: 6)
            .joined(separator: " ")
        editor.setContent(try! s.node("doc", [:], content: Fragment.from([
            try! s.node("paragraph", [:], content: Fragment.from([s.text(text)])),
        ])))
        let v = EditorTextView(editor: editor)
        v.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        v.layoutIfNeeded()
        return v
    }

    /// A point just inside the right-hand end of a line — where a finger lands
    /// when reaching for the end of it.
    private func pointAtEndOf(_ line: LineLayout, in block: TextBlock) -> CGPoint {
        let width = CTLineGetTypographicBounds(line.ctLine, nil, nil, nil)
        return CGPoint(x: line.baselineOrigin.x + CGFloat(width) - 1,
                       y: line.baselineOrigin.y - line.ascent + line.height / 2)
    }

    /// Through the view, not the layout: a tap reaches UIKit as
    /// `closestPosition(to:)` and comes back as `caretRect(for:)`, and the
    /// side of the wrap is only known in between. Asking the layout directly
    /// skips the part being fixed — the first version of these tests did
    /// exactly that and went on failing after the fix landed.
    private func caretForTap(_ v: EditorTextView, at point: CGPoint) -> CGRect? {
        guard let p = v.closestPosition(to: point) else { return nil }
        return v.caretRect(for: p)
    }

    func testTappingTheEndOfAWrappedLineKeepsTheCaretOnThatLine() {
        let v = wrappedView()
        let block = v.ensureLayout().blocks[0]
        XCTAssertGreaterThan(block.lines.count, 3, "the paragraph must wrap")

        // Every wrapped line except the last: the last one ends the paragraph,
        // which is an unambiguous position and not part of this bug.
        for i in 0 ..< (block.lines.count - 1) {
            let line = block.lines[i]
            guard let caret = caretForTap(v, at: pointAtEndOf(line, in: block)) else {
                return XCTFail("no caret for a tap on line \(i)")
            }
            let lineTop = line.baselineOrigin.y - line.ascent
            XCTAssertEqual(caret.midY, lineTop + line.height / 2, accuracy: line.height / 2,
                           "tapping the end of line \(i) put the caret on another line")
        }
    }

    func testTheCaretLandsAfterTheLastVisibleCharacterOfThatLine() {
        // Not just the right line — the right end of it. Tapping the end of a
        // line should not drop the caret at its start.
        let v = wrappedView()
        let block = v.ensureLayout().blocks[0]
        let line = block.lines[1]
        guard let caret = caretForTap(v, at: pointAtEndOf(line, in: block)) else {
            return XCTFail("no caret for a tap at the end of line 1")
        }
        let width = CGFloat(CTLineGetTypographicBounds(line.ctLine, nil, nil, nil))
        XCTAssertGreaterThan(caret.midX, line.baselineOrigin.x + width / 2,
                             "the caret landed in the left half of the tapped line")
    }

    func testTappingTheStartOfALineStillLandsThere() {
        // The other side of the same boundary must keep working: tapping at the
        // very start of a wrapped line belongs to that line, not the one above.
        let v = wrappedView()
        let block = v.ensureLayout().blocks[0]
        for i in 1 ..< min(block.lines.count, 4) {
            let line = block.lines[i]
            let point = CGPoint(x: line.baselineOrigin.x + 1,
                                y: line.baselineOrigin.y - line.ascent + line.height / 2)
            guard let caret = caretForTap(v, at: point) else {
                return XCTFail("no caret for a tap at the start of line \(i)")
            }
            let lineTop = line.baselineOrigin.y - line.ascent
            XCTAssertEqual(caret.midY, lineTop + line.height / 2, accuracy: line.height / 2,
                           "tapping the start of line \(i) put the caret on another line")
        }
    }

    func testAWrappedRightToLeftLineBehavesTheSameWay() {
        // `atLineEnd` is decided on the logical end of the line, which in RTL
        // text is the visually leftmost glyph. The invariant is the same and
        // direction-agnostic — a tap stays on the line it landed on — but
        // nothing else here runs the RTL path.
        let editor = try! Editor(extensions: fullKit())
        let s = editor.schema
        let text = Array(repeating: "שלום עולם זהו טקסט בעברית", count: 8).joined(separator: " ")
        editor.setContent(try! s.node("doc", [:], content: Fragment.from([
            try! s.node("paragraph", [:], content: Fragment.from([s.text(text)])),
        ])))
        let v = EditorTextView(editor: editor)
        v.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        v.layoutIfNeeded()
        let block = v.ensureLayout().blocks[0]
        XCTAssertGreaterThan(block.lines.count, 2, "the paragraph must wrap")

        for i in 0 ..< (block.lines.count - 1) {
            let line = block.lines[i]
            let y = line.baselineOrigin.y - line.ascent + line.height / 2
            // Both ends of the line: which one is "the end" depends on the
            // writing direction, and either must stay on this line.
            let width = CGFloat(CTLineGetTypographicBounds(line.ctLine, nil, nil, nil))
            for x in [line.baselineOrigin.x + 1, line.baselineOrigin.x + width - 1] {
                guard let caret = caretForTap(v, at: CGPoint(x: x, y: y)) else {
                    return XCTFail("no caret for a tap on RTL line \(i)")
                }
                XCTAssertEqual(caret.midY, y, accuracy: line.height / 2,
                               "tapping RTL line \(i) at x=\(x) moved the caret off it")
            }
        }
    }

    func testTheTappedPositionIsTheSameEitherSideOfTheWrap() {
        // Affinity must change where the caret is drawn and nothing else. The
        // end of one line and the start of the next are the same place in the
        // document, and typing at either must insert at the same offset.
        let v = wrappedView()
        let block = v.ensureLayout().blocks[0]
        let first = block.lines[1], second = block.lines[2]
        let endOfFirst = v.closestPosition(to: pointAtEndOf(first, in: block))
        let startOfSecond = v.closestPosition(to: CGPoint(
            x: second.baselineOrigin.x + 1,
            y: second.baselineOrigin.y - second.ascent + second.height / 2))
        XCTAssertEqual((endOfFirst as? DocTextPosition)?.offset,
                       (startOfSecond as? DocTextPosition)?.offset,
                       "the two sides of a wrap must be one document position")
    }

    func testTypingAtTheEndOfAWrappedLineInsertsThere() {
        // The whole point of reaching the end of the line: continuing to edit.
        let v = wrappedView()
        let block = v.ensureLayout().blocks[0]
        let line = block.lines[1]
        guard let p = v.closestPosition(to: pointAtEndOf(line, in: block)) as? DocTextPosition else {
            return XCTFail("no position at the end of line 1")
        }
        v.selectedTextRange = DocTextRange(p.offset, p.offset)
        v.insertText("Z")
        v.layoutIfNeeded()
        XCTAssertEqual(v.projectedText(from: p.offset, to: p.offset + 1), "Z",
                       "typing after tapping the line end did not insert there")
    }
}
#endif

#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import SchemaKit
import EditorStateKit
import DocumentTransform
@testable import EditorUIKit

/// Where a tap puts the caret at a soft wrap, and in the space under a block.
///
/// A soft wrap is one document position with two places on screen: the end of
/// the line that wrapped and the start of the line it wrapped onto. It gets ONE
/// caret, at the later of the two.
///
/// Which is not an accident of the layout — it is the only thing we can draw.
/// UITextInteraction places its own caret from our `UITextInput` geometry,
/// beside the one we draw, and it has no notion of affinity to hand us: drawing
/// the position anywhere other than where it thinks the position is puts a
/// second caret on the screen. It also declines to hold a caret we hand back
/// from the space a line broke at, moving it on to the following line, so
/// neither half of "draw it at the end of the wrapped line" survives contact
/// with the system. See `testTheCaretWeDrawIsWhereTheSystemDrawsItsOwn`.
@MainActor
final class CaretLineWrapTests: XCTestCase {
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
    private func pointAtEndOf(_ line: LineLayout) -> CGPoint {
        let width = CTLineGetTypographicBounds(line.ctLine, nil, nil, nil)
        return CGPoint(x: line.baselineOrigin.x + CGFloat(width) - 1,
                       y: line.baselineOrigin.y - line.ascent + line.height / 2)
    }

    private func pointAtStartOf(_ line: LineLayout) -> CGPoint {
        CGPoint(x: line.baselineOrigin.x + 1,
                y: line.baselineOrigin.y - line.ascent + line.height / 2)
    }

    /// Through the view, not the layout: a tap reaches UIKit as
    /// `closestPosition(to:)` and comes back as `caretRect(for:)`, and asking
    /// the layout directly skips the part being tested.
    private func caretForTap(_ v: EditorTextView, at point: CGPoint) -> CGRect? {
        guard let p = v.closestPosition(to: point) else { return nil }
        return v.caretRect(for: p)
    }

    func testAWrapIsOnePositionDrawnInOnePlace() {
        // Both sides of the break resolve to one position, and that position has
        // one rect. Two rects for it is the double caret.
        let v = wrappedView()
        let block = v.ensureLayout().blocks[0]
        XCTAssertGreaterThan(block.lines.count, 3, "the paragraph must wrap")

        for i in 0 ..< (block.lines.count - 1) {
            guard let end = v.closestPosition(to: pointAtEndOf(block.lines[i])) as? DocTextPosition else {
                return XCTFail("no position at the end of line \(i)")
            }
            // Read the rect for the end-of-line tap BEFORE tapping the other
            // side. Reading both afterwards is what makes this test vacuous
            // against a caret that remembers which side it was tapped from: the
            // second tap sets the memory both readings then agree with.
            let fromTheEnd = v.caretRect(for: end)
            guard let start = v.closestPosition(to: pointAtStartOf(block.lines[i + 1])) as? DocTextPosition else {
                return XCTFail("no position at the start of line \(i + 1)")
            }
            XCTAssertEqual(end.offset, start.offset, "the two sides of the wrap after line \(i) are one position")
            XCTAssertEqual(fromTheEnd, v.caretRect(for: start),
                           "one position, drawn in two places, is two carets")
        }
    }

    func testWhereACaretIsDrawnDependsOnlyOnWhereItIs() {
        // The double caret, at its root. UITextInteraction draws its own cursor
        // from `caretRect(for:)`, beside the one we draw, and it asks only about
        // the position — so anything else we let the answer depend on, such as
        // which side of a wrap the finger was on, is a second cursor on screen.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        let v = wrappedView()
        window.addSubview(v)
        window.makeKeyAndVisible()
        XCTAssertTrue(v.becomeFirstResponder())

        let block = v.ensureLayout().blocks[0]
        for i in 0 ..< (block.lines.count - 1) {
            guard let p = v.closestPosition(to: pointAtEndOf(block.lines[i])) as? DocTextPosition else {
                return XCTFail("no position at the end of line \(i)")
            }
            v.selectedTextRange = DocTextRange(p.offset, p.offset)
            let asTapped = v.caretRect(for: p)
            XCTAssertEqual(v.caretViewRectForTesting, asTapped,
                           "we draw line \(i)'s caret where the system would not")
            // The same position, arrived at from anywhere else.
            _ = v.closestPosition(to: pointAtStartOf(block.lines[0]))
            v.selectedTextRange = DocTextRange(p.offset, p.offset)
            XCTAssertEqual(v.caretRect(for: p), asTapped,
                           "line \(i)'s caret moved without the position moving")
            XCTAssertEqual(v.caretViewRectForTesting, asTapped,
                           "we drew line \(i)'s caret somewhere the system does not")
        }
    }

    func testTappingTheStartOfALineLandsThere() {
        let v = wrappedView()
        let block = v.ensureLayout().blocks[0]
        for i in 1 ..< min(block.lines.count, 4) {
            let line = block.lines[i]
            guard let caret = caretForTap(v, at: pointAtStartOf(line)) else {
                return XCTFail("no caret for a tap at the start of line \(i)")
            }
            let lineTop = line.baselineOrigin.y - line.ascent
            XCTAssertEqual(caret.midY, lineTop + line.height / 2, accuracy: line.height / 2,
                           "tapping the start of line \(i) put the caret on another line")
            XCTAssertEqual(caret.minX, line.baselineOrigin.x, accuracy: 1,
                           "tapping the start of line \(i) did not land at its start")
        }
    }

    func testALineOwnsItsTopEdgeAndNotTheOneAbove() {
        // Lines abut: the bottom of one is the top of the next. Asking for the
        // first line whose band contains the point answered that shared edge
        // with the line above, so the topmost row of pixels of every line but
        // the first belonged to the wrong line.
        let v = wrappedView()
        let block = v.ensureLayout().blocks[0]
        let line = block.lines[2]
        let top = line.baselineOrigin.y - line.ascent
        guard let caret = caretForTap(v, at: CGPoint(x: line.baselineOrigin.x + 1, y: top)) else {
            return XCTFail("no caret for a tap on line 2's top edge")
        }
        XCTAssertEqual(caret.minY, top, accuracy: 1, "the top edge of a line belongs to that line")
    }

    func testATapInsideARightToLeftLineStaysOnIt() {
        // Nothing else here runs the RTL path, where the logical end of a line
        // is its leftmost glyph.
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

        for i in 0 ..< block.lines.count {
            let line = block.lines[i]
            let y = line.baselineOrigin.y - line.ascent + line.height / 2
            let width = CGFloat(CTLineGetTypographicBounds(line.ctLine, nil, nil, nil))
            guard let caret = caretForTap(v, at: CGPoint(x: line.baselineOrigin.x + width / 2, y: y)) else {
                return XCTFail("no caret for a tap on RTL line \(i)")
            }
            XCTAssertEqual(caret.midY, y, accuracy: line.height / 2,
                           "tapping the middle of RTL line \(i) moved the caret off it")
        }
    }

    /// A paragraph with a heading under it — the two are spaced apart, and the
    /// space belongs to neither.
    private func paragraphAboveAHeading() -> EditorTextView {
        let editor = try! Editor(extensions: fullKit())
        let s = editor.schema
        editor.setContent(try! s.node("doc", [:], content: Fragment.from([
            try! s.node("paragraph", [:], content: Fragment.from([
                s.text("A native Swift rich-text editor — a faithful port. Try typing, and code."),
            ])),
            try! s.node("heading", ["level": .int(2)], content: Fragment.from([s.text("Lists")])),
        ])))
        let v = EditorTextView(editor: editor)
        v.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        v.layoutIfNeeded()
        return v
    }

    func testTappingRightOfTheLastLineOfAParagraphLandsAtItsEnd() {
        let v = paragraphAboveAHeading()
        let para = v.ensureLayout().blocks[0]
        let last = para.lines[para.lines.count - 1]
        let y = last.baselineOrigin.y - last.ascent + last.height / 2
        guard let p = v.closestPosition(to: CGPoint(x: para.frame.maxX - 4, y: y)) as? DocTextPosition else {
            return XCTFail("no position at the end of the paragraph")
        }
        XCTAssertEqual(p.offset, para.contentEnd, "a tap past the last line did not reach the paragraph's end")
    }

    func testTappingUnderTheLastLineOfAParagraphStaysInIt() {
        // The end of a paragraph, reached the way a finger reaches it: at the
        // right-hand end of the last line, a little low. The space under a block
        // belongs to no block, and going to the nearest block MIDDLE gave all of
        // it to the short heading below — a paragraph is as tall as it is long,
        // so its middle is far away. The end of a paragraph could not be tapped.
        let v = paragraphAboveAHeading()
        let l = v.ensureLayout()
        let para = l.blocks[0], heading = l.blocks[1]
        XCTAssertGreaterThan(heading.frame.minY, para.frame.maxY, "the blocks must be spaced apart")

        let y = para.frame.maxY + (heading.frame.minY - para.frame.maxY) / 4
        guard let p = v.closestPosition(to: CGPoint(x: para.frame.maxX - 4, y: y)) as? DocTextPosition else {
            return XCTFail("no position just under the paragraph")
        }
        XCTAssertEqual(p.offset, para.contentEnd, "a tap under the paragraph jumped to the next block")
    }

    func testTheFarSideOfTheGapStillBelongsToTheBlockBelow() {
        // The gap splits down the middle; it is not simply handed to the block
        // above instead.
        let v = paragraphAboveAHeading()
        let l = v.ensureLayout()
        let para = l.blocks[0], heading = l.blocks[1]
        let y = heading.frame.minY - (heading.frame.minY - para.frame.maxY) / 4
        guard let p = v.closestPosition(to: CGPoint(x: heading.frame.minX + 1, y: y)) as? DocTextPosition else {
            return XCTFail("no position just above the heading")
        }
        XCTAssertEqual(p.offset, heading.contentStart, "a tap just above the heading did not reach it")
    }
}
#endif

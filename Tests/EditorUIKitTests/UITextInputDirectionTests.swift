#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

/// The direction-taking half of `UITextInput`.
///
/// `UITextInputTests` covers what the system asks while *editing* — reading
/// text, replacing ranges, marked text. This covers what it asks while
/// *navigating*: the four `UITextLayoutDirection` methods, the range-relative
/// hit tests, and the writing direction. Nothing in the suite called them, and
/// they are not ours to call — UIKit does, for arrow keys, the selection
/// handles, the loupe, and keyboard text traversal. A wrong answer here is a
/// caret that jumps to the wrong place under someone's finger, with no code of
/// ours in the stack to blame.
@MainActor
final class UITextInputDirectionTests: XCTestCase {
    private func makeView(_ paragraphs: [String] = ["alpha one", "bravo two", "charlie three"]) throws -> EditorTextView {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        let blocks = paragraphs.map { text in
            try! s.node("paragraph", [:], content: Fragment.from(text.isEmpty ? [] : [s.text(text)]))
        }
        editor.setContent(try s.node("doc", [:], content: Fragment.from(blocks)))
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        view.layoutIfNeeded()
        return view
    }

    private func pos(_ p: UITextPosition?) -> Int? { (p as? DocTextPosition)?.offset }
    private func bounds(_ r: UITextRange?) -> (from: Int, to: Int)? {
        (r as? DocTextRange).map { ($0.from, $0.to) }
    }

    // MARK: - position(from:in:offset:)

    func testHorizontalDirectionsAreSignedOffsets() throws {
        let view = try makeView()
        let start = DocTextPosition(5)
        XCTAssertEqual(pos(view.position(from: start, in: .right, offset: 3)), 8)
        XCTAssertEqual(pos(view.position(from: start, in: .left, offset: 3)), 2)
        // Off either end there is no position, exactly as `position(from:offset:)` says.
        XCTAssertNil(view.position(from: DocTextPosition(1), in: .left, offset: 5))
        XCTAssertNil(view.position(from: DocTextPosition(view.editor.doc.content.size), in: .right, offset: 1))
    }

    func testVerticalDirectionsMoveByLine() throws {
        let view = try makeView()
        // Position 12 is inside the second paragraph ("bravo two" starts at 12).
        let inSecond = DocTextPosition(14)
        let up = try XCTUnwrap(pos(view.position(from: inSecond, in: .up, offset: 1)))
        let down = try XCTUnwrap(pos(view.position(from: inSecond, in: .down, offset: 1)))
        XCTAssertLessThan(up, 11, "up from the second paragraph lands in the first")
        XCTAssertGreaterThan(down, 22, "down lands in the third")
        // Two steps up from the third paragraph reaches the first.
        let inThird = DocTextPosition(25)
        let twoUp = try XCTUnwrap(pos(view.position(from: inThird, in: .up, offset: 2)))
        XCTAssertLessThan(twoUp, 11, "two lines up from the third paragraph is the first")
    }

    func testVerticalMovementStopsAtTheDocumentEdgeInsteadOfRunningOff() throws {
        let view = try makeView()
        // More steps than there are lines: it stops at the first line rather
        // than walking past the start of the document.
        let far = try XCTUnwrap(pos(view.position(from: DocTextPosition(25), in: .up, offset: 50)))
        XCTAssertGreaterThanOrEqual(far, 0)
        XCTAssertLessThan(far, 11)
        let down = try XCTUnwrap(pos(view.position(from: DocTextPosition(3), in: .down, offset: 50)))
        XCTAssertLessThanOrEqual(down, view.editor.doc.content.size)
    }

    func testAZeroOffsetVerticalMoveStaysPut() throws {
        let view = try makeView()
        XCTAssertEqual(pos(view.position(from: DocTextPosition(14), in: .up, offset: 0)), 14)
        XCTAssertEqual(pos(view.position(from: DocTextPosition(14), in: .down, offset: 0)), 14)
    }

    func testAForeignPositionIsDeclinedRatherThanAssumed() throws {
        let view = try makeView()
        // UIKit hands back the positions we gave it, but the protocol allows
        // any `UITextPosition`; a foreign one must not be read as offset 0.
        let foreign = UITextPosition()
        XCTAssertNil(view.position(from: foreign, in: .right, offset: 1))
        XCTAssertNil(view.position(from: foreign, offset: 1))
        XCTAssertNil(view.characterRange(byExtending: foreign, in: .right))
        XCTAssertNil(view.textRange(from: foreign, to: DocTextPosition(1)))
    }

    // MARK: - position(within:farthestIn:)

    func testFarthestPositionInARangeIsItsNearOrFarEnd() throws {
        let view = try makeView()
        let range = DocTextRange(4, 9)
        XCTAssertEqual(pos(view.position(within: range, farthestIn: .left)), 4)
        XCTAssertEqual(pos(view.position(within: range, farthestIn: .up)), 4)
        XCTAssertEqual(pos(view.position(within: range, farthestIn: .right)), 9)
        XCTAssertEqual(pos(view.position(within: range, farthestIn: .down)), 9)
        XCTAssertNil(view.position(within: UITextRange(), farthestIn: .left))
    }

    // MARK: - characterRange(byExtending:in:)

    func testExtendingByOneCharacterGoesTheWayItIsAsked() throws {
        let view = try makeView()
        XCTAssertEqual(bounds(view.characterRange(byExtending: DocTextPosition(5), in: .right))?.from, 5)
        XCTAssertEqual(bounds(view.characterRange(byExtending: DocTextPosition(5), in: .right))?.to, 6)
        XCTAssertEqual(bounds(view.characterRange(byExtending: DocTextPosition(5), in: .left))?.from, 4)
        XCTAssertEqual(bounds(view.characterRange(byExtending: DocTextPosition(5), in: .left))?.to, 5)
        XCTAssertEqual(bounds(view.characterRange(byExtending: DocTextPosition(5), in: .up))?.from, 4, "up reads as backward")
        XCTAssertEqual(bounds(view.characterRange(byExtending: DocTextPosition(5), in: .down))?.to, 6, "down reads as forward")
    }

    func testExtendingAtTheDocumentEdgesClampsInsteadOfGoingOutOfBounds() throws {
        let view = try makeView()
        let end = view.editor.doc.content.size
        let atStart = try XCTUnwrap(bounds(view.characterRange(byExtending: DocTextPosition(0), in: .left)))
        XCTAssertEqual(atStart.from, 0)
        XCTAssertEqual(atStart.to, 0, "nothing before the start of the document")
        let atEnd = try XCTUnwrap(bounds(view.characterRange(byExtending: DocTextPosition(end), in: .right)))
        XCTAssertEqual(atEnd.from, end)
        XCTAssertEqual(atEnd.to, end, "nothing past the end of it")
    }

    // MARK: - Writing direction

    func testWritingDirectionIsNaturalAndSettingItIsAccepted() throws {
        let view = try makeView()
        XCTAssertEqual(view.baseWritingDirection(for: DocTextPosition(3), in: .forward), .natural)
        XCTAssertEqual(view.baseWritingDirection(for: DocTextPosition(3), in: .backward), .natural)
        // The setter is a no-op the system is allowed to call; it must not
        // disturb the document or the selection.
        let before = view.editor.doc
        view.setBaseWritingDirection(.rightToLeft, for: DocTextRange(1, 4))
        XCTAssertEqual(view.editor.doc, before)
    }

    // MARK: - Point hit tests

    /// A point inside the first paragraph's text, in the view's own coordinates.
    private func pointInFirstParagraph(_ view: EditorTextView) throws -> CGPoint {
        let caret = view.caretRect(for: DocTextPosition(3))
        XCTAssertFalse(caret.isNull)
        return CGPoint(x: caret.midX, y: caret.midY)
    }

    func testClosestPositionWithinARangeIsClampedToIt() throws {
        let view = try makeView()
        let point = try pointInFirstParagraph(view)
        let free = try XCTUnwrap(pos(view.closestPosition(to: point)))
        XCTAssertEqual(free, 3, accuracy: 1, "the unconstrained answer is where we aimed")
        // The same point, asked within a range that ends before it, comes back
        // pinned to the range — this is what keeps a drag handle inside its
        // sentence instead of jumping past it.
        let clamped = try XCTUnwrap(pos(view.closestPosition(to: point, within: DocTextRange(6, 9))))
        XCTAssertEqual(clamped, 6)
        let clampedAbove = try XCTUnwrap(pos(view.closestPosition(to: point, within: DocTextRange(1, 2))))
        XCTAssertEqual(clampedAbove, 2)
        // A point that is genuinely inside the range comes back untouched.
        XCTAssertEqual(pos(view.closestPosition(to: point, within: DocTextRange(1, 9))), free)
    }

    func testClosestPositionWithinAForeignRangeFallsBackToTheFreeAnswer() throws {
        let view = try makeView()
        let point = try pointInFirstParagraph(view)
        XCTAssertEqual(pos(view.closestPosition(to: point, within: UITextRange())),
                       pos(view.closestPosition(to: point)))
    }

    func testCharacterRangeAtAPointIsTheOneCharacterUnderIt() throws {
        let view = try makeView()
        let point = try pointInFirstParagraph(view)
        let range = try XCTUnwrap(bounds(view.characterRange(at: point)))
        XCTAssertEqual(range.to - range.from, 1, "one character wide")
        XCTAssertEqual(range.from, 3, accuracy: 1)
    }

    func testCharacterRangeAtThePointPastTheLastCharacterStaysInsideTheDocument() throws {
        let view = try makeView()
        let end = view.editor.doc.content.size
        let caret = view.caretRect(for: DocTextPosition(end))
        let range = try XCTUnwrap(bounds(view.characterRange(at: CGPoint(x: caret.maxX + 40, y: caret.midY))))
        XCTAssertLessThanOrEqual(range.to, end, "never past the end of the document")
        XCTAssertLessThanOrEqual(range.from, range.to)
    }

    // MARK: - Marked-text style

    func testTheMarkedTextStyleIsStoredAsGiven() throws {
        let view = try makeView()
        XCTAssertNil(view.markedTextStyle)
        // The system sets this to style an in-progress IME composition; it is
        // ours only to hold and hand back.
        view.markedTextStyle = [.foregroundColor: UIColor.red]
        XCTAssertEqual(view.markedTextStyle?[.foregroundColor] as? UIColor, .red)
        view.markedTextStyle = nil
        XCTAssertNil(view.markedTextStyle)
    }
}
#endif

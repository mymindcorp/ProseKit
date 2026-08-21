#if canImport(UIKit) && PROSEKIT_FUZZ
import XCTest
import UIKit
import DocumentModel
import SchemaKit
@testable import EditorUIKit

/// A fuzzer for the `UITextInput` surface — the one the system drives, and the
/// one whose answers UIKit trusts without checking. Same corpus and same
/// compilation switch as `GeometryFuzzTests`; see that file for how to run it.
@MainActor
final class TextInputFuzzTests: XCTestCase {
    private func pos(_ v: EditorTextView, _ offset: Int) -> UITextPosition {
        v.position(from: v.beginningOfDocument, offset: offset)!
    }

    // MARK: - Reading text out

    func testReadingTextInPiecesMatchesReadingItWhole() throws {
        // `text(in:)` is how the system reads the document — for autocorrect,
        // for dictation, for the accessibility tree. Splitting a range must not
        // change what comes back, or every one of those reads a different
        // document depending on how UIKit happened to chunk its question.
        var checked = 0
        try FuzzViews.forEachView { name, v in
            let size = v.editor.doc.content.size
            let positions = FuzzViews.caretPositions(v)
            guard positions.count >= 3 else { return }
            for _ in 0 ..< 30 {
                let a = positions.randomElement()!, b = positions.randomElement()!
                let (from, to) = (min(a, b), max(a, b))
                guard let whole = v.text(in: DocTextRange(from, to)) else { continue }
                for split in positions where split > from && split < to {
                    guard let head = v.text(in: DocTextRange(from, split)),
                          let tail = v.text(in: DocTextRange(split, to)) else {
                        XCTFail("no text for a sub-range of \(from)..\(to) in \(name)")
                        continue
                    }
                    XCTAssertEqual(head + tail, whole,
                                   "reading \(from)..\(to) split at \(split) differs in \(name)")
                    checked += 1
                }
            }
            XCTAssertEqual(v.text(in: DocTextRange(size, size)), "", "a collapsed range isn't empty in \(name)")
        }
        XCTAssertGreaterThan(checked, 500, "only \(checked) splits compared")
    }

    // MARK: - Position arithmetic

    func testPositionArithmeticIsConsistentWithItself() throws {
        try FuzzViews.forEachView { name, v in
            let size = v.editor.doc.content.size
            XCTAssertEqual(v.offset(from: v.beginningOfDocument, to: v.endOfDocument), size,
                           "the document doesn't measure its own length in \(name)")
            for a in 0 ... size {
                let pa = pos(v, a)
                XCTAssertEqual(v.offset(from: v.beginningOfDocument, to: pa), a,
                               "a position built at \(a) doesn't measure back in \(name)")
                // Out of range is nil, never a clamped answer that lies about
                // where it is.
                XCTAssertNil(v.position(from: pa, offset: size - a + 1),
                             "walking past the end from \(a) gave a position in \(name)")
                XCTAssertNil(v.position(from: pa, offset: -a - 1),
                             "walking before the start from \(a) gave a position in \(name)")
                for b in stride(from: 0, through: size, by: 7) {
                    let pb = pos(v, b)
                    let expected: ComparisonResult = a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
                    XCTAssertEqual(v.compare(pa, to: pb), expected,
                                   "comparing \(a) with \(b) disagrees with their offsets in \(name)")
                    XCTAssertEqual(v.offset(from: pa, to: pb), b - a,
                                   "the distance from \(a) to \(b) is wrong in \(name)")
                }
            }
        }
    }

    // MARK: - The tokenizer

    func testWordBoundariesAgreeWithTheRangesTheyBound() throws {
        // The tokenizer decides what a double-tap selects and where a word
        // delete stops. Its two halves have to describe the same words: a
        // boundary it walks to is a boundary it recognises, and a range it
        // encloses a position with actually contains it.
        let granularities: [UITextGranularity] = [.character, .word, .paragraph, .line]
        var checked = 0
        try FuzzViews.forEachView { name, v in
            let tokenizer = v.tokenizer
            for p in FuzzViews.caretPositions(v) {
                let here = pos(v, p)
                for g in granularities {
                    for direction in [UITextStorageDirection.forward, .backward] {
                        let d = direction.rawValue == UITextStorageDirection.forward.rawValue
                            ? UITextDirection.storage(.forward) : UITextDirection.storage(.backward)
                        let ctx = "\(g) \(direction) from \(p) in \(name)"

                        if let range = tokenizer.rangeEnclosingPosition(here, with: g, inDirection: d) as? DocTextRange {
                            XCTAssertLessThanOrEqual(range.from, range.to, "an inverted enclosing range — \(ctx)")
                            XCTAssertTrue(range.from <= p && p <= range.to,
                                          "the enclosing range \(range.from)..\(range.to) doesn't contain \(p) — \(ctx)")
                            checked += 1
                        }

                        guard let moved = tokenizer.position(from: here, toBoundary: g, inDirection: d) as? DocTextPosition
                        else { continue }
                        XCTAssertTrue(moved.offset >= 0 && moved.offset <= v.editor.doc.content.size,
                                      "a boundary walk left the document, to \(moved.offset) — \(ctx)")
                        if direction == .forward {
                            XCTAssertGreaterThanOrEqual(moved.offset, p, "a forward boundary walk went backwards — \(ctx)")
                        } else {
                            XCTAssertLessThanOrEqual(moved.offset, p, "a backward boundary walk went forwards — \(ctx)")
                        }
                        // Deliberately not "what it walked to, it calls a
                        // boundary": that isn't true of `UITextInputStringTokenizer`
                        // either — at the start of the document, facing
                        // backward, there is no boundary to be at — so asserting
                        // it would only be asserting Apple's semantics wrong.
                        //
                        // What must hold is progress. A walk that answers with
                        // the position it was given is a word-wise arrow key
                        // that never moves, and a caller looping on it hangs.
                        if moved.offset != p {
                            checked += 1
                        } else {
                            XCTAssertNotEqual(moved.offset, p, "a boundary walk stood still — \(ctx)")
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 2000, "only \(checked) boundary questions asked")
    }

    func testWalkingWordByWordCrossesTheDocumentAndStops() throws {
        // ⌥→ held down. Each step has to advance, and the walk has to end.
        try FuzzViews.forEachView { name, v in
            let size = v.editor.doc.content.size
            guard size > 0 else { return }
            let forward = UITextDirection.storage(.forward)
            var at = 0
            var steps = 0
            while let next = v.tokenizer.position(from: pos(v, at), toBoundary: .word, inDirection: forward) as? DocTextPosition {
                XCTAssertGreaterThan(next.offset, at, "a word walk stalled at \(at) in \(name)")
                guard next.offset > at else { break }
                at = next.offset
                steps += 1
                if steps > size + 2 {
                    XCTFail("walking words never reached the end of \(name) after \(steps) steps")
                    break
                }
            }
        }
    }
}
#endif

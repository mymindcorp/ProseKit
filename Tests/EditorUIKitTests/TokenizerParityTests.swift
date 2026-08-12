#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import SchemaKit
import EditorStateKit
import DocumentTransform
@testable import EditorUIKit

/// The document-backed tokenizer against the one it replaces.
///
/// `UITextInputStringTokenizer` answers word and sentence questions by asking
/// us for text and building a CoreNLP/ICU tokenizer from scratch on every
/// call — 238 samples of one scroll, and it is on the path UIKit runs for every
/// `selectionDidChange`. Replacing it is only safe if it answers the same
/// questions the same way: word-wise arrow movement, double-tap selection and
/// autocorrect all read these four methods.
///
/// So this is a parity suite, not a specification. The system tokenizer is the
/// oracle; every position of every corpus document is compared for all four
/// protocol methods, across granularities and both directions. Where the two
/// genuinely cannot agree, the disagreement is named explicitly below rather
/// than papered over.
@MainActor
final class TokenizerParityTests: XCTestCase {
    private func view(_ paragraphs: [String]) -> EditorTextView {
        let editor = try! Editor(extensions: fullKit())
        let s = editor.schema
        let nodes = paragraphs.map { text in
            text.isEmpty
                ? try! s.node("paragraph", [:])
                : try! s.node("paragraph", [:], content: Fragment.from([s.text(text)]))
        }
        editor.setContent(try! s.node("doc", [:], content: Fragment.from(nodes)))
        let v = EditorTextView(editor: editor)
        v.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        v.layoutIfNeeded()
        return v
    }

    /// Documents chosen for the seams: punctuation, contractions, digits,
    /// double spaces, leading/trailing space, an empty paragraph, non-ASCII,
    /// and a hyphenated word.
    private let corpus: [[String]] = [
        ["hello world"],
        ["one two three four"],
        ["Hello, world! How are you?"],
        ["it's a well-known fact"],
        ["numbers 42 and 3.14 here"],
        ["double  space and trailing "],
        [" leading space"],
        ["first paragraph", "second paragraph"],
        ["before", "", "after"],
        ["café naïve résumé"],
        ["a"],
        [""],
    ]

    private let granularities: [UITextGranularity] = [
        .character, .word, .sentence, .paragraph, .line, .document,
    ]
    private let directions: [UITextDirection] = [
        UITextDirection(rawValue: UITextStorageDirection.forward.rawValue),
        UITextDirection(rawValue: UITextStorageDirection.backward.rawValue),
        UITextDirection(rawValue: UITextLayoutDirection.right.rawValue),
        UITextDirection(rawValue: UITextLayoutDirection.left.rawValue),
    ]

    private func offset(_ p: UITextPosition?) -> Int? { (p as? DocTextPosition)?.offset }
    private func bounds(_ r: UITextRange?) -> (Int, Int)? {
        guard let r = r as? DocTextRange else { return nil }
        return (r.from, r.to)
    }

    /// Compare every answer, and report the first divergence with enough
    /// context to reproduce it by hand.
    private func assertParity(_ doc: [String], file: StaticString = #filePath, line: UInt = #line) {
        let v = view(doc)
        let system = UITextInputStringTokenizer(textInput: v)
        let ours = DocumentTokenizer(textInput: v)
        let size = v.editor.doc.content.size
        var compared = 0
        for pos in 0 ... size {
            let p = DocTextPosition(pos)
            for g in granularities {
                for d in directions {
                    let label = "doc \(doc) at \(pos), \(g.rawValue)/\(d.rawValue)"
                    XCTAssertEqual(offset(ours.position(from: p, toBoundary: g, inDirection: d)),
                                   offset(system.position(from: p, toBoundary: g, inDirection: d)),
                                   "position(toBoundary) — \(label)", file: file, line: line)
                    XCTAssertEqual(bounds(ours.rangeEnclosingPosition(p, with: g, inDirection: d)).map { [$0.0, $0.1] },
                                   bounds(system.rangeEnclosingPosition(p, with: g, inDirection: d)).map { [$0.0, $0.1] },
                                   "rangeEnclosingPosition — \(label)", file: file, line: line)
                    XCTAssertEqual(ours.isPosition(p, atBoundary: g, inDirection: d),
                                   system.isPosition(p, atBoundary: g, inDirection: d),
                                   "isPosition(atBoundary) — \(label)", file: file, line: line)
                    XCTAssertEqual(ours.isPosition(p, withinTextUnit: g, inDirection: d),
                                   system.isPosition(p, withinTextUnit: g, inDirection: d),
                                   "isPosition(withinTextUnit) — \(label)", file: file, line: line)
                    compared += 4
                }
            }
        }
        XCTAssertGreaterThan(compared, 0)
    }

    func testParityAcrossTheCorpus() {
        for doc in corpus { assertParity(doc) }
    }

    /// The one place parity is the wrong goal.
    ///
    /// `projectedText` returns one *character* per document position, so a
    /// non-BMP character is one position but two UTF-16 units. The system
    /// tokenizer indexes the string it is handed in UTF-16 and maps offsets
    /// back as though a unit were a position, so every word after an emoji
    /// comes back shifted by one per non-BMP character before it. Ours works
    /// in document positions and does not drift. Matching the system here
    /// would mean reproducing the bug.
    func testWordRangesAreRightAroundNonBMPCharacters() {
        let v = view(["emoji 😀 between words"])
        let ours = DocumentTokenizer(textInput: v)
        // e1 m2 o3 j4 i5 ␣6 😀7 ␣8 b9 …n15 ␣16 w17 …s21
        let forward = UITextDirection(rawValue: UITextStorageDirection.forward.rawValue)
        func word(at pos: Int) -> [Int]? {
            (ours.rangeEnclosingPosition(DocTextPosition(pos), with: .word, inDirection: forward)
                as? DocTextRange).map { [$0.from, $0.to] }
        }
        XCTAssertEqual(word(at: 1), [1, 6], "\"emoji\" before the emoji")
        XCTAssertEqual(word(at: 9), [9, 16], "\"between\" — the word right after the emoji")
        XCTAssertEqual(word(at: 12), [9, 16], "still inside \"between\"")
        XCTAssertEqual(word(at: 17), [17, 22], "\"words\" at the end")
        // And the text really is one character per position, which is what
        // makes the document-position answer the correct one.
        XCTAssertEqual(v.projectedText(from: 9, to: 16), "between")
        XCTAssertEqual(v.projectedText(from: 17, to: 22), "words")
    }

    func testItIsCheaperThanRebuildingATokenizerEachCall() {
        // The reason for the whole class. The system tokenizer builds a
        // CoreNLP/ICU word tokenizer per call; this one builds it once. UIKit
        // asks these questions on every scroll tick, so the per-call cost is a
        // per-frame cost.
        let body = Array(repeating: "lorem ipsum dolor sit amet consectetur", count: 40).joined(separator: " ")
        let v = view([body, body, body])
        let system = UITextInputStringTokenizer(textInput: v)
        let ours = DocumentTokenizer(textInput: v)
        let forward = UITextDirection(rawValue: UITextStorageDirection.forward.rawValue)
        let probes = (0 ..< 200).map { DocTextPosition(1 + $0 * 3) }

        func best(_ t: any UITextInputTokenizer) -> Double {
            var b = Double.infinity
            for _ in 0 ..< 5 {
                let start = CFAbsoluteTimeGetCurrent()
                for p in probes { _ = t.position(from: p, toBoundary: .word, inDirection: forward) }
                b = min(b, (CFAbsoluteTimeGetCurrent() - start) * 1000)
            }
            return b
        }
        // Ours first would flatter it (the system tokenizer warms shared ICU
        // state), so measure the system one first.
        let systemMs = best(system), oursMs = best(ours)
        print(unsafe "TOKENIZER system=\(String(format: "%.2f", systemMs))ms "
            + "ours=\(String(format: "%.2f", oursMs))ms "
            + "ratio=\(String(format: "%.1f", systemMs / max(oursMs, 0.0001)))x")
        XCTAssertLessThan(oursMs, systemMs,
                          "the point of this tokenizer is that it is cheaper")
    }

    func testTheTokenizerIsTheOneWeInstalled() {
        let v = view(["hello world"])
        XCTAssertTrue(v.tokenizer is DocumentTokenizer,
                      "the view must actually use the document-backed tokenizer")
    }
}
#endif

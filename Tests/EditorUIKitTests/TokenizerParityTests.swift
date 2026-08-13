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
        ["שלום עולם shalom"],
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

    /// The start or end of a textblock.
    private func blockEdge(_ v: EditorTextView, _ pos: Int) -> Bool {
        guard pos >= 0, pos <= v.editor.doc.content.size else { return false }
        let r = v.editor.doc.resolve(pos)
        return r.parent.isTextblock && (r.parentOffset == 0 || r.parentOffset == r.parent.content.size)
    }
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
                    // The ends of a paragraph are the named disagreement — see
                    // `testABlockEdgeIsAWordBoundary`.
                    if !(g == .word && blockEdge(v, pos)) {
                        XCTAssertEqual(ours.isPosition(p, atBoundary: g, inDirection: d),
                                       system.isPosition(p, atBoundary: g, inDirection: d),
                                       "isPosition(atBoundary) — \(label)", file: file, line: line)
                    }
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

    /// The first place parity is the wrong goal.
    ///
    /// After a tap, UIKit asks `isPosition(_:atBoundary:.word:)` — is the caret
    /// somewhere sensible? — and, told no, hunts for the nearest word boundary
    /// with `position(from:toBoundary:)`. Past the end of a paragraph the
    /// nearest word is in the NEXT paragraph, so being told no at the end of a
    /// paragraph moves the caret out of it: tapping the end of a paragraph put
    /// the caret at the start of the block below, every time, and the end of a
    /// paragraph could not be reached at all.
    ///
    /// `UITextInputStringTokenizer` is answering about a string, where a block
    /// break is a newline like any other and "and code." runs on into "Lists".
    /// We are answering about a document, where it does not: a word never spans
    /// a paragraph break, so both ends of one are word boundaries. That is the
    /// disagreement, and it is the whole of it — `position(from:toBoundary:)`
    /// and `rangeEnclosingPosition` still match the system everywhere.
    func testABlockEdgeIsAWordBoundary() {
        let v = view(["hello world", "second paragraph"])
        let ours = DocumentTokenizer(textInput: v)
        let system = UITextInputStringTokenizer(textInput: v)
        // "hello world" is 1..12, "second paragraph" is 14..30.
        XCTAssertEqual(v.projectedText(from: 1, to: 12), "hello world")
        XCTAssertEqual(v.projectedText(from: 14, to: 30), "second paragraph")

        for pos in [1, 12, 14, 30] {
            let p = DocTextPosition(pos)
            for d in directions {
                XCTAssertTrue(ours.isPosition(p, atBoundary: .word, inDirection: d),
                              "the block edge at \(pos) is a word boundary, direction \(d.rawValue)")
            }
        }
        // The end of a paragraph is exactly where the system says otherwise —
        // if this ever starts agreeing, the exception above can go.
        XCTAssertFalse(system.isPosition(DocTextPosition(12), atBoundary: .word,
                                         inDirection: UITextDirection(rawValue: UITextStorageDirection.backward.rawValue)),
                       "the system tokenizer no longer disagrees")

        // Only `atBoundary` moves: a block edge is still not inside a word, and
        // word-wise movement still crosses paragraphs (⌥→ must not get stuck).
        let forward = UITextDirection(rawValue: UITextStorageDirection.forward.rawValue)
        XCTAssertFalse(ours.isPosition(DocTextPosition(12), withinTextUnit: .word, inDirection: forward))
        XCTAssertEqual(offset(ours.position(from: DocTextPosition(12), toBoundary: .word, inDirection: forward)),
                       offset(system.position(from: DocTextPosition(12), toBoundary: .word, inDirection: forward)),
                       "word-wise movement out of a paragraph still matches the system")
    }

    // MARK: Past the window

    /// A document several windows long, with the paragraph lengths chosen so
    /// words straddle the edges rather than landing neatly on them.
    private func longView() -> EditorTextView {
        let words = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel"]
        let paragraphs = (0 ..< 24).map { i -> String in
            let n = 17 + (i % 5) * 3          // uneven, so edges fall mid-word
            return (0 ..< n).map { words[($0 + i) % words.count] }.joined(separator: " ")
        }
        return view(paragraphs)
    }

    /// Positions worth asking about: a spread across the document, plus dense
    /// bands where the window is rebuilt.
    private func probePositions(_ size: Int) -> [Int] {
        var positions = Set(stride(from: 0, through: size, by: 13))
        // `margin` is 512 and `guardBand` 64, so rebuilds cluster around these.
        for edge in stride(from: 0, through: size, by: 448) {
            for p in max(0, edge - 70) ... min(size, edge + 70) { positions.insert(p) }
        }
        return positions.sorted()
    }

    func testParityOnADocumentLongerThanTheWindow() {
        // Every corpus document above fits inside one window, so none of them
        // exercise the part of this class that makes it fast: the window is
        // always the whole document, and the cache is always valid. This walks
        // a document several windows long, over the positions where the window
        // is rebuilt and a word can be cut by its edge.
        let v = longView()
        let system = UITextInputStringTokenizer(textInput: v)
        let ours = DocumentTokenizer(textInput: v)
        let size = v.editor.doc.content.size
        XCTAssertGreaterThan(size, 512 * 4, "the document must span several windows")

        for pos in probePositions(size) {
            let p = DocTextPosition(pos)
            for d in directions {
                XCTAssertEqual(offset(ours.position(from: p, toBoundary: .word, inDirection: d)),
                               offset(system.position(from: p, toBoundary: .word, inDirection: d)),
                               "position(toBoundary) at \(pos), direction \(d.rawValue)")
                XCTAssertEqual(bounds(ours.rangeEnclosingPosition(p, with: .word, inDirection: d)).map { [$0.0, $0.1] },
                               bounds(system.rangeEnclosingPosition(p, with: .word, inDirection: d)).map { [$0.0, $0.1] },
                               "rangeEnclosingPosition at \(pos), direction \(d.rawValue)")
                if !blockEdge(v, pos) {   // see `testABlockEdgeIsAWordBoundary`
                    XCTAssertEqual(ours.isPosition(p, atBoundary: .word, inDirection: d),
                                   system.isPosition(p, atBoundary: .word, inDirection: d),
                                   "isPosition(atBoundary) at \(pos), direction \(d.rawValue)")
                }
                XCTAssertEqual(ours.isPosition(p, withinTextUnit: .word, inDirection: d),
                               system.isPosition(p, withinTextUnit: .word, inDirection: d),
                               "isPosition(withinTextUnit) at \(pos), direction \(d.rawValue)")
            }
        }
    }

    /// The second place parity is the wrong goal — and the one I expected to
    /// go the other way.
    ///
    /// The worry was our own cache: it is reused whenever the position sits at
    /// least `guardBand` (64) inside the window, which only protects words
    /// shorter than that, so a 150-character token could in principle be cut
    /// by a window edge while the position asking about it still looked safely
    /// inside. It is not cut — the assertions below sweep every position of
    /// such a token, in three orders, and get the whole of it every time.
    ///
    /// What the sweep found instead was in the tokenizer being replaced.
    /// `UITextInputStringTokenizer` clamps a word to ±100 characters around
    /// the position asked about, so for a longer token it returns a *sliding*
    /// fragment rather than a word: [321, 421] asked at 321, [321, 431] at
    /// 331, [322, 471] at 422. Ours returns the same true range wherever it is
    /// asked from. That is a behaviour change — double-tapping a long URL now
    /// selects all of it rather than a hundred characters of it — so it is
    /// asserted here rather than left as a surprise.
    func testLongTokensComeBackWholeAndStable() {
        let token = String(repeating: "x", count: 150)
        // The long run *inside* a URL, not the URL itself: ICU splits a URL at
        // its punctuation, so "https" is a word and the whole thing is not.
        let run = String(repeating: "a", count: 120)
        let url = "https://example.com/" + run + "/end"
        let filler = Array(repeating: "alpha bravo charlie delta", count: 12).joined(separator: " ")
        let v = view([filler, "before \(token) after", filler, "link \(url) tail", filler])
        let ours = DocumentTokenizer(textInput: v)
        let size = v.editor.doc.content.size
        let all = Array(v.projectedText(from: 0, to: size))
        let forward = UITextDirection(rawValue: UITextStorageDirection.forward.rawValue)

        for expected in [token, run] {
            let chars = Array(expected)
            guard let start = (0 ... (all.count - chars.count)).first(where: {
                Array(all[$0 ..< ($0 + chars.count)]) == chars
            }) else { return XCTFail("the long token is not in the document") }
            let want = [start, start + chars.count]
            XCTAssertGreaterThan(chars.count, 100, "shorter than this and the clamp would not show")

            func rangeAt(_ pos: Int) -> [Int]? {
                bounds(ours.rangeEnclosingPosition(DocTextPosition(pos), with: .word, inDirection: forward))
                    .map { [$0.0, $0.1] }
            }
            let inside = Array(start ..< (start + chars.count))
            // Ascending, descending, and jumping about: the cache is warmed
            // differently by each, and a window edge cutting the token would
            // show up as an answer that depends on the route taken.
            for pos in inside {
                XCTAssertEqual(rangeAt(pos), want, "ascending: token cut at \(pos)")
            }
            for pos in inside.reversed() {
                XCTAssertEqual(rangeAt(pos), want, "descending: token cut at \(pos)")
            }
            for pos in inside.enumerated()
                .sorted(by: { ($0.offset * 7919) % inside.count < ($1.offset * 7919) % inside.count })
                .map({ $0.element }) {
                XCTAssertEqual(rangeAt(pos), want, "jumbled: token cut at \(pos)")
            }
            XCTAssertEqual(v.projectedText(from: want[0], to: want[1]), expected,
                           "the range does not project back to the whole token")
        }
    }

    func testAnswersDoNotDependOnTheOrderTheyAreAsked() {
        // The cache holds one window, so the answer to a question could depend
        // on which question came before it — walking forwards keeps it warm,
        // jumping about rebuilds it constantly. Those must agree, or scrolling
        // and tapping would disagree about where a word is.
        let v = longView()
        let ours = DocumentTokenizer(textInput: v)
        let size = v.editor.doc.content.size
        let forward = UITextDirection(rawValue: UITextStorageDirection.forward.rawValue)
        let positions = probePositions(size)

        func answer(_ pos: Int) -> [Int]? {
            bounds(ours.rangeEnclosingPosition(DocTextPosition(pos), with: .word, inDirection: forward))
                .map { [$0.0, $0.1] }
        }
        let ascending = positions.map { ($0, answer($0)) }
        // A fixed shuffle (no RNG — the order must be reproducible on failure).
        let jumbled = positions.enumerated()
            .sorted { ($0.offset * 7919) % positions.count < ($1.offset * 7919) % positions.count }
            .map { $0.element }
        var outOfOrder: [Int: [Int]?] = [:]
        for pos in jumbled { outOfOrder[pos] = answer(pos) }
        // ...and once more descending, the other way a cache can go stale.
        var descending: [Int: [Int]?] = [:]
        for pos in positions.reversed() { descending[pos] = answer(pos) }

        for (pos, expected) in ascending {
            XCTAssertEqual(outOfOrder[pos] ?? nil, expected, "jumbled order disagreed at \(pos)")
            XCTAssertEqual(descending[pos] ?? nil, expected, "descending order disagreed at \(pos)")
        }
    }

    func testEditingInvalidatesTheCachedWords() {
        // The window is cached against the document revision. If that key ever
        // stops being enough, this is what breaks: a word range from before
        // the edit, handed to UIKit after it.
        let v = view(["hello world"])
        let ours = DocumentTokenizer(textInput: v)
        let forward = UITextDirection(rawValue: UITextStorageDirection.forward.rawValue)
        func word(at pos: Int) -> [Int]? {
            bounds(ours.rangeEnclosingPosition(DocTextPosition(pos), with: .word, inDirection: forward))
                .map { [$0.0, $0.1] }
        }
        XCTAssertEqual(word(at: 1), [1, 6], "\"hello\"")

        // Insert at the very start: every following word shifts.
        v.selectedTextRange = DocTextRange(1, 1)
        v.insertText("XY ")
        v.layoutIfNeeded()
        XCTAssertEqual(v.projectedText(from: 1, to: 4), "XY ", "the edit landed where expected")
        XCTAssertEqual(word(at: 1), [1, 3], "\"XY\" after the insert")
        XCTAssertEqual(word(at: 4), [4, 9], "\"hello\", now shifted")
    }

    func testALeafNodeIsNotAWord() {
        // Leaves project as U+FFFC (object replacement). It should not read as
        // a word, and the words either side of it should keep their positions.
        let editor = try! Editor(extensions: fullKit())
        let s = editor.schema
        guard let rule = s.nodes["horizontalRule"] else { return }
        editor.setContent(try! s.node("doc", [:], content: Fragment.from([
            try! s.node("paragraph", [:], content: Fragment.from([s.text("before")])),
            rule.createAndFill()!,
            try! s.node("paragraph", [:], content: Fragment.from([s.text("after")])),
        ])))
        let v = EditorTextView(editor: editor)
        v.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        v.layoutIfNeeded()
        let ours = DocumentTokenizer(textInput: v)
        let system = UITextInputStringTokenizer(textInput: v)
        for pos in 0 ... editor.doc.content.size {
            let p = DocTextPosition(pos)
            for d in directions {
                XCTAssertEqual(bounds(ours.rangeEnclosingPosition(p, with: .word, inDirection: d)).map { [$0.0, $0.1] },
                               bounds(system.rangeEnclosingPosition(p, with: .word, inDirection: d)).map { [$0.0, $0.1] },
                               "a leaf changed word ranges at \(pos)")
            }
        }
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

    /// One emoji is the easy case: a single scalar, two UTF-16 units. These are
    /// the graphemes that are many scalars and many units but still one
    /// document position — where `Window`'s character↔UTF-16 conversion has to
    /// carry its weight.
    ///
    /// Asserted through the text a range projects back to, rather than against
    /// hand-counted positions: it is the property that matters (the range
    /// UIKit is handed covers the word a reader sees) and it does not quietly
    /// rot when the corpus is edited.
    func testWordRangesAroundMultiScalarGraphemes() {
        let cases: [(String, String)] = [
            ("family 👨‍👩‍👧‍👦 here", "ZWJ sequence — many scalars, one grapheme"),
            ("flag 🇯🇵 here", "regional indicators"),
            ("wave 👋🏽 here", "skin tone modifier"),
            ("accent cafe\u{0301} here", "combining mark"),
            ("multi 😀😀😀 here", "several in a row"),
            ("tight👋🏽word here", "no spaces either side"),
        ]
        let forward = UITextDirection(rawValue: UITextStorageDirection.forward.rawValue)
        for (text, label) in cases {
            let v = view([text])
            let ours = DocumentTokenizer(textInput: v)
            // "here" is the last word. The paragraph's closing token occupies
            // the final position, so the text ends at `size - 1`.
            let size = v.editor.doc.content.size
            let textEnd = size - 1
            let hereStart = textEnd - 4      // one character per position
            XCTAssertEqual(v.projectedText(from: hereStart, to: textEnd), "here",
                           "\(label): the document is not shaped as expected")
            guard let r = ours.rangeEnclosingPosition(DocTextPosition(hereStart), with: .word,
                                                      inDirection: forward) as? DocTextRange else {
                return XCTFail("\(label): no word at the trailing word")
            }
            XCTAssertEqual(v.projectedText(from: r.from, to: r.to), "here",
                           "\(label): word range drifted past the grapheme")
            // The leading word too, on the other side of it.
            guard let first = ours.rangeEnclosingPosition(DocTextPosition(1), with: .word,
                                                          inDirection: forward) as? DocTextRange else {
                return XCTFail("\(label): no word at the start")
            }
            XCTAssertEqual(v.projectedText(from: first.from, to: first.to),
                           String(text.prefix(while: { $0.isLetter })),
                           "\(label): leading word range is wrong")
        }
    }

    func testEmojiPastTheWindowEdge() {
        // The window starts at a non-zero document position here, so a
        // character index inside it and a document position are no longer the
        // same number *and* the UTF-16 offsets differ from both. Nothing above
        // reaches this combination.
        let filler = Array(repeating: "alpha bravo charlie delta echo", count: 30).joined(separator: " ")
        let v = view([filler, "tail 😀 marker words", filler])
        let ours = DocumentTokenizer(textInput: v)
        let forward = UITextDirection(rawValue: UITextStorageDirection.forward.rawValue)
        // Locate "marker" by projecting the whole document once.
        let size = v.editor.doc.content.size
        let all = Array(v.projectedText(from: 0, to: size))
        guard let markerStart = (0 ..< all.count - 6).first(where: { String(all[$0 ..< ($0 + 6)]) == "marker" }) else {
            return XCTFail("test document does not contain the marker")
        }
        XCTAssertGreaterThan(markerStart, 512, "the marker must sit past the first window")

        guard let r = ours.rangeEnclosingPosition(DocTextPosition(markerStart), with: .word,
                                                  inDirection: forward) as? DocTextRange else {
            return XCTFail("no word at the marker")
        }
        XCTAssertEqual(v.projectedText(from: r.from, to: r.to), "marker",
                       "word range drifted for an emoji past the window edge")
        // And the word on the far side of the emoji. Found the same way rather
        // than by counting back from the marker, so the emoji's width in
        // positions is not baked into the test.
        guard let tailStart = (0 ..< markerStart).last(where: { String(all[$0 ..< ($0 + 4)]) == "tail" }) else {
            return XCTFail("test document does not contain the tail word")
        }
        guard let tail = ours.rangeEnclosingPosition(DocTextPosition(tailStart), with: .word,
                                                     inDirection: forward) as? DocTextRange else {
            return XCTFail("no word before the emoji")
        }
        XCTAssertEqual(v.projectedText(from: tail.from, to: tail.to), "tail")
        // The emoji really does sit between them, one position wide.
        XCTAssertEqual(v.projectedText(from: tailStart + 5, to: tailStart + 6), "😀")
    }

    func testTheTokenizerIsTheOneWeInstalled() {
        let v = view(["hello world"])
        XCTAssertTrue(v.tokenizer is DocumentTokenizer,
                      "the view must actually use the document-backed tokenizer")
    }
}
#endif

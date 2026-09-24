#if canImport(UIKit)
import XCTest
import UIKit
import CoreText
import DocumentModel
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

/// A long block re-broken after an edit resumes from its last breaks instead
/// of breaking all of it again (`LineBreaking.resume`). Nothing about CoreText
/// promises that is the same as a full re-break — its choice for one line
/// depends on text well past it — so every test here is an oracle: lay the
/// edited document out through a cache that has seen the old one, lay it out
/// again with no cache at all, and demand identical lines.
@MainActor
final class IncrementalLineBreakTests: XCTestCase {
    private let schema = try! Editor(extensions: fullKit()).schema

    private struct RNG: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    /// What a paragraph is made of here: runs of text with marks, hard
    /// breaks, and inline images (an atom, whose run delegate the comparison
    /// must treat as changed).
    private enum Piece: Equatable {
        case text(String, [String])
        case hardBreak
        case image(width: Int)
    }

    /// A real picture, so an inline image is an atom with a run delegate — the
    /// default provider returns nil, and the image is then drawn as a plain
    /// character that tests nothing about atoms.
    private static let picture = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { _ in }
    private func layout(_ doc: Node, _ width: CGFloat, _ cache: TextBlockLayoutCache? = nil) -> DocumentLayout {
        DocumentLayout(doc: doc, width: width, theme: DocumentTheme(), imageProvider: { _ in Self.picture },
                       blockCache: cache)
    }

    /// Words that stress the breaker differently: plain ones, a token far
    /// wider than any line (emergency breaks), a URL, CJK with no spaces
    /// (breaks between any two ideographs), combining marks, emoji sequences,
    /// no-break and soft hyphens, tabs.
    private static let vocabulary = [
        "the", "a", "of", "typesetting", "paragraph", "quadratic", "line", "break", "I", "x",
        "antidisestablishmentarianism", "don't", "e\u{301}te\u{301}", "naïve", "über", "2026-09-23",
        "https://example.com/a/very/long/path/that/never/offers/a/break/at/all?q=1&r=2",
        String(repeating: "W", count: 140),
        "中文字符没有空格的长句子中文字符没有空格的长句子日本語の文章も区切りがない",
        "👩‍👩‍👧‍👦", "🇩🇪", "👍🏽", "no\u{00A0}break", "soft\u{00AD}hyphen", "tab\there", "—", "“quoted”",
    ]
    private static let marks = ["bold", "italic", "code", "link", "highlight"]

    private func words(_ n: Int, _ rng: inout RNG) -> String {
        (0 ..< n).map { _ in Self.vocabulary.randomElement(using: &rng)! }.joined(separator: " ")
    }

    private func mark(_ name: String) -> Mark {
        switch name {
        case "link": schema.mark("link", ["href": .string("https://example.com")])
        case "highlight": schema.mark("highlight", ["color": .string("yellow")])
        default: schema.mark(name)
        }
    }

    private func paragraph(_ pieces: [Piece]) -> Node {
        let inline: [Node] = pieces.compactMap {
            switch $0 {
            case let .text(t, m): t.isEmpty ? nil : schema.text(t, m.map(mark))
            case .hardBreak: try! schema.node("hardBreak", [:])
            case let .image(w): try! schema.node("image", ["src": .string("data:image/png;base64,AAAA"), "width": .int(w)])
            }
        }
        return try! schema.node("paragraph", [:], content: Fragment.from(inline))
    }

    private func document(_ paragraphs: [[Piece]]) -> Node {
        try! schema.node("doc", [:], content: Fragment.from(paragraphs.map(paragraph)))
    }

    private func randomPieces(words count: Int, _ rng: inout RNG) -> [Piece] {
        var pieces: [Piece] = []
        var left = count
        while left > 0 {
            let n = min(left, Int.random(in: 5 ... 80, using: &rng))
            left -= n
            let marks = Int.random(in: 0 ..< 4, using: &rng) == 0 ? [Self.marks.randomElement(using: &rng)!] : []
            pieces.append(.text(words(n, &rng) + " ", marks))
            switch Int.random(in: 0 ..< 30, using: &rng) {
            case 0: pieces.append(.hardBreak)
            case 1, 2: pieces.append(.image(width: Int.random(in: 12 ... 60, using: &rng)))
            default: break
            }
        }
        return pieces
    }

    /// One random edit: typing, deleting, pasting, changing only a run's
    /// marks — the case where the text is the same and the breaks still move —
    /// or resizing an inline image, where only an atom's metrics change.
    private func edit(_ pieces: inout [Piece], _ rng: inout RNG) {
        let images = pieces.indices.filter { if case .image = pieces[$0] { true } else { false } }
        if let k = images.randomElement(using: &rng), Int.random(in: 0 ..< 6, using: &rng) == 0 {
            pieces[k] = .image(width: Int.random(in: 12 ... 60, using: &rng))
            return
        }
        let textIndices = pieces.indices.filter { if case .text = pieces[$0] { true } else { false } }
        guard let i = textIndices.randomElement(using: &rng), case let .text(t, m) = pieces[i] else { return }
        let at = t.index(t.startIndex, offsetBy: Int.random(in: 0 ... t.count, using: &rng))
        switch Int.random(in: 0 ..< 8, using: &rng) {
        case 0, 1: // type a character
            let c = ["x", " ", "é", "W", "中", ".", "\u{00AD}"].randomElement(using: &rng)!
            pieces[i] = .text(String(t[..<at]) + c + String(t[at...]), m)
        case 2: // type a word
            pieces[i] = .text(String(t[..<at]) + words(1, &rng) + " " + String(t[at...]), m)
        case 3, 4: // delete a few characters
            let end = t.index(at, offsetBy: Int.random(in: 1 ... 12, using: &rng), limitedBy: t.endIndex) ?? t.endIndex
            pieces[i] = .text(String(t[..<at]) + String(t[end...]), m)
        case 5: // paste
            pieces[i] = .text(String(t[..<at]) + words(Int.random(in: 2 ... 60, using: &rng), &rng) + " "
                + String(t[at...]), m)
        case 6: // change only the marks
            pieces[i] = .text(t, m.isEmpty ? [Self.marks.randomElement(using: &rng)!] : [])
        default: // delete a whole run
            pieces.remove(at: i)
        }
    }

    /// Nil when the two layouts have the same lines in every block, else what
    /// differs first.
    private func difference(_ a: DocumentLayout, _ b: DocumentLayout) -> String? {
        guard a.blocks.count == b.blocks.count else { return "\(a.blocks.count) blocks vs \(b.blocks.count)" }
        for (i, (x, y)) in zip(a.blocks, b.blocks).enumerated() {
            for (j, (l, m)) in zip(x.lines, y.lines).enumerated() where
                l.stringRange != m.stringRange || l.baselineOrigin != m.baselineOrigin || l.height != m.height {
                return "block \(i) line \(j): \(l.stringRange) at \(l.baselineOrigin) vs \(m.stringRange) at \(m.baselineOrigin)"
            }
            if x.lines.count != y.lines.count {
                return "block \(i): \(x.lines.count) lines vs \(y.lines.count)"
            }
            if x.frame != y.frame { return "block \(i): frame \(x.frame) vs \(y.frame)" }
        }
        return nil
    }

    /// How many edits resumed, of how many were compared — and how many
    /// carried an edited paragraph across `LineBreaking.shapingChangeLength`.
    private func sweep(seeds: Range<UInt64>, widths: [CGFloat], words: Int, edits: Int,
                       file: StaticString = #filePath, line: UInt = #line)
        -> (resumed: Int, compared: Int, crossed: Int) {
        var resumed = 0, compared = 0, crossed = 0
        for seed in seeds {
            for width in widths {
                var rng = RNG(seed: seed &* 7919 &+ UInt64(width))
                // Two long paragraphs around a short one: the cache holds a
                // record of each, and must resume the edited one from
                // whichever shares the most with it.
                var paragraphs = [randomPieces(words: words, &rng), [.text("A short one.", [])],
                                  randomPieces(words: words, &rng)]
                let cache = TextBlockLayoutCache()
                var lengths = layout(document(paragraphs), width, cache).blocks.map(\.attributed.length)
                for step in 0 ..< edits {
                    edit(&paragraphs[Bool.random(using: &rng) ? 0 : 2], &rng)
                    let doc = document(paragraphs)
                    let before = cache.debugIncrementalBreaks
                    let incremental = layout(doc, width, cache)
                    resumed += cache.debugIncrementalBreaks - before
                    compared += 1
                    let now = incremental.blocks.map(\.attributed.length)
                    crossed += zip(lengths, now).filter { !LineBreaking.shapedAlike($0, $1) }.count
                    lengths = now
                    let whole = layout(doc, width)
                    if let diff = difference(incremental, whole) {
                        XCTFail("seed \(seed), width \(width), edit \(step): \(diff)", file: file, line: line)
                        return (resumed, compared, crossed)
                    }
                }
            }
        }
        return (resumed, compared, crossed)
    }

    func testResumedBreaksMatchABreakFromScratch() {
        #if PROSEKIT_FUZZ
        let resumed = sweep(seeds: 0 ..< 30, widths: [120, 180, 362, 600, 1000, 2000], words: 1200, edits: 60)
        #else
        let resumed = sweep(seeds: 0 ..< 1, widths: [180, 362, 1000], words: 600, edits: 20)
        #endif
        // The comparison only means something if the path under test ran —
        // a sweep that mostly broke whole would pass while testing little.
        XCTAssertGreaterThan(resumed.resumed * 2, resumed.compared, "\(resumed)")
    }

    /// Around the length where CoreText starts shaping text differently, with
    /// edits that carry a paragraph back and forth across it.
    func testResumedBreaksMatchAcrossTheShapingChangeLength() {
        // The vocabulary averages ~16 units a word with its space, so ~620
        // words starts a paragraph right at the threshold, and the sweep's
        // pastes and deletions carry it back and forth across.
        #if PROSEKIT_FUZZ
        let result = sweep(seeds: 0 ..< 8, widths: [180, 362, 1000], words: 620, edits: 40)
        #else
        let result = sweep(seeds: 0 ..< 2, widths: [362], words: 620, edits: 20)
        #endif
        XCTAssertGreaterThan(result.crossed, 0, "no edit crossed the threshold: \(result)")
        XCTAssertGreaterThan(result.resumed * 2, result.compared, "\(result)")
    }

    /// A string longer than `LineBreaking.shapingChangeLength` is shaped
    /// differently — here, measurably wider — while a shorter one is shaped the
    /// same at any length. Resuming depends on exactly that, so this is the
    /// test that fails if an OS release moves the threshold or adds another.
    func testCoreTextShapesTextDifferentlyPastTheShapingChangeLength() {
        let sentence = "It was the best of times, it was the worst of times, it was the age of wisdom. "
        let long = String(repeating: sentence, count: 400) as NSString
        let font = DocumentTheme().bodyFont
        func width(total: Int) -> CGFloat {
            let text = NSAttributedString(string: long.substring(to: total), attributes: [.font: font])
            let ts = CTTypesetterCreateWithAttributedString(text as CFAttributedString)
            return CGFloat(CTLineGetTypographicBounds(CTTypesetterCreateLine(ts, CFRangeMake(0, 300)), nil, nil, nil))
        }
        let edge = LineBreaking.shapingChangeLength
        let below = width(total: edge), above = width(total: edge + 1)
        XCTAssertNotEqual(below, above, "the shaping change has moved: breaks may not carry over the way LineBreaking assumes")
        for total in [400, 2000, 5000, 8192, edge - 1] {
            XCTAssertEqual(width(total: total), below, "another shaping change below the threshold, at \(total)")
        }
        for total in [edge + 2, 16384, 20000, 30000] {
            XCTAssertEqual(width(total: total), above, "another shaping change above the threshold, at \(total)")
        }
        // It is the whole string that counts — not the run the line is in, nor
        // its CoreText paragraph. A short run of another face, or a paragraph
        // separator, leaves the first run and paragraph short and the string
        // long, and the line is shaped as in a long string.
        let other = UIFont.systemFont(ofSize: font.pointSize, weight: .bold)
        for (label, second) in [("a second run", [NSAttributedString.Key.font: other]),
                                ("a second paragraph", [.font: font])] {
            let first = NSMutableAttributedString(string: long.substring(to: 5000), attributes: [.font: font])
            if label == "a second paragraph" { first.append(NSAttributedString(string: "\n", attributes: [.font: font])) }
            first.append(NSAttributedString(string: long.substring(to: 6000), attributes: second))
            let ts = CTTypesetterCreateWithAttributedString(first as CFAttributedString)
            let w = CGFloat(CTLineGetTypographicBounds(CTTypesetterCreateLine(ts, CFRangeMake(0, 300)), nil, nil, nil))
            XCTAssertEqual(w, above, "5000 units then \(label): shaped as the long string it is part of")
        }
    }

    /// Inline atoms compare by the room they reserve: an image near the start
    /// of a long paragraph must not stop an edit near its end from resuming —
    /// and resizing that image must still re-break the lines around it.
    func testAnAtomEarlyInAParagraphStillResumes() {
        var rng = RNG(seed: 9)
        var pieces: [Piece] = [.text("Start ", []), .image(width: 30), .text(words(700, &rng), [])]
        let cache = TextBlockLayoutCache()
        _ = layout(document([pieces]), 362, cache)
        guard case let .text(t, _) = pieces[2] else { return }
        pieces[2] = .text(String(t.dropLast(20)) + "x" + String(t.suffix(20)), [])
        var doc = document([pieces])
        var incremental = layout(doc, 362, cache)
        XCTAssertEqual(cache.debugIncrementalBreaks, 1, "an edit after an unchanged atom resumes")
        XCTAssertNil(difference(incremental, layout(doc, 362)))

        pieces[1] = .image(width: 200)
        doc = document([pieces])
        incremental = layout(doc, 362, cache)
        XCTAssertNil(difference(incremental, layout(doc, 362)), "a resized atom re-breaks around it")
    }

    /// A code block: every line ends at a "\n", which CoreText treats as the
    /// end of a paragraph, and edits that add and remove them.
    func testResumedBreaksMatchInACodeBlock() {
        let lines = ["let value = compute(42, factor: 7) // a comment that runs on",
                     "    return items.filter { $0.isValid && $0.count > threshold }.map(\\.name)",
                     "}", "", "\tindented with a tab", "func f() {"]
        for width: CGFloat in [180, 362] {
            var rng = RNG(seed: UInt64(width))
            var text = (0 ..< 120).map { _ in lines.randomElement(using: &rng)! }.joined(separator: "\n")
            let cache = TextBlockLayoutCache()
            func doc() -> Node {
                try! schema.node("doc", [:], content: Fragment.from([
                    try! schema.node("codeBlock", [:], content: Fragment.from([schema.text(text)]))]))
            }
            _ = layout(doc(), width, cache)
            for step in 0 ..< 25 {
                let at = text.index(text.startIndex, offsetBy: Int.random(in: 0 ... text.count, using: &rng))
                switch Int.random(in: 0 ..< 4, using: &rng) {
                case 0: text.insert("\n", at: at)
                case 1: text.insert(contentsOf: "x", at: at)
                case 2: text.insert(contentsOf: lines.randomElement(using: &rng)! + "\n", at: at)
                default:
                    let end = text.index(at, offsetBy: 6, limitedBy: text.endIndex) ?? text.endIndex
                    text.removeSubrange(at ..< end)
                }
                let d = doc()
                if let diff = difference(layout(d, width, cache), layout(d, width)) {
                    XCTFail("width \(width), edit \(step): \(diff)"); break
                }
            }
            XCTAssertGreaterThan(cache.debugIncrementalBreaks, 12, "width \(width)")
        }
    }

    /// Crossing the length breaks whole; staying on one side resumes.
    func testAnEditAcrossTheShapingChangeLengthBreaksWhole() {
        let sentence = "It was the best of times, it was the worst of times, it was the age of wisdom. "
        let base = String(String(repeating: sentence, count: 200).prefix(LineBreaking.shapingChangeLength - 20))
        let cache = TextBlockLayoutCache()
        var pieces: [Piece] = [.text(base, [])]
        _ = DocumentLayout(doc: document([pieces]), width: 362, theme: DocumentTheme(), blockCache: cache)
        for (added, resumes) in [("short ", true), (String(repeating: "longer ", count: 10), false),
                                 ("more ", true), (String(repeating: "x", count: 1), true)] {
            guard case let .text(t, _) = pieces[0] else { return }
            pieces[0] = .text(String(t.prefix(40)) + added + String(t.dropFirst(40)), [])
            let doc = document([pieces])
            let before = cache.debugIncrementalBreaks
            let incremental = DocumentLayout(doc: doc, width: 362, theme: DocumentTheme(), blockCache: cache)
            XCTAssertEqual(cache.debugIncrementalBreaks - before, resumes ? 1 : 0, "adding \(added.count) units")
            XCTAssertNil(difference(incremental, DocumentLayout(doc: doc, width: 362, theme: DocumentTheme())))
        }
    }

    /// Resuming has to be the common case, or it buys nothing: most edits to
    /// a long paragraph must take it, not fall back.
    func testMostEditsToALongParagraphResume() {
        var rng = RNG(seed: 42)
        var pieces: [Piece] = [.text(words(800, &rng), [])]
        let cache = TextBlockLayoutCache()
        _ = DocumentLayout(doc: document([pieces]), width: 362, theme: DocumentTheme(), blockCache: cache)
        for _ in 0 ..< 20 {
            guard case let .text(t, _) = pieces[0] else { return }
            let at = t.index(t.startIndex, offsetBy: Int.random(in: 0 ... t.count, using: &rng))
            pieces[0] = .text(String(t[..<at]) + "x" + String(t[at...]), [])
            _ = DocumentLayout(doc: document([pieces]), width: 362, theme: DocumentTheme(), blockCache: cache)
        }
        XCTAssertEqual(cache.debugIncrementalBreaks, 20)
    }

    /// Text that can reorder a line, or that line breaking segments by
    /// dictionary, is always broken whole — and still comes out right.
    func testBidirectionalAndDictionaryScriptsBreakWhole() {
        for sample in ["שלום עולם זה משפט ארוך בעברית", "مرحبا بالعالم هذه جملة طويلة",
                       "ภาษาไทยไม่มีช่องว่างระหว่างคำ", "English with a \u{200F} mark in it"] {
            var rng = RNG(seed: 7)
            let base = words(500, &rng)
            var pieces: [Piece] = [.text(base + " " + sample + " " + base, [])]
            let cache = TextBlockLayoutCache()
            _ = DocumentLayout(doc: document([pieces]), width: 362, theme: DocumentTheme(), blockCache: cache)
            guard case let .text(t, _) = pieces[0] else { return }
            pieces[0] = .text("x" + t, [])
            let doc = document([pieces])
            let incremental = DocumentLayout(doc: doc, width: 362, theme: DocumentTheme(), blockCache: cache)
            XCTAssertEqual(cache.debugIncrementalBreaks, 0, sample)
            XCTAssertNil(difference(incremental, DocumentLayout(doc: doc, width: 362, theme: DocumentTheme())), sample)
        }
    }

    /// Text with no space to resume from takes the plain path: it would be
    /// re-broken end to end either way.
    func testTextWithoutSpacesBreaksWhole() {
        let cjk = String(repeating: "中文字符没有空格的长句子日本語の文章", count: 200)
        var pieces: [Piece] = [.text(cjk, [])]
        let cache = TextBlockLayoutCache()
        _ = layout(document([pieces]), 362, cache)
        pieces[0] = .text("字" + cjk, [])
        let doc = document([pieces])
        let incremental = layout(doc, 362, cache)
        XCTAssertEqual(cache.debugIncrementalBreaks, 0)
        XCTAssertNil(difference(incremental, layout(doc, 362)))
    }

    /// A short block never keeps a record, so a document of ordinary
    /// paragraphs pays nothing for any of this.
    func testShortBlocksBreakWhole() {
        let cache = TextBlockLayoutCache()
        let para = [Piece.text("An ordinary paragraph of a few words.", [])]
        _ = DocumentLayout(doc: document([para]), width: 362, theme: DocumentTheme(), blockCache: cache)
        _ = DocumentLayout(doc: document([para + [.text(" More.", [])]]), width: 362, theme: DocumentTheme(),
                           blockCache: cache)
        XCTAssertEqual(cache.debugIncrementalBreaks, 0)
    }

    /// The whole path, as a user takes it: keystrokes into a long paragraph in
    /// the editable view, compared with a fresh view of the same document.
    func testTypingInALongParagraphLaysOutAsAFreshViewWould() throws {
        var rng = RNG(seed: 3)
        let text = words(900, &rng)
        let editor = try Editor(extensions: fullKit())
        editor.setContent(try editor.schema.node("doc", [:], content: Fragment.from([
            try editor.schema.node("paragraph", [:], content: Fragment.from([editor.schema.text(text)]))])))
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        view.spellCheckingEnabled = false
        view.layoutIfNeeded()
        _ = view.ensureLayout()
        let size = editor.doc.content.size
        for (step, pos) in [size / 2, 3, size - 4, size / 3].enumerated() {
            editor.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.doc, pos)))
            view.insertText("x")
            view.insertText(" ")
            view.deleteBackward()
            let typed = view.ensureLayout()

            // Its own editor, so nothing is shared but the document.
            let other = try Editor(extensions: fullKit())
            other.setContent(try other.schema.nodeFromJSON(editor.doc.toJSON()))
            let fresh = EditorTextView(editor: other)
            fresh.frame = view.frame
            fresh.spellCheckingEnabled = false
            fresh.layoutIfNeeded()
            XCTAssertNil(difference(typed, fresh.ensureLayout()), "after edit \(step)")
        }
        XCTAssertGreaterThan(view.blockCache.debugIncrementalBreaks, 0)
    }
}
#endif

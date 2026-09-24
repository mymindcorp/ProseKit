#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import SchemaKit
@testable import EditorUIKit

/// `documentHeight` is an estimate past the lazy threshold, and a host that
/// sizes a scroll container to it needs to know that — a short extent is also a
/// short scroll, so the missing tail cannot be reached and never realizes.
@MainActor
final class DocumentHeightExactnessTests: XCTestCase {
    /// The body text the documents here are built from. It has to carry two
    /// properties, each pinned by a test below, because losing either one
    /// quietly empties out the test that depends on it:
    ///
    /// - the estimator under-counts it (`…FallsShortAndMeasuringRecoversIt`);
    /// - its last line has almost no slack, so the list and quote indents each
    ///   push it onto one more line (`…ActuallyDiffersFromAllParagraphs`).
    ///
    /// One string can't reliably carry both. The second can't be had from a
    /// fixed string at all: how full the last line is depends on the body
    /// font's metrics, which change between simulators, and on the width of
    /// the block's "Para \(i):" prefix, which changes with the digits in `i` —
    /// a 54-word corpus that suited one device left only about half the
    /// indented blocks a line taller on another. So the mixed documents use
    /// `fittedBody`, fitted per block. And filling the last line takes away
    /// the wrap waste that is exactly what the estimator misses in a bare
    /// paragraph — this corpus is narrower per character than the 0.5 em the
    /// estimator assumes, so without that waste it over-counts — so the
    /// all-paragraph documents keep the plain corpus.
    private static let corpus: String = {
        let vocab = ["lorem", "ipsum", "dolor", "sit", "amet",
                     "consectetur", "adipiscing", "elit", "sed", "do"]
        return (0 ..< 54).map { vocab[$0 % vocab.count] }.joined(separator: " ")
    }()

    private static var fitted: [Int: String] = [:]
    private static let measuringSchema = try! Editor(extensions: fullKit()).schema

    private static func plainBody(_ i: Int) -> String { "Para \(i): \(corpus)" }

    /// Block `i`'s text with its last line filled: the plain text topped up
    /// with as many " i" as fit without adding a line at a bare paragraph's
    /// width. The slack that leaves is under the width of " i", and the
    /// narrowest indent (the quote's) is wider than that, so every indent costs
    /// a line wherever the lines break: line breaking is greedy, so no line of
    /// the narrower column ends past where the full-width one did, and the text
    /// left for its last line is wider than the narrower column.
    private static func fittedBody(_ i: Int) -> String {
        if let text = fitted[i] { return text }
        let base = plainBody(i)
        func text(_ k: Int) -> String { base + String(repeating: " i", count: k) }
        func lines(_ k: Int) -> Int {
            let s = measuringSchema
            let doc = try! s.node("doc", [:], content: Fragment.from([
                try! s.node("paragraph", [:], content: Fragment.from([s.text(text(k))])),
            ]))
            return DocumentLayout(doc: doc, width: 362, theme: DocumentTheme()).blocks[0].lines.count
        }
        // The largest k that keeps the line count: lines(k) is monotone in k,
        // and 64 of them overflow any line of a phone column.
        let target = lines(0)
        var lo = 0, hi = 64
        precondition(lines(hi) > target)
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if lines(mid) == target { lo = mid } else { hi = mid }
        }
        fitted[i] = text(lo)
        return text(lo)
    }

    private func editor(_ n: Int, mixed: Bool = false, fitted: Bool = false) -> Editor {
        let editor = try! Editor(extensions: fullKit())
        let s = editor.schema
        var blocks: [Node] = []
        for i in 0 ..< n {
            let text = Fragment.from([s.text(fitted ? Self.fittedBody(i) : Self.plainBody(i))])
            // Block types the estimator under-counts: it assumes a fixed average
            // character width and no wrap overhead, so markers and indents are
            // exactly what it misses.
            if mixed, i % 3 == 1 {
                let item = try! s.node("listItem", [:], content: Fragment.from([try! s.node("paragraph", [:], content: text)]))
                blocks.append(try! s.node("bulletList", [:], content: Fragment.from([item])))
            } else if mixed, i % 3 == 2 {
                blocks.append(try! s.node("blockquote", [:], content: Fragment.from([try! s.node("paragraph", [:], content: text)])))
            } else {
                blocks.append(try! s.node("paragraph", [:], content: text))
            }
        }
        editor.setContent(try! s.node("doc", [:], content: Fragment.from(blocks)))
        return editor
    }

    private func view(_ e: Editor, width: CGFloat = 362, height: CGFloat = 800) -> EditorTextView {
        let v = EditorTextView(editor: e)
        v.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        return v
    }

    /// The reference: the same document laid out with no realize window at all.
    private func fullHeight(_ e: Editor, width: CGFloat = 362) -> CGFloat {
        DocumentLayout(doc: e.doc, width: width, theme: DocumentTheme()).height
    }

    func testASmallDocumentIsExactImmediately() {
        let v = view(editor(8))
        XCTAssertTrue(v.documentHeightIsExact)
        XCTAssertEqual(v.measuredDocumentHeight(), v.documentHeight, accuracy: 0.01)
    }

    func testALazyDocumentIsNotExactUntilMeasured() {
        let v = view(editor(300))
        XCTAssertFalse(v.documentHeightIsExact, "most of a 300-block document is estimated")
        _ = v.measuredDocumentHeight()
        XCTAssertTrue(v.documentHeightIsExact, "measuring realizes the whole document")
    }

    func testMeasuredHeightMatchesAFullLayout() {
        let e = editor(300)
        let v = view(e)
        XCTAssertEqual(v.measuredDocumentHeight(), fullHeight(e), accuracy: 0.5)
    }

    /// The regression the app hit, at the library level: the estimate lands
    /// *under* the truth, and a host that sizes a scroll container to it then
    /// has no way to reach — or realize — the tail it cut off. Measured here at
    /// -2.2% on 300 paragraphs at a phone column.
    func testTheEstimateFallsShortAndMeasuringRecoversIt() {
        let e = editor(300)
        let v = view(e)
        let exact = fullHeight(e)
        XCTAssertLessThan(v.documentHeight, exact,
                          "the estimator under-reports this document — the case that clips a note")
        XCTAssertFalse(v.documentHeightIsExact)
        XCTAssertEqual(v.measuredDocumentHeight(), exact, accuracy: 0.5)
        XCTAssertTrue(v.documentHeightIsExact)
    }

    /// The same guarantee over a document carrying lists and quotes as well as
    /// paragraphs.
    func testMeasuredHeightIsExactForAMixOfBlockTypes() {
        let e = editor(300, mixed: true, fitted: true)
        let v = view(e)
        XCTAssertFalse(v.documentHeightIsExact)
        XCTAssertEqual(v.measuredDocumentHeight(), fullHeight(e), accuracy: 0.5)
    }

    /// The mix is load-bearing: lists and quotes indent their content, so the
    /// same text wraps to more lines inside them than in a bare paragraph, and
    /// this document is taller than the all-paragraph one of the same length.
    ///
    /// Asserted rather than assumed, because it holds only for a corpus picked
    /// for it. Wrapping is quantised to whole lines, so an indent shows up in
    /// the height only when it pushes the text past a line boundary; give the
    /// last line room to spare and the narrower column costs nothing, leaving
    /// the test above passing over a document indistinguishable in height from
    /// 300 paragraphs. An earlier corpus did exactly that — it wrapped to nine
    /// lines at 330 pt, at 314 pt and at 306 pt alike.
    func testTheMixedDocumentActuallyDiffersFromAllParagraphs() {
        // What one indent costs, measured rather than assumed, so this doesn't
        // depend on the body font: the same two blocks, listed and not.
        let oneIndent = fullHeight(editor(2, mixed: true, fitted: true)) - fullHeight(editor(2, fitted: true))
        XCTAssertGreaterThan(oneIndent, 0, "the list indent has to cost a line for this to cover anything")
        XCTAssertEqual(fullHeight(editor(300, mixed: true, fitted: true)) - fullHeight(editor(300, fitted: true)),
                       200 * oneIndent, accuracy: 0.5,
                       "each of the 200 lists and quotes costs a line")
    }

    /// Measuring keeps its work, unlike laying the document out on a throwaway
    /// view: nothing is left estimated, so scrolling realizes nothing.
    func testMeasuringLeavesTheLayoutRealized() {
        let v = view(editor(300))
        _ = v.measuredDocumentHeight()
        XCTAssertFalse(v.ensureLayout().hasEstimatedContent)
        XCTAssertFalse(v.ensureLayout().entries.contains { $0.estimated })
    }
}
#endif

#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import SchemaKit
import EditorStateKit
import DocumentTransform
@testable import EditorUIKit

/// Drawing the selection while scrolling.
///
/// Every rect `selectionRects` returns costs two CoreText offset lookups, and
/// it produces one per line of the range. The drawing callers only ever fill
/// the rects that are on screen — but they used to ask for all of them and
/// filter afterwards, so a document with a large selection paid for every line
/// of that selection on every frame of a scroll. The band being drawn is a
/// screenful; the selection can be the whole document.
@MainActor
final class SelectionScrollPerfTests: XCTestCase {
    private func longDoc(_ n: Int) -> (Schema, Node) {
        let s = try! Editor(extensions: fullKit()).schema
        let words = Array(repeating: "lorem ipsum dolor sit amet", count: 12).joined(separator: " ")
        let paras = (0 ..< n).map { i in
            try! s.node("paragraph", [:], content: Fragment.from([s.text("Para \(i): \(words)")]))
        }
        return (s, try! s.node("doc", [:], content: Fragment.from(paras)))
    }

    private func layout(_ doc: Node) -> DocumentLayout {
        DocumentLayout(doc: doc, width: 390, theme: DocumentTheme(),
                       blockCache: TextBlockLayoutCache())
    }

    private func bestMs(_ runs: Int = 7, _ body: () -> Void) -> Double {
        var best = Double.infinity
        for _ in 0 ..< runs {
            let t = CFAbsoluteTimeGetCurrent()
            body()
            best = min(best, (CFAbsoluteTimeGetCurrent() - t) * 1000)
        }
        return best
    }

    // MARK: What it costs

    func testClippingDecouplesSelectionSizeFromFrameCost() {
        // The bug, as a number: with everything selected, one frame's worth of
        // selection rects should cost what a screenful costs, not what the
        // document costs.
        let (_, doc) = longDoc(600)
        let l = layout(doc)
        let all = 1 ... (doc.content.size - 1)
        let band: ClosedRange<CGFloat> = 0 ... 800   // roughly one screen

        let whole = bestMs { _ = l.selectionRects(from: all.lowerBound, to: all.upperBound) }
        let clipped = bestMs { _ = l.selectionRects(from: all.lowerBound, to: all.upperBound, clipY: band) }
        print(unsafe "SELRECTS whole=\(String(format: "%.2f", whole))ms "
            + "clipped=\(String(format: "%.3f", clipped))ms ratio=\(String(format: "%.1f", whole / clipped))x")

        XCTAssertLessThan(clipped, whole / 10,
                          "clipping to a screenful should be an order of magnitude cheaper")
    }

    func testScrollingThroughASelectionCostsTheSameAtEveryDepth() {
        // The reported symptom, as a property. Selecting the whole document and
        // scrolling means the visible band walks away from where the selection
        // starts — so a frame drawn near the bottom must cost what a frame near
        // the top costs. Measuring at the top alone proves nothing: that is the
        // one place a scan from the start of the selection is already cheap,
        // which is how the first version of this test passed without the fix.
        let (_, doc) = longDoc(2000)
        let l = layout(doc)
        let whole = 1 ... (doc.content.size - 1)
        var costs: [(CGFloat, Double)] = []
        for fraction in [CGFloat(0), 0.25, 0.5, 0.9] {
            let top = l.height * fraction
            let band = top ... (top + 800)
            // A hundred frames per sample: one is a few microseconds, which is
            // under the noise floor, and a ratio of two noisy numbers is not a
            // measurement.
            costs.append((top, bestMs {
                for _ in 0 ..< 100 {
                    _ = l.selectionRects(from: whole.lowerBound, to: whole.upperBound, clipY: band)
                }
            }))
        }
        let report = costs.map { pair -> String in
            let ms = unsafe String(format: "%.3f", pair.1)
            return "y=\(Int(pair.0)):\(ms)ms"
        }.joined(separator: " ")
        print("SELDEPTH " + report)
        let shallowest = costs[0].1, deepest = costs.map(\.1).max()!
        // Ratio-based, with a small floor so a fast machine measuring near zero
        // doesn't turn noise into a failure. The claim is that the cost doesn't
        // grow as you scroll, not that every frame is identical.
        XCTAssertLessThan(deepest, shallowest * 3 + 0.5,
                          "drawing the selection gets more expensive the further you scroll")
    }

    /// The demo's "Long" document: 520 paragraphs of ~500 words. One paragraph
    /// is a single block hundreds of lines tall — far taller than the screen.
    private func longParagraphDoc(_ n: Int, words: Int = 500) -> Node {
        let s = try! Editor(extensions: fullKit()).schema
        let text = (0 ..< words).map { "word\($0 % 97)" }.joined(separator: " ")
        let paras = (0 ..< n).map { i in
            try! s.node("paragraph", [:], content: Fragment.from([s.text("Para \(i). \(text)")]))
        }
        return try! s.node("doc", [:], content: Fragment.from(paras))
    }

    func testAHighlightedBlockTallerThanTheScreenCostsOnlyTheScreen() {
        // Clipping to blocks is not enough on its own. Highlight one ~500-word
        // paragraph — a single block hundreds of lines tall — and every line of
        // it passes the character test, so a per-block clip still pays for the
        // whole paragraph on every frame of a scroll. This is the demo's Long
        // view, and it stayed slow after the per-block clip landed.
        let doc = longParagraphDoc(8)
        let l = layout(doc)
        let block = l.blocks[1]                       // the first full paragraph
        XCTAssertGreaterThan(block.lines.count, 60,
                             "a 500-word paragraph should be many screens tall")
        XCTAssertGreaterThan(block.frame.height, 2400, "and far taller than a screen")

        let from = block.contentStart, to = block.contentEnd
        // A band in the middle of the block: every edge of it is inside the
        // same block, so nothing but per-line clipping can help here.
        let mid = block.frame.minY + block.frame.height / 2
        let band = mid ... (mid + 800)
        let whole = bestMs(20) { _ = l.selectionRects(from: from, to: to) }
        let clipped = bestMs(20) { _ = l.selectionRects(from: from, to: to, clipY: band) }
        print(unsafe "SELBLOCK lines=\(block.lines.count) whole=\(String(format: "%.3f", whole))ms "
            + "clipped=\(String(format: "%.3f", clipped))ms ratio=\(String(format: "%.1f", whole / clipped))x")

        // An 800pt band of a ~2400pt block: the rects it keeps are about a
        // third of the paragraph's lines, so the offset lookups drop by that
        // much. The line loop still *visits* every line (it does not break out
        // — nothing here promises the lines are in vertical order), so the win
        // inside one block is a fraction, not an order of magnitude. The claim
        // that matters for scrolling is the flatness one, tested below.
        let kept = l.selectionRects(from: from, to: to, clipY: band).count
        XCTAssertLessThan(kept, block.lines.count / 2)
        XCTAssertGreaterThan(kept, 0, "the band is inside the block; it must draw something")
        XCTAssertLessThan(clipped, whole,
                          "a screenful of a tall highlighted block should cost less than the block")
    }

    func testScrollingThroughOneTallHighlightIsFlat() {
        // The same property as the depth test, but the scroll happens *within*
        // a single block rather than across many.
        let doc = longParagraphDoc(4)
        let l = layout(doc)
        let block = l.blocks[1]
        let from = block.contentStart, to = block.contentEnd
        var costs: [Double] = []
        for fraction in [CGFloat(0), 0.3, 0.6, 0.9] {
            let top = block.frame.minY + block.frame.height * fraction
            costs.append(bestMs {
                for _ in 0 ..< 100 { _ = l.selectionRects(from: from, to: to, clipY: top ... (top + 800)) }
            })
        }
        let report = costs.map { c -> String in unsafe String(format: "%.3f", c) }.joined(separator: " ")
        print("SELINBLOCK " + report)
        XCTAssertLessThan(costs.max()!, costs.min()! * 3 + 0.5,
                          "cost grows as you scroll down inside one highlighted block")
    }

    // MARK: The scroll tick itself

    func testScrollTickDoesNotCostTheWholeSelection() {
        // `onSelectionChange` fires from `contentOffsetY.didSet` — on every tick
        // of a scroll, not just when the selection changes. It asked for the
        // whole selection's rects, so scrolling with everything selected paid
        // the unclipped cost per frame no matter how much of it was visible.
        // This is the same bug as the drawing paths, in a caller that does not
        // draw, which is why converting the drawing callers did not fix it.
        // Built from this editor's own schema — a node made with another
        // schema does not survive setContent, and the doc comes out empty.
        let editor = try! Editor(extensions: fullKit())
        let s = editor.schema
        let words = Array(repeating: "lorem ipsum dolor sit amet", count: 12).joined(separator: " ")
        let paras = (0 ..< 800).map { i in
            try! s.node("paragraph", [:], content: Fragment.from([s.text("Para \(i): \(words)")]))
        }
        editor.setContent(try! s.node("doc", [:], content: Fragment.from(paras)))
        let v = EditorTextView(editor: editor)
        v.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        v.layoutIfNeeded()
        var reports = 0
        var lastCount = 0
        var lastEmpty = true
        v.onSelectionChange = { rects, isEmpty in
            reports += 1; lastCount = rects.count; lastEmpty = isEmpty
        }
        let tr = editor.state.tr
        tr.setSelection(TextSelection.create(tr.doc, 1, tr.doc.content.size - 1))
        editor.dispatch(tr)

        // Somewhere the lazy layout has realized: an estimated block has no
        // lines, so measuring over one would be measuring nothing.
        v.contentOffsetY = 1000
        v.layoutIfNeeded()
        reports = 0
        let ms = bestMs(5) {
            for i in 0 ..< 50 { v.contentOffsetY = 1000 + CGFloat(i) }
        }
        let sel = editor.state.selection
        // For scale: what the tick used to ask for. Note this is nothing like
        // the unclipped cost on a fully realized layout — under lazy layout an
        // off-screen block is estimated and has no lines, so the old call was
        // already bounded by the realize window (a few screens), not by the
        // document. The reported count is the invariant worth asserting on;
        // the timings are printed for information, not asserted, since the
        // tick also realizes, moves the caret, and syncs checkbox views.
        let unclipped = bestMs(3) { _ = v.ensureLayout().selectionRects(from: sel.from, to: sel.to) }
        print(unsafe "SELTICK reports=\(reports) rects=\(lastCount) empty=\(lastEmpty) "
            + "sel=\(sel.from)..\(sel.to) perTick=\(String(format: "%.3f", ms / 50))ms "
            + "unclipped=\(String(format: "%.2f", unclipped))ms")
        XCTAssertGreaterThan(reports, 0, "scrolling must report geometry, or the caret strands")
        XCTAssertFalse(lastEmpty, "the whole document is selected")
        // A screenful of 15pt-ish lines is tens of rects, not the thousands a
        // 800-paragraph selection spans.
        XCTAssertLessThan(lastCount, 100, "reported more than a screenful of rects")
        XCTAssertGreaterThan(lastCount, 0, "the selection covers the viewport; it must report rects")
    }

    // MARK: That it draws the same thing

    func testClippingKeepsExactlyTheRectsInTheBand() {
        // Clipping must be invisible: the rects that survive have to be the
        // ones the caller would have kept anyway. If this diverges, the fix
        // has changed what the user sees.
        let (_, doc) = longDoc(200)
        let l = layout(doc)
        let from = 1, to = doc.content.size - 1
        let unclipped = l.selectionRects(from: from, to: to)
        for band in [CGFloat(0) ... 400, 500 ... 1200, 2000 ... 2600] {
            let clipped = l.selectionRects(from: from, to: to, clipY: band)
            let expected = unclipped.filter { $0.maxY >= band.lowerBound && $0.minY <= band.upperBound }
            // Clipping is per line, using the same predicate the callers used
            // to filter by hand — so this is equality, not containment. Drawing
            // is bit-for-bit what it was before the clip existed.
            XCTAssertEqual(clipped, expected, "band \(band) changed what gets drawn")
        }
    }

    /// A doc where every paragraph carries a highlight mark, as the demo's Long
    /// view does once you highlight your way through it.
    private func highlightedDoc(_ n: Int) -> Node {
        let s = try! Editor(extensions: fullKit()).schema
        let words = Array(repeating: "lorem ipsum dolor sit amet", count: 12).joined(separator: " ")
        let hl = s.mark("highlight", ["color": .string("yellow")])
        let paras = (0 ..< n).map { i in
            try! s.node("paragraph", [:], content: Fragment.from([s.text("Para \(i): \(words)", [hl])]))
        }
        return try! s.node("doc", [:], content: Fragment.from(paras))
    }

    func testOffScreenHighlightsAreSkippedWithoutChangingTheRuns() {
        // Marks live in one flat list over the document, so drawing them walks
        // all of them however far off screen they are. Rejecting them on
        // position must hand the host renderer exactly the same runs.
        let doc = highlightedDoc(400)
        let l = layout(doc)
        XCTAssertEqual(l.highlights.count, 400)

        func runs(clipY: ClosedRange<CGFloat>?) -> [CGRect] {
            var seen: [CGRect] = []
            let img = UIGraphicsImageRenderer(size: CGSize(width: 390, height: 800))
            _ = img.image { c in
                l.draw(in: c.cgContext, clipY: clipY) { _, rs in seen += rs.map(\.rect) }
            }
            return seen
        }
        let everything = runs(clipY: nil)
        for band in [CGFloat(0) ... 800, 4000 ... 4800, l.height - 400 ... l.height] {
            let expected = everything.filter { $0.maxY >= band.lowerBound && $0.minY <= band.upperBound }
            XCTAssertEqual(runs(clipY: band), expected, "band \(band) changed the runs")
            XCTAssertFalse(expected.isEmpty, "band \(band) should cover some highlighted text")
        }
        // A band past the end draws nothing at all.
        XCTAssertTrue(runs(clipY: 100_000 ... 200_000).isEmpty)
    }

    func testNoClipStillMeansEverything() {
        // UIKit asks for the selection's geometry to place handles and the
        // loupe, and it is not drawing a band. That call must be unchanged.
        let (_, doc) = longDoc(50)
        let l = layout(doc)
        let all = l.selectionRects(from: 1, to: doc.content.size - 1)
        XCTAssertGreaterThan(all.count, 50, "a 50-paragraph selection spans many lines")
        XCTAssertEqual(l.selectionRects(from: 1, to: doc.content.size - 1, clipY: nil).count, all.count)
    }

    func testAnEmptyOrBackwardsRangeIsStillNothing() {
        let (_, doc) = longDoc(10)
        let l = layout(doc)
        XCTAssertTrue(l.selectionRects(from: 5, to: 5, clipY: 0 ... 800).isEmpty)
        XCTAssertTrue(l.selectionRects(from: 20, to: 5, clipY: 0 ... 800).isEmpty)
    }

    func testABandBeyondTheDocumentSelectsNothing() {
        let (_, doc) = longDoc(20)
        let l = layout(doc)
        XCTAssertTrue(l.selectionRects(from: 1, to: doc.content.size - 1,
                                       clipY: 100_000 ... 200_000).isEmpty)
    }
}
#endif

#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import SchemaKit
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
            // Clipping is per block, so it may keep a little more than the
            // per-rect filter would — never less, and never anything outside
            // the blocks that overlap the band.
            for rect in expected {
                XCTAssertTrue(clipped.contains(rect),
                              "dropped a visible rect \(rect) for band \(band)")
            }
            XCTAssertLessThanOrEqual(clipped.count, unclipped.count)
        }
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

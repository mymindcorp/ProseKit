#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import SchemaKit
@testable import EditorUIKit

/// Lazy (estimated) initial layout for very large documents: typeset only the
/// children near the viewport, estimate the rest, and realize on scroll —
/// converging exactly to a full layout.
@MainActor
final class LazyLayoutTests: XCTestCase {
    private func bigDoc(_ n: Int) -> (Schema, Node) {
        let s = try! Editor(extensions: fullKit()).schema
        let words = Array(repeating: "lorem ipsum dolor sit amet", count: 12).joined(separator: " ")
        let paras = (0 ..< n).map { i in
            try! s.node("paragraph", [:], content: Fragment.from([s.text("Para \(i): \(words)")]))
        }
        return (s, try! s.node("doc", [:], content: Fragment.from(paras)))
    }

    private func full(_ doc: Node) -> DocumentLayout {
        DocumentLayout(doc: doc, width: 390, theme: DocumentTheme())
    }
    private func lazy(_ doc: Node, window: ClosedRange<CGFloat>) -> DocumentLayout {
        DocumentLayout(doc: doc, width: 390, theme: DocumentTheme(), realizeWindow: window)
    }

    func testLazyOnlyTypesetsNearWindowButReportsFullHeight() {
        let (_, doc) = bigDoc(300)
        let reference = full(doc)
        let small = lazy(doc, window: 0 ... 800) // only the first screen
        XCTAssertTrue(small.hasEstimatedContent, "most of the doc is estimated")
        XCTAssertLessThan(small.blocks.count, reference.blocks.count, "fewer blocks typeset")
        // The estimated total height is in the right ballpark (within 25%).
        XCTAssertEqual(small.height, reference.height, accuracy: reference.height * 0.25)
    }

    func testRealizingTheWholeDocConvergesToTheFullLayout() {
        let (_, doc) = bigDoc(300)
        let reference = full(doc)
        let lazyLayout = lazy(doc, window: 0 ... 800)
        // Realize everything by passing an all-covering window.
        _ = lazyLayout.realize(window: 0 ... .greatestFiniteMagnitude)
        XCTAssertFalse(lazyLayout.hasEstimatedContent, "everything is realized now")
        XCTAssertEqual(lazyLayout.height, reference.height, accuracy: 0.5, "height matches the full layout")
        XCTAssertEqual(lazyLayout.blocks.count, reference.blocks.count, "same number of blocks")
        // Block geometry matches the full layout exactly.
        for (a, b) in zip(lazyLayout.blocks, reference.blocks) {
            XCTAssertEqual(a.frame.minY, b.frame.minY, accuracy: 0.5)
            XCTAssertEqual(a.contentStart, b.contentStart)
        }
    }

    func testRealizeAroundPositionMakesAnOffScreenCaretAvailable() throws {
        let (_, doc) = bigDoc(300)
        let l = lazy(doc, window: 0 ... 800) // only the top is realized
        let farPos = doc.content.size - 5    // near the end — estimated
        XCTAssertTrue(l.isEstimated(pos: farPos), "the end is still estimated")
        XCTAssertTrue(l.realize(aroundPos: farPos, viewportHeight: 800))
        XCTAssertFalse(l.isEstimated(pos: farPos), "now realized")
        // The caret lands far down the document — not the near-top fallback the
        // estimated block would otherwise resolve to. (Its exact y converges as
        // the still-estimated blocks above it are realized on scroll.)
        let caret = try XCTUnwrap(l.caretRect(at: farPos))
        XCTAssertGreaterThan(caret.minY, 800, "realized caret is far down, not the near-top fallback")
    }

    func testSmallDocsAreNotEstimatedEvenWithAWindow() {
        let (_, doc) = bigDoc(5) // below the lazy threshold
        let l = lazy(doc, window: 0 ... 100)
        XCTAssertFalse(l.hasEstimatedContent, "small docs always lay out fully")
    }

    func testColdLazyLayoutIsFasterThanFull() {
        let (_, doc) = bigDoc(520)
        // Best of 3 for each, so a CPU-load spike on one sample (the suite
        // runs in parallel) affects both equally, then compare best-of-N.
        func time(_ body: () -> Void) -> Double {
            let t = CFAbsoluteTimeGetCurrent()
            body()
            return (CFAbsoluteTimeGetCurrent() - t) * 1000
        }
        var fulls: [Double] = [], lazies: [Double] = []
        for _ in 0..<7 {
            fulls.append(time { _ = self.full(doc) })
            lazies.append(time { _ = self.lazy(doc, window: 0 ... 900) }) // one screen
        }
        let fullMs = fulls.min()!, lazyMs = lazies.min()!
        print("LAYOUT full=\(Int(fullMs))ms lazy=\(Int(lazyMs))ms")
        XCTAssertLessThan(lazyMs, fullMs * 0.6, "lazy initial layout is much faster than a full one")
    }
}
#endif

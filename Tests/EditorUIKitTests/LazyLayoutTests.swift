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

    /// Realizing a viewport at a time keeps everything above the first child
    /// it typesets — those entries and their stretch of every flat array — and
    /// rebuilds only what follows. Scrolled down, then jumped far ahead, then
    /// back up into the gap, a layout must still end up as a full one would:
    /// each flat output in the same order with the same geometry, not just the
    /// blocks. Every kind of output is in the document, so a flat array that
    /// is trimmed wrong (or not at all) shows up as a duplicate or a gap.
    func testRealizingAViewportAtATimeConvergesToTheFullLayout() throws {
        let s = try Editor(extensions: fullKit()).schema
        func p(_ nodes: [Node]) -> Node { try! s.node("paragraph", [:], content: Fragment.from(nodes)) }
        var top: [Node] = []
        for i in 0 ..< 90 {
            switch i % 5 {
            case 0:
                top.append(p([s.text("plain \(i) "), s.text("highlighted", [s.mark("highlight")]),
                              s.text(" and "), s.text("code()", [s.mark("code")]),
                              s.text(" with words enough to wrap onto a second line of the column")]))
            case 1:
                top.append(try s.node("bulletList", [:], content: Fragment.from((0 ..< 3).map { j in
                    try! s.node("listItem", [:], content: Fragment.from([p([s.text("item \(i).\(j)")])]))
                })))
            case 2:
                top.append(try s.node("taskList", [:], content: Fragment.from((0 ..< 2).map { j in
                    try! s.node("taskItem", ["checked": .bool(j == 0)],
                                content: Fragment.from([p([s.text("task \(i).\(j)")])]))
                })))
            case 3:
                top.append(try s.node("blockquote", [:], content: Fragment.from([p([s.text("quoted \(i)")])])))
            default:
                top.append(try s.node("heading", ["level": .int(2)], content: Fragment.from([s.text("Heading \(i)")])))
            }
        }
        let doc = try s.node("doc", [:], content: Fragment.from(top))
        let reference = full(doc)
        let l = lazy(doc, window: 0 ... 800)
        XCTAssertTrue(l.hasEstimatedContent)

        var y: CGFloat = 0
        for _ in 0 ..< 5 { _ = l.realize(window: y ... (y + 800)); y += 800 }
        let far = l.height * 0.75
        _ = l.realize(window: far ... (far + 800))
        _ = l.realize(window: (far - 1600) ... (far - 800))
        XCTAssertTrue(l.hasEstimatedContent, "the walk should leave gaps, or it tests nothing a single realize doesn't")
        _ = l.realize(window: 0 ... .greatestFiniteMagnitude)
        XCTAssertFalse(l.hasEstimatedContent)

        XCTAssertEqual(l.height, reference.height, accuracy: 0.5)
        XCTAssertEqual(l.blocks.map(\.contentStart), reference.blocks.map(\.contentStart))
        for (a, b) in zip(l.blocks, reference.blocks) {
            XCTAssertEqual(a.frame.minY, b.frame.minY, accuracy: 0.5)
        }
        func ys(_ items: [DecorationItem]) -> [CGFloat] {
            items.map { d -> CGFloat in
                switch d {
                case let .fill(r, _), let .stroke(r, _, _), let .image(_, r), let .icon(_, r), let .math(_, r),
                     let .roundedFill(r, _, _), let .roundedStroke(r, _, _, _): r.minY
                case let .text(_, point, _): point.y
                }
            }
        }
        XCTAssertEqual(l.decorations.count, reference.decorations.count, "decorations")
        for (a, b) in zip(ys(l.decorations), ys(reference.decorations)) { XCTAssertEqual(a, b, accuracy: 0.5) }
        XCTAssertEqual(l.checkboxes.map(\.pos), reference.checkboxes.map(\.pos), "checkboxes")
        XCTAssertEqual(l.highlights.map(\.from), reference.highlights.map(\.from), "highlights")
        XCTAssertEqual(l.codeBackgrounds.map(\.from), reference.codeBackgrounds.map(\.from), "code backgrounds")
        XCTAssertFalse(reference.checkboxes.isEmpty || reference.highlights.isEmpty
                       || reference.codeBackgrounds.isEmpty, "the document should exercise every flat array")
    }

    func testSmallDocsAreNotEstimatedEvenWithAWindow() {
        let (_, doc) = bigDoc(5) // below the lazy threshold
        let l = lazy(doc, window: 0 ... 100)
        XCTAssertFalse(l.hasEstimatedContent, "small docs always lay out fully")
    }

    func testColdLazyLayoutIsFasterThanFull() {
        let (_, doc) = bigDoc(520)
        // Best of 7 for each, alternating, so a CPU-load spike on one sample
        // (the suite runs in parallel) can't decide the comparison.
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

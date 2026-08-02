#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import SchemaKit
@testable import EditorUIKit

/// Per-keystroke layout cost on long documents: an edit must only re-typeset
/// the edited block, and the block cache must survive incremental passes.
@MainActor
final class TypingPerfTests: XCTestCase {
    private func bigDoc(_ n: Int) -> (Schema, Node) {
        let s = try! Editor(extensions: fullKit()).schema
        let words = Array(repeating: "lorem ipsum dolor sit amet", count: 12).joined(separator: " ")
        let paras = (0 ..< n).map { i in
            try! s.node("paragraph", [:], content: Fragment.from([s.text("Para \(i): \(words)")]))
        }
        return (s, try! s.node("doc", [:], content: Fragment.from(paras)))
    }

    /// A keystroke: replace one paragraph, everything else shares storage.
    private func editing(_ s: Schema, _ doc: Node, para: Int, text: String) -> Node {
        var paras = (0 ..< doc.childCount).map { doc.child($0) }
        paras[para] = try! s.node("paragraph", [:], content: Fragment.from([s.text(text)]))
        return try! s.node("doc", [:], content: Fragment.from(paras))
    }

    /// Diagnostic: keystroke cost in the long-view (lazy window) path at several
    /// document sizes, editing NEAR THE TOP (worst case: a large suffix to shift).
    func testLongViewKeystrokeScaling() {
        let theme = TextTheme()
        for n in [1000, 4000, 8000] {
            let (s, doc) = bigDoc(n)
            let cache = TextBlockLayoutCache()
            var previous = DocumentLayout(doc: doc, width: 390, theme: theme,
                                          blockCache: cache, realizeWindow: 0 ... 900)
            var current = doc
            var times: [Double] = []
            for round in 0 ..< 5 {
                current = editing(s, current, para: 2, text: "edit \(round)")
                let t = CFAbsoluteTimeGetCurrent()
                previous = DocumentLayout(doc: current, width: 390, theme: theme,
                                          blockCache: cache, previous: previous, realizeWindow: 0 ... 900)
                times.append((CFAbsoluteTimeGetCurrent() - t) * 1000)
            }
            print(unsafe "LONGVIEW n=\(n) keystroke(min)=\(String(format: "%.2f", times.min()!))ms realizedBlocks=\(previous.blocks.count)")
        }
    }

    func testKeystrokeLayoutIsIncrementalAndCacheSurvives() {
        let (s, doc) = bigDoc(800)
        let cache = TextBlockLayoutCache()
        let theme = TextTheme()

        let t0 = CFAbsoluteTimeGetCurrent()
        let base = DocumentLayout(doc: doc, width: 390, theme: theme, blockCache: cache)
        let fullMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000

        // Three consecutive keystrokes in the middle of the document.
        var previous = base
        var current = doc
        var keystrokeMs: [Double] = []
        for round in 0 ..< 3 {
            current = editing(s, current, para: 400, text: "edited \(round) word wrod")
            let t1 = CFAbsoluteTimeGetCurrent()
            previous = DocumentLayout(doc: current, width: 390, theme: theme,
                                      blockCache: cache, previous: previous)
            keystrokeMs.append((CFAbsoluteTimeGetCurrent() - t1) * 1000)
        }
        print(unsafe "TYPING-PERF full=\(String(format: "%.1f", fullMs))ms keystrokes=\(keystrokeMs.map { unsafe String(format: "%.2f", $0) }) cacheCount=\(cache.debugEntryCount)")

        // Geometry must match a from-scratch layout exactly.
        let reference = DocumentLayout(doc: current, width: 390, theme: theme)
        XCTAssertEqual(previous.blocks.count, reference.blocks.count)
        XCTAssertEqual(previous.height, reference.height, accuracy: 0.5)

        // The cold build cached every paragraph; keystrokes must not wipe it.
        XCTAssertGreaterThan(cache.debugEntryCount, 700,
                             "block cache must survive incremental passes")
        // And a keystroke is far cheaper than the cold build (generous margin
        // to stay robust under CI load).
        XCTAssertLessThan(keystrokeMs.min()!, fullMs * 0.2)
    }
}
#endif

#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import SchemaKit
import EditorStateKit
@testable import EditorUIKit

/// What one step of a selection drag costs — the dispatch a moving selection
/// handle (or caret loupe) pays on every tick.
///
/// The table extension's fix pass used to walk the whole document from
/// `appendTransaction` on *every* transaction, selection-only ones included, so
/// a selection drag got slower with the document: 0.05ms a step at 100
/// paragraphs, ~1ms at 3200 — most of a 120Hz frame, spent re-checking tables
/// that a selection move cannot deform. The walk now runs only when the doc
/// changed (`PMTableExtra` pins that behavior); this test pins the consequence,
/// that a drag step's cost does not grow with the document.
@MainActor
final class SelectionDragPerfTests: XCTestCase {
    private func bigView(_ paragraphs: Int) -> EditorTextView {
        let editor = try! Editor(extensions: fullKit())
        let s = editor.schema
        let words = Array(repeating: "lorem ipsum dolor sit amet", count: 12).joined(separator: " ")
        let paras = (0 ..< paragraphs).map { i in
            try! s.node("paragraph", [:], content: Fragment.from([s.text("Para \(i): \(words)")]))
        }
        editor.setContent(try! s.node("doc", [:], content: Fragment.from(paras)))
        let v = EditorTextView(editor: editor)
        v.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        v.layoutIfNeeded()
        _ = v.ensureLayout()
        return v
    }

    /// Per-step cost of one pass of a handle drag over the first ~430 steps.
    private func dragStepPass(_ v: EditorTextView) -> Double {
        let t = CFAbsoluteTimeGetCurrent()
        var steps = 0
        for head in stride(from: 2, to: 3000, by: 7) {
            v.selectedTextRange = DocTextRange(1, head)
            steps += 1
        }
        return (CFAbsoluteTimeGetCurrent() - t) * 1000 / Double(steps)
    }

    func testDragStepCostDoesNotGrowWithTheDocument() {
        // Both views exist before either is measured, so the large document's
        // allocation is not charged to the large document's timings.
        let smallView = bigView(100)
        let largeView = bigView(3200)
        _ = dragStepPass(smallView) // warm the caches a first pass populates
        _ = dragStepPass(largeView)

        // Measured in alternating rounds rather than one side and then the
        // other, each side keeping its cheapest round. A shared CI runner's
        // contention comes and goes and can only ever make a round *dearer*, so
        // the cheapest round is the best estimate of what a step really costs —
        // and alternating gives both documents the same chance at a quiet one.
        // (Timing all of the small passes first, as this did, let a runner that
        // got busy halfway through compare a quiet small against a contended
        // large, which is how a ratio test fails on a machine that has not
        // regressed at all.)
        var small = Double.infinity, large = Double.infinity
        for _ in 0 ..< 5 {
            small = min(small, dragStepPass(smallView))
            large = min(large, dragStepPass(largeView))
        }
        print(unsafe "DRAGSTEP small=\(String(format: "%.4f", small))ms "
            + "large=\(String(format: "%.4f", large))ms")
        // Ratio with a floor, as the scroll perf tests do: the claim is that a
        // 32× document does not make a drag step meaningfully dearer, not that
        // two tiny numbers are identical. The floor is generous enough to cover
        // the fixed per-step work on a slow, contended runner (~0.18ms a step
        // has been seen on CI) while staying far below the ~1ms/step the walk
        // this pins cost at 3200 paragraphs.
        XCTAssertLessThan(large, small * 3 + 0.2,
                          "a selection drag step got more expensive as the document grew")
    }
}
#endif

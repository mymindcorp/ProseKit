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

    /// Per-step cost of a handle drag over the first ~430 steps, best of a few
    /// runs so a scheduler hiccup doesn't decide the outcome.
    private func dragStepMs(_ v: EditorTextView) -> Double {
        var best = Double.infinity
        for _ in 0 ..< 3 {
            let t = CFAbsoluteTimeGetCurrent()
            var steps = 0
            for head in stride(from: 2, to: 3000, by: 7) {
                v.selectedTextRange = DocTextRange(1, head)
                steps += 1
            }
            best = min(best, (CFAbsoluteTimeGetCurrent() - t) * 1000 / Double(steps))
        }
        return best
    }

    func testDragStepCostDoesNotGrowWithTheDocument() {
        let small = dragStepMs(bigView(100))
        let large = dragStepMs(bigView(3200))
        print(unsafe "DRAGSTEP small=\(String(format: "%.4f", small))ms "
            + "large=\(String(format: "%.4f", large))ms")
        // Ratio with a floor, as the scroll perf tests do: the claim is that a
        // 32× document does not make a drag step meaningfully dearer, not that
        // two tiny numbers are identical.
        XCTAssertLessThan(large, small * 3 + 0.05,
                          "a selection drag step got more expensive as the document grew")
    }
}
#endif

#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

/// Persistent incremental layout must be indistinguishable from a full rebuild.
/// This fuzzes random edits and, after each, asserts the view's incrementally
/// updated layout matches a fresh full layout exactly (block ranges + geometry).
@MainActor
final class IncrementalLayoutTests: XCTestCase {
    private struct RNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    private func assertMatchesFullRebuild(_ view: EditorTextView, _ context: String) {
        let incremental = view.ensureLayout()
        let full = DocumentLayout(doc: view.editor.doc, width: 320, theme: TextTheme())
        XCTAssertEqual(incremental.blocks.count, full.blocks.count, "block count \(context)")
        XCTAssertEqual(incremental.height, full.height, accuracy: 0.5, "height \(context)")
        for i in 0..<min(incremental.blocks.count, full.blocks.count) {
            let a = incremental.blocks[i], b = full.blocks[i]
            XCTAssertEqual(a.contentStart, b.contentStart, "block \(i) contentStart \(context)")
            XCTAssertEqual(a.contentEnd, b.contentEnd, "block \(i) contentEnd \(context)")
            XCTAssertEqual(a.frame.minY, b.frame.minY, accuracy: 0.5, "block \(i) y \(context)")
            XCTAssertEqual(a.lines.count, b.lines.count, "block \(i) line count \(context)")
        }
    }

    func testIncrementalLayoutMatchesFullRebuildUnderRandomEdits() throws {
        for seed in UInt64(1)...10 {
            var rng = RNG(state: seed)
            let editor = try Editor(extensions: fullKit())
            let paras = (0..<25).map { i in
                try! editor.schema.node("paragraph", [:], content: Fragment.from([editor.schema.text("paragraph \(i) with a little text")]))
            }
            editor.setContent(try! editor.schema.node("doc", [:], content: Fragment.from(paras)))
            let view = EditorTextView(editor: editor)
            view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
            view.layoutIfNeeded()
            _ = view.ensureLayout()

            for step in 0..<60 {
                let size = editor.doc.content.size
                let tr = editor.state.tr
                if Bool.random(using: &rng), size > 6 {
                    let from = Int.random(in: 1..<(size - 2), using: &rng)
                    let len = Int.random(in: 1...3, using: &rng)
                    try? tr.delete(from, min(from + len, size - 1))
                } else {
                    let at = Int.random(in: 1...max(1, size - 1), using: &rng)
                    try? tr.insertText(["a", "b ", "long word ", "x"].randomElement(using: &rng)!, at, at)
                }
                if tr.docChanged { editor.dispatch(tr) }
                assertMatchesFullRebuild(view, "seed \(seed) step \(step)")
            }
        }
    }
}
#endif

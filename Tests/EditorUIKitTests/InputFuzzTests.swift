#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

/// Randomised, reproducible exercising of the text-input paths (the way the
/// system drives them) to flush out ordering/state bugs like the fast-typing
/// word-breaking regression. Every seed is deterministic, so a failure prints
/// the seed and reproduces exactly.
@MainActor
final class InputFuzzTests: XCTestCase {
    /// Small deterministic PRNG (SplitMix64) so fuzz runs are reproducible.
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

    private func makeView() throws -> EditorTextView {
        let editor = try Editor(extensions: fullKit())
        let para = try! editor.schema.node("paragraph", [:], content: Fragment.empty)
        editor.setContent(try! editor.schema.node("doc", [:], content: Fragment.from([para])))
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        view.layoutIfNeeded()
        return view
    }

    /// Assert the invariants that must hold after any input operation.
    private func assertInvariants(_ view: EditorTextView, _ context: String) {
        let doc = view.editor.doc
        XCTAssertNoThrow(try doc.check(), "document became invalid \(context)")
        let size = doc.content.size
        let sel = view.editor.state.selection
        XCTAssertTrue(sel.from >= 0 && sel.to <= size && sel.from <= sel.to, "selection out of bounds \(context)")
        // Every position 0...size must resolve without trapping.
        for p in 0...size { _ = doc.resolve(p) }
        // UITextInput round-trips.
        let whole = DocTextRange(0, size)
        XCTAssertNotNil(view.text(in: whole), context)
        XCTAssertEqual(view.offset(from: view.beginningOfDocument, to: view.endOfDocument), size, context)
        let caret = view.caretRect(for: DocTextPosition(sel.head))
        XCTAssertTrue(caret.height.isFinite && caret.origin.x.isFinite, "caret rect not finite \(context)")
    }

    // MARK: - The core fast-typing guarantee

    func testFastTypingAtCursorProducesExactText() throws {
        let safe = Array("abcdefghijklmnopqrstuvwxyz ABCXYZ0123")
        for seed in UInt64(1)...30 {
            var rng = RNG(seed: seed)
            let view = try makeView()
            var expected = ""
            let count = Int.random(in: 20...120, using: &rng)
            for _ in 0..<count {
                let ch = safe.randomElement(using: &rng)!
                view.insertText(String(ch))
                expected.append(ch)
            }
            XCTAssertEqual(view.editor.doc.textContent, expected, "fast typing dropped/reordered characters (seed \(seed))")
            assertInvariants(view, "after fast typing (seed \(seed))")
        }
    }

    // MARK: - Mixed insert / delete / select / compose

    func testFuzzMixedOperationsKeepDocumentValid() throws {
        let chars = Array("abc def ghi\t")
        for seed in UInt64(1)...40 {
            var rng = RNG(seed: seed)
            let view = try makeView()
            for step in 0..<200 {
                let size = view.editor.doc.content.size
                switch Int.random(in: 0..<8, using: &rng) {
                case 0, 1, 2: // insert a character
                    view.insertText(String(chars.randomElement(using: &rng)!))
                case 3: // delete backward
                    view.deleteBackward()
                case 4: // move the caret somewhere valid
                    let p = Int.random(in: 0...size, using: &rng)
                    view.selectedTextRange = DocTextRange(p, p)
                case 5: // select a random range
                    let a = Int.random(in: 0...size, using: &rng)
                    let b = Int.random(in: 0...size, using: &rng)
                    view.selectedTextRange = DocTextRange(a, b)
                case 6: // begin/extend an IME composition
                    let len = Int.random(in: 1...3, using: &rng)
                    let s = String((0..<len).map { _ in chars.randomElement(using: &rng)! })
                    view.setMarkedText(s, selectedRange: NSRange(location: s.count, length: 0))
                default: // commit or cancel a composition, or press Enter
                    if Bool.random(using: &rng) { view.insertText("x") } else { view.unmarkText() }
                }
                assertInvariants(view, "seed \(seed), step \(step)")
            }
        }
    }

    // MARK: - IME composition consistency

    func testFuzzMarkedTextStaysConsistent() throws {
        let chars = Array("niháoabc")
        for seed in UInt64(1)...30 {
            var rng = RNG(seed: seed)
            let view = try makeView()
            // Type some base text first.
            for _ in 0..<Int.random(in: 0...10, using: &rng) { view.insertText("a") }
            var composing = ""
            for step in 0..<60 {
                switch Int.random(in: 0..<4, using: &rng) {
                case 0, 1: // grow the composition
                    composing.append(chars.randomElement(using: &rng)!)
                    view.setMarkedText(composing, selectedRange: NSRange(location: composing.count, length: 0))
                    let marked = try XCTUnwrap(view.markedTextRange as? DocTextRange, "seed \(seed) step \(step)")
                    XCTAssertEqual(view.text(in: marked), composing, "marked text diverged (seed \(seed), step \(step))")
                case 2: // commit
                    view.insertText("Z")
                    XCTAssertNil(view.markedTextRange)
                    composing = ""
                default: // cancel
                    view.unmarkText()
                    composing = ""
                }
                assertInvariants(view, "seed \(seed), step \(step)")
            }
        }
    }
}
#endif

#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import SchemaKit
import EditorStateKit
@testable import EditorUIKit

/// What a *paint* costs while scrolling — the sibling of `SelectionScrollPerfTests`,
/// which covers the geometry the paint asks for.
///
/// Both bugs here are the same shape as the one that file describes: work that
/// belongs to the screenful being drawn was instead proportional to the whole
/// document, so it was invisible until the document got long. Neither is caught
/// by a correctness test — the pixels were always right, they just cost too much
/// — so they are asserted as ratios, and always run.
@MainActor
final class DrawScrollPerfTests: XCTestCase {
    private static let width: CGFloat = 362
    private static let viewport: CGFloat = 800

    private func bestMs(_ runs: Int = 7, _ body: () -> Void) -> Double {
        var best = Double.infinity
        for _ in 0 ..< runs {
            let t = CFAbsoluteTimeGetCurrent()
            body()
            best = min(best, (CFAbsoluteTimeGetCurrent() - t) * 1000)
        }
        return best
    }

    private func inBitmap(_ body: (CGContext) -> Void) {
        UIGraphicsBeginImageContextWithOptions(CGSize(width: Self.width, height: Self.viewport), true, 1)
        defer { UIGraphicsEndImageContext() }
        body(UIGraphicsGetCurrentContext()!)
    }

    // MARK: - A block taller than the screen

    func testDrawingATallBlockCostsOnlyTheVisibleLines() {
        // A code block is one block however long it is, and a block that met the
        // band drew every one of its lines — so showing the top of a 2000-line
        // block paid for all 2000. The per-block clip cannot help here (there is
        // only one block); only a per-line one can.
        let s = try! Editor(extensions: fullKit()).schema
        func codeDoc(_ lines: Int) -> Node {
            let text = (0 ..< lines).map { "let value\($0) = compute(\($0)) // a line of code" }
                .joined(separator: "\n")
            let code = try! s.node("codeBlock", [:], content: Fragment.from([s.text(text)]))
            return try! s.node("doc", [:], content: Fragment.from([code]))
        }
        let short = DocumentLayout(doc: codeDoc(200), width: Self.width, theme: DocumentTheme())
        let long = DocumentLayout(doc: codeDoc(2000), width: Self.width, theme: DocumentTheme())
        XCTAssertEqual(long.blocks.count, 1, "a code block is a single block")
        XCTAssertGreaterThan(long.blocks[0].frame.height, Self.viewport * 10,
                             "and far taller than a screen")

        let band = 0.0 ... Self.viewport
        var shortMs = 0.0, longMs = 0.0
        inBitmap { ctx in
            shortMs = bestMs { for _ in 0 ..< 20 { short.draw(in: ctx, clipY: band) } }
            longMs = bestMs { for _ in 0 ..< 20 { long.draw(in: ctx, clipY: band) } }
        }
        print(unsafe "DRAWTALL 200-line=\(String(format: "%.3f", shortMs))ms "
            + "2000-line=\(String(format: "%.3f", longMs))ms "
            + "ratio=\(String(format: "%.1f", longMs / max(shortMs, 0.0001)))x")

        // The same screenful of code is on screen either way, so the same
        // screenful of work should pay for it. Floor for a fast machine.
        XCTAssertLessThan(longMs, shortMs * 3 + 2.0,
                          "drawing a block costs more the taller the block is, not the screen")
    }

    // MARK: - Decorations spread over the whole document

    /// An editable view over `n` paragraphs of prose, scrolled to the middle.
    private func makeView(_ n: Int) -> EditorTextView {
        let editor = try! Editor(extensions: fullKit())
        let s = editor.schema
        let words = Array(repeating: "lorem ipsum dolor sit amet", count: 12).joined(separator: " ")
        let paras = (0 ..< n).map { i in
            try! s.node("paragraph", [:], content: Fragment.from([s.text("Para \(i): \(words)")]))
        }
        editor.setContent(try! s.node("doc", [:], content: Fragment.from(paras)))
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: Self.width, height: Self.viewport)
        // Off so the measurement is the decoration loop, not UITextChecker.
        view.spellCheckingEnabled = false
        view.layoutIfNeeded()
        let l = view.ensureLayout()
        _ = l.realize(window: 0 ... .greatestFiniteMagnitude)
        view.contentOffsetY = max((l.height - Self.viewport) / 2, 0)
        return view
    }

    private func drawFrames(_ view: EditorTextView, _ count: Int) {
        UIGraphicsBeginImageContextWithOptions(view.bounds.size, true, 1)
        defer { UIGraphicsEndImageContext() }
        for _ in 0 ..< count { view.draw(view.bounds) }
    }

    func testAFindAllDoesNotMultiplyTheCostOfAFrame() {
        // A plugin's decorations cover the whole document: a find-all with a
        // common query emits one per match. `draw` walked all of them every
        // frame, paying for a colour and a `selectionRects` call per match —
        // including matches hundreds of screens away. The screenful on show is
        // the same either way, so opening the find bar must not change what a
        // frame costs.
        let view = makeView(1000)
        let before = bestMs { drawFrames(view, 10) }

        let tr = view.editor.state.tr
        setSearchState(tr, SearchQuery(search: "lorem"))
        view.editor.dispatch(tr)
        _ = view.ensureLayout()
        let matches = getSearchQueryState(view.editor.state)?.deco.decorations.count ?? 0
        XCTAssertGreaterThan(matches, 5000, "the query should match across the whole document")
        let after = bestMs { drawFrames(view, 10) }

        print(unsafe "DRAWFIND matches=\(matches) "
            + "idle=\(String(format: "%.3f", before))ms find=\(String(format: "%.3f", after))ms "
            + "ratio=\(String(format: "%.1f", after / max(before, 0.0001)))x")

        // A handful of matches really are on screen and really are drawn, so
        // this is not asking for parity — only that the cost tracks the screen
        // rather than the document. The bound is loose because what is left is
        // one linear pass: `DecorationSet` is a flat array (by its own
        // admission), so asking it for a band still walks every decoration,
        // just with two integer compares each instead of a copy and a draw.
        // Unfixed, this ran ~7x the idle cost here and ~24x in release.
        XCTAssertLessThan(after, before * 5 + 5.0,
                          "a find-all makes every frame cost the whole document")
    }
}
#endif

#if canImport(UIKit) && PROSEKIT_BENCH
import XCTest
import UIKit
import DocumentModel
import SchemaKit
import EditorStateKit
@testable import EditorUIKit

/// A survey of the per-frame and per-keystroke paths, to find which of them
/// still scale with the document rather than the screen. Ranks candidates
/// before any of them is optimized — several plausible-looking linear scans
/// turn out to be noise, and the point is to tell those apart.
///
/// Compiled out by default; run in Release, as `DrawBench` documents.
@MainActor
final class HotPathProbe: XCTestCase {
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

    private func row(_ label: String, _ ms: Double) {
        unsafe print(String(format: "  %-46@ %8.3f ms", label as NSString, ms))
        unsafe fflush(stdout)
    }

    private func makeView(_ n: Int, taskList: Bool = false, spell: Bool = false) -> EditorTextView {
        let editor = try! Editor(extensions: fullKit())
        let s = editor.schema
        let words = Array(repeating: "lorem ipsum dolor sit amet", count: 12).joined(separator: " ")
        let doc: Node
        if taskList {
            let items = (0 ..< n).map { i -> Node in
                let p = try! s.node("paragraph", [:], content: Fragment.from([s.text("Task \(i): \(words)")]))
                return try! s.node("taskItem", ["checked": .bool(i % 2 == 0)], content: Fragment.from([p]))
            }
            doc = try! s.node("doc", [:], content: Fragment.from([
                try! s.node("taskList", [:], content: Fragment.from(items))]))
        } else {
            let paras = (0 ..< n).map { i in
                try! s.node("paragraph", [:], content: Fragment.from([s.text("Para \(i): \(words)")]))
            }
            doc = try! s.node("doc", [:], content: Fragment.from(paras))
        }
        editor.setContent(doc)
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: Self.width, height: Self.viewport)
        view.spellCheckingEnabled = spell
        view.layoutIfNeeded()
        let l = view.ensureLayout()
        _ = l.realize(window: 0 ... .greatestFiniteMagnitude)
        view.contentOffsetY = max((l.height - Self.viewport) / 2, 0)
        return view
    }

    /// One paragraph of `words` words (a wall of text), with the viewport
    /// spell pass already done so keystrokes hit the steady state.
    private func makeParagraphView(words: Int, spell: Bool) -> EditorTextView {
        let editor = try! Editor(extensions: fullKit())
        let s = editor.schema
        let vocabulary = ["lorem", "ipsum", "dolor", "sit", "amet", "consectetur", "adipiscing", "elit", "teh", "recieve"]
        let text = (0 ..< words).map { vocabulary[$0 % vocabulary.count] }.joined(separator: " ")
        let para = try! s.node("paragraph", [:], content: Fragment.from([s.text(text)]))
        editor.setContent(try! s.node("doc", [:], content: Fragment.from([para])))
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: Self.width, height: Self.viewport)
        view.spellCheckingEnabled = spell
        view.layoutIfNeeded()
        _ = view.ensureLayout()
        view.runSpellPassIfNeeded()
        return view
    }

    /// One scroll tick, as the host drives it: everything `contentOffsetY`'s
    /// setter fans out to, without a paint.
    private func scrollTicks(_ view: EditorTextView, _ count: Int) {
        var y = view.contentOffsetY
        for i in 0 ..< count {
            y += (i % 2 == 0) ? 4 : -4
            view.contentOffsetY = y
        }
    }

    func testScrollTickCost() {
        print("\n  --- one scroll tick (no paint) ---")
        for n in [200, 1000, 3000] {
            let view = makeView(n)
            row("\(n) paragraphs", bestMs { scrollTicks(view, 100) } / 100)
        }
        for n in [200, 1000, 3000] {
            let view = makeView(n, taskList: true)
            row("\(n) task items (checkbox overlay)", bestMs { scrollTicks(view, 100) } / 100)
        }
    }

    /// With the find bar open. Scrolling creates no transaction, so this
    /// isolates the per-frame decoration work from the per-edit rebuild below.
    func testScrollTickWithFindOpen() {
        print("\n  --- one scroll tick, find-all active ---")
        for n in [200, 1000, 3000] {
            let view = makeView(n)
            let tr = view.editor.state.tr
            setSearchState(tr, SearchQuery(search: "lorem"))
            view.editor.dispatch(tr)
            let matches = getSearchQueryState(view.editor.state)?.deco.decorations.count ?? 0
            row("\(n) paragraphs, \(matches) matches", bestMs { scrollTicks(view, 100) } / 100)
        }
    }

    /// Moving the cursor with the find bar open. The search plugin rebuilds its
    /// decorations on `selectionSet` as well as on `docChanged`, because which
    /// match is the *active* one depends on the selection.
    func testCursorMoveWithFindOpen() {
        print("\n  --- one cursor move (no edit) ---")
        for n in [200, 1000, 3000] {
            for searching in [false, true] {
                let view = makeView(n)
                if searching {
                    let tr = view.editor.state.tr
                    setSearchState(tr, SearchQuery(search: "lorem"))
                    view.editor.dispatch(tr)
                }
                let size = view.editor.doc.content.size
                var at = 4
                let ms = bestMs(5) {
                    for _ in 0 ..< 20 {
                        at = at >= size - 8 ? 4 : at + 2
                        view.editor.dispatch(view.editor.state.tr
                            .setSelection(TextSelection.create(view.editor.doc, at)))
                    }
                } / 20
                row("\(n) paragraphs, find \(searching ? "open" : "closed")", ms)
            }
        }
    }

    /// Typing with the find bar open, against typing without it.
    func testKeystrokeWithFindOpen() {
        print("\n  --- one keystroke ---")
        for n in [200, 1000, 3000] {
            for searching in [false, true] {
                let view = makeView(n)
                if searching {
                    let tr = view.editor.state.tr
                    setSearchState(tr, SearchQuery(search: "lorem"))
                    view.editor.dispatch(tr)
                }
                view.editor.dispatch(view.editor.state.tr
                    .setSelection(TextSelection.create(view.editor.doc, 4)))
                let ms = bestMs(5) { for _ in 0 ..< 20 { view.insertText("x") } } / 20
                row("\(n) paragraphs, find \(searching ? "open" : "closed")", ms)
            }
        }
    }

    /// Typing with spell checking on, against off. The edit re-checks spelling
    /// synchronously on every keystroke, so its cost should follow the word
    /// being typed — not the paragraph it is in, and not the document.
    func testKeystrokeSpellCheck() {
        print("\n  --- one keystroke, spell checking ---")
        for n in [200, 3000] {
            for spell in [false, true] {
                let view = makeView(n, spell: spell)
                view.contentOffsetY = 0
                view.runSpellPassIfNeeded()
                view.editor.dispatch(view.editor.state.tr
                    .setSelection(TextSelection.create(view.editor.doc, 4)))
                let ms = bestMs(5) { for _ in 0 ..< 20 { view.insertText("x") } } / 20
                row("\(n) short paragraphs, spell \(spell ? "on" : "off")", ms)
            }
        }
        for words in [60, 600, 3000] {
            for spell in [false, true] {
                let view = makeParagraphView(words: words, spell: spell)
                let mid = view.editor.doc.content.size / 2
                view.editor.dispatch(view.editor.state.tr
                    .setSelection(TextSelection.create(view.editor.doc, mid)))
                let ms = bestMs(5) { for _ in 0 ..< 20 { view.insertText("x") } } / 20
                row("one \(words)-word paragraph, spell \(spell ? "on" : "off")", ms)
            }
        }
    }
}
#endif

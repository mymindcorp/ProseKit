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

    private func makeView(_ n: Int, taskList: Bool = false) -> EditorTextView {
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
        view.spellCheckingEnabled = false
        view.layoutIfNeeded()
        let l = view.ensureLayout()
        _ = l.realize(window: 0 ... .greatestFiniteMagnitude)
        view.contentOffsetY = max((l.height - Self.viewport) / 2, 0)
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

    /// Where a keystroke's time goes, phase by phase: the bare transform and
    /// plugin pass (no view), the layout rebuild on its own, the whole view
    /// keystroke, and the paint that follows. Spell checking is on by default
    /// in the view, so it is measured both ways.
    func testKeystrokeBreakdown() {
        print("\n  --- one keystroke, by phase (edit near the top) ---")
        for n in [200, 1000, 3000] {
            // (a) Bare dispatch: transform + plugins + state, no view attached.
            let bare = try! Editor(extensions: fullKit())
            let s = bare.schema
            let words = Array(repeating: "lorem ipsum dolor sit amet", count: 12).joined(separator: " ")
            let paras = (0 ..< n).map { i in
                try! s.node("paragraph", [:], content: Fragment.from([s.text("Para \(i): \(words)")]))
            }
            bare.setContent(try! s.node("doc", [:], content: Fragment.from(paras)))
            bare.dispatch(bare.state.tr.setSelection(TextSelection.create(bare.doc, 40)))
            let dispatchMs = bestMs(5) {
                for _ in 0 ..< 20 {
                    let tr = bare.state.tr
                    _ = try? tr.insertText("x")
                    bare.dispatch(tr)
                }
            } / 20

            // (b) Layout alone: incremental rebuild of a fully-realized layout
            //     after replacing one paragraph near the top.
            let cache = TextBlockLayoutCache()
            var doc = bare.doc
            var layout = DocumentLayout(doc: doc, width: Self.width, theme: DocumentTheme(),
                                        blockCache: cache, realizeWindow: 0 ... Self.viewport)
            // The same rebuild before anything off screen has been realized —
            // the state a long document opens in, and stays in until the reader
            // scrolls through it. Estimated entries carry no arrays to shift.
            var lazyDoc = doc, lazyLayout = layout, lazyRound = 0
            let lazyMs = bestMs(5) {
                for _ in 0 ..< 5 {
                    lazyRound += 1
                    var children = (0 ..< lazyDoc.childCount).map { lazyDoc.child($0) }
                    children[2] = try! s.node("paragraph", [:], content: Fragment.from([s.text("lazy \(lazyRound) \(words)")]))
                    lazyDoc = try! s.node("doc", [:], content: Fragment.from(children))
                    lazyLayout = DocumentLayout(doc: lazyDoc, width: Self.width, theme: DocumentTheme(),
                                                blockCache: cache, previous: lazyLayout, realizeWindow: 0 ... Self.viewport)
                }
            } / 5
            row("\(n) paras: layout only, lazy (unscrolled)", lazyMs)
            row("\(n) paras: Node == over every child (diff's sweep)", bestMs(5) {
                let a = lazyDoc, b = doc
                for _ in 0 ..< 5 { for i in 0 ..< a.childCount { _ = a.child(i) == b.child(i) } }
            } / 5)
            row("\(n) paras: footnoteOrdering walk alone", bestMs(5) {
                for _ in 0 ..< 5 { _ = DocumentLayout.footnoteOrdering(lazyDoc) }
            } / 5)
            _ = layout.realize(window: 0 ... .greatestFiniteMagnitude)
            var round = 0
            let layoutMs = bestMs(5) {
                for _ in 0 ..< 5 {
                    round += 1
                    var children = (0 ..< doc.childCount).map { doc.child($0) }
                    children[2] = try! s.node("paragraph", [:], content: Fragment.from([s.text("edit \(round) \(words)")]))
                    doc = try! s.node("doc", [:], content: Fragment.from(children))
                    layout = DocumentLayout(doc: doc, width: Self.width, theme: DocumentTheme(),
                                            blockCache: cache, previous: layout, realizeWindow: 0 ... Self.viewport)
                }
            } / 5

            // (c) The whole view keystroke, spell checking off and on, and
            // (d) the paint that follows it.
            for spell in [false, true] {
                let view = makeView(n)
                view.spellCheckingEnabled = spell
                view.contentOffsetY = 0
                view.editor.dispatch(view.editor.state.tr.setSelection(TextSelection.create(view.editor.doc, 40)))
                _ = view.becomeFirstResponder()
                let keyMs = bestMs(5) { for _ in 0 ..< 20 { view.insertText("x") } } / 20
                let paintMs = bestMs(5) {
                    for _ in 0 ..< 5 {
                        view.insertText("x")
                        UIGraphicsBeginImageContextWithOptions(view.bounds.size, true, 1)
                        view.draw(view.bounds)
                        UIGraphicsEndImageContext()
                    }
                } / 5
                row("\(n) paras, spell \(spell ? "on " : "off"): dispatch", dispatchMs)
                row("\(n) paras, spell \(spell ? "on " : "off"): layout only", layoutMs)
                row("\(n) paras, spell \(spell ? "on " : "off"): view keystroke", keyMs)
                row("\(n) paras, spell \(spell ? "on " : "off"): keystroke + paint", paintMs)
            }
        }
    }
}
#endif

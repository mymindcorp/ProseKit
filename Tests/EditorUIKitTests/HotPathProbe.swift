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

    /// Typing inside a list. A list is a single top-level child, so the
    /// incremental layout's prefix/suffix reuse — which works per child —
    /// cannot help inside it; this measures what that costs as the list grows.
    func testKeystrokeInsideLists() {
        print("\n  --- one keystroke inside a list (item 3 of n) ---")
        let words = Array(repeating: "lorem ipsum dolor sit amet", count: 6).joined(separator: " ")
        for kind in ["bulletList", "orderedList", "taskList"] {
            for n in [200, 1000, 3000] {
                let editor = try! Editor(extensions: fullKit())
                let s = editor.schema
                let itemType = kind == "taskList" ? "taskItem" : "listItem"
                let items = (0 ..< n).map { i -> Node in
                    let p = try! s.node("paragraph", [:], content: Fragment.from([s.text("Item \(i): \(words)")]))
                    let attrs: Attrs = kind == "taskList" ? ["checked": .bool(i % 3 == 0)] : [:]
                    return try! s.node(itemType, attrs, content: Fragment.from([p]))
                }
                editor.setContent(try! s.node("doc", [:], content: Fragment.from([
                    try! s.node(kind, [:], content: Fragment.from(items))])))
                let view = EditorTextView(editor: editor)
                view.frame = CGRect(x: 0, y: 0, width: Self.width, height: Self.viewport)
                view.spellCheckingEnabled = false
                view.layoutIfNeeded()
                _ = view.ensureLayout()
                // Caret inside the third item's paragraph.
                let third = editor.doc.child(0)
                var pos = 1 // into the list
                for i in 0 ..< 2 { pos += third.child(i).nodeSize }
                pos += 2 + 4 // into item, into paragraph, after "Item"
                view.editor.dispatch(view.editor.state.tr.setSelection(TextSelection.create(view.editor.doc, pos)))
                _ = view.becomeFirstResponder()

                // Same schema instance: a node built by one editor's schema is
                // not a document for another's.
                let bare = try! Editor(extensions: fullKit())
                let bs = bare.schema
                let bareItems = (0 ..< n).map { i -> Node in
                    let p = try! bs.node("paragraph", [:], content: Fragment.from([bs.text("Item \(i): \(words)")]))
                    let attrs: Attrs = kind == "taskList" ? ["checked": .bool(i % 3 == 0)] : [:]
                    return try! bs.node(itemType, attrs, content: Fragment.from([p]))
                }
                bare.setContent(try! bs.node("doc", [:], content: Fragment.from([
                    try! bs.node(kind, [:], content: Fragment.from(bareItems))])))
                bare.dispatch(bare.state.tr.setSelection(TextSelection.create(bare.doc, pos)))
                let dispatchMs = bestMs(5) {
                    for _ in 0 ..< 10 { let tr = bare.state.tr; _ = try? tr.insertText("x"); bare.dispatch(tr) }
                } / 10
                let keyMs = bestMs(5) { for _ in 0 ..< 10 { view.insertText("x") } } / 10
                let paintMs = bestMs(5) {
                    for _ in 0 ..< 5 {
                        view.insertText("x")
                        UIGraphicsBeginImageContextWithOptions(view.bounds.size, true, 1)
                        view.draw(view.bounds)
                        UIGraphicsEndImageContext()
                    }
                } / 5
                row("\(kind) x\(n): dispatch", dispatchMs)
                row("\(kind) x\(n): view keystroke", keyMs)
                row("\(kind) x\(n): keystroke + paint", paintMs)
            }
        }
    }

    /// Typing inside the other containers that group many blocks under one
    /// top-level child — the shape that made lists 15x worse than paragraphs
    /// — and inside one very long paragraph, which is one block however long.
    func testKeystrokeInsideContainers() {
        print("\n  --- one keystroke inside a container ---")
        let words = Array(repeating: "lorem ipsum dolor sit amet", count: 6).joined(separator: " ")
        func para(_ s: Schema, _ t: String) -> Node {
            try! s.node("paragraph", [:], content: Fragment.from([s.text(t)]))
        }
        typealias Build = (Schema, Int) -> (doc: Node, caret: Int)
        let cases: [(String, [Int], Build)] = [
            ("blockquote of n paragraphs", [200, 1000, 3000], { s, n in
                let q = try! s.node("blockquote", [:], content: Fragment.from((0 ..< n).map { para(s, "Para \($0): \(words)") }))
                return (try! s.node("doc", [:], content: Fragment.from([q])), 1 + 1 + 4)
            }),
            ("open details of n paragraphs", [200, 1000, 3000], { s, n in
                let summary = try! s.node("detailsSummary", [:], content: Fragment.from([s.text("Summary")]))
                let content = try! s.node("detailsContent", [:], content: Fragment.from((0 ..< n).map { para(s, "Para \($0): \(words)") }))
                let d = try! s.node("details", ["open": .bool(true)], content: Fragment.from([summary, content]))
                return (try! s.node("doc", [:], content: Fragment.from([d])), 1 + summary.nodeSize + 1 + 1 + 4)
            }),
            ("table of n rows x 3 cells", [50, 200, 500], { s, n in
                let rows = (0 ..< n).map { r -> Node in
                    let cells = (0 ..< 3).map { c in
                        try! s.node("tableCell", [:], content: Fragment.from([para(s, "r\(r)c\(c) lorem ipsum dolor")]))
                    }
                    return try! s.node("tableRow", [:], content: Fragment.from(cells))
                }
                let t = try! s.node("table", [:], content: Fragment.from(rows))
                return (try! s.node("doc", [:], content: Fragment.from([t])), 1 + 1 + 1 + 1 + 2)
            }),
            ("nested list, n items x 10 sub-items", [20, 100, 300], { s, n in
                let items = (0 ..< n).map { i -> Node in
                    let subs = (0 ..< 10).map { j in
                        try! s.node("listItem", [:], content: Fragment.from([para(s, "Sub \(i).\(j): \(words)")]))
                    }
                    let inner = try! s.node("bulletList", [:], content: Fragment.from(subs))
                    return try! s.node("listItem", [:], content: Fragment.from([para(s, "Item \(i): \(words)"), inner]))
                }
                let l = try! s.node("bulletList", [:], content: Fragment.from(items))
                return (try! s.node("doc", [:], content: Fragment.from([l])), 1 + 1 + 1 + 4)
            }),
            ("one paragraph of n words", [500, 1500, 3000], { s, n in
                let text = (0 ..< n).map { "word\($0 % 97)" }.joined(separator: " ")
                return (try! s.node("doc", [:], content: Fragment.from([para(s, text)])), 1 + 4)
            }),
        ]
        for (label, sizes, build) in cases {
            for n in sizes {
                let editor = try! Editor(extensions: fullKit())
                let (doc, caret) = build(editor.schema, n)
                editor.setContent(doc)
                let view = EditorTextView(editor: editor)
                view.frame = CGRect(x: 0, y: 0, width: Self.width, height: Self.viewport)
                view.spellCheckingEnabled = false
                view.layoutIfNeeded()
                _ = view.ensureLayout()
                view.editor.dispatch(view.editor.state.tr.setSelection(TextSelection.create(view.editor.doc, caret)))
                _ = view.becomeFirstResponder()
                let ms = bestMs(5) {
                    for _ in 0 ..< 5 {
                        view.insertText("x")
                        UIGraphicsBeginImageContextWithOptions(view.bounds.size, true, 1)
                        view.draw(view.bounds)
                        UIGraphicsEndImageContext()
                    }
                } / 5
                row("\(label), n=\(n): keystroke + paint", ms)
            }
        }
    }

    /// Where a long paragraph's keystroke goes. One paragraph is one block, so
    /// a keystroke re-typesets all of it; this isolates the CoreText line
    /// breaking from everything around it, and tries the framesetter beside
    /// the typesetter, to see which part grows faster than the text does.
    ///
    /// What it found (2026-09): `CTTypesetterSuggestLineBreak` is linear in
    /// the whole string per call, so breaking a paragraph is quadratic — 38 ms
    /// at 3000 words, 152 at 6000, on every keystroke. The framesetter is the
    /// same. A forced embedding level, the usual remedy, is refused (nil)
    /// past a few thousand characters. Typesetting in chunks *is* linear —
    /// and the row below measures that — but it was built and reverted:
    /// CoreText's suggestion for a line depends on text thousands of
    /// characters after it (one first line: 2384 chars from a 4096- or
    /// 8192-char substring, 2376 from 16384 or the whole), so chunks change
    /// wraps — at every width from 800pt up for plain words — and chunk
    /// boundaries move as you type. Do not retry substring typesetting; the
    /// open route is reusing unchanged lines against the whole-string
    /// typesetter, which needs its own oracle test first.
    func testLongParagraphBreakdown() {
        print("\n  --- one long paragraph, by phase ---")
        let font = DocumentTheme().bodyFont
        for n in [500, 1500, 3000, 6000] {
            let text = (0 ..< n).map { "word\($0 % 97)" }.joined(separator: " ")
            let attributed = NSAttributedString(string: text, attributes: [.font: font])
            let width = Double(Self.width - 40)

            let typesetterMs = bestMs(3) {
                let ts = CTTypesetterCreateWithAttributedString(attributed as CFAttributedString)
                var start = 0, lines = 0
                let length = attributed.length
                while start < length {
                    var count = CTTypesetterSuggestLineBreak(ts, start, width)
                    if count <= 0 { count = length - start }
                    _ = CTTypesetterCreateLine(ts, CFRangeMake(start, count))
                    start += count; lines += 1
                }
            }
            let framesetterMs = bestMs(3) {
                let fs = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
                let path = unsafe CGPath(rect: CGRect(x: 0, y: 0, width: width, height: 1e6), transform: nil)
                let frame = CTFramesetterCreateFrame(fs, CFRangeMake(0, 0), path, nil)
                _ = CTFrameGetLines(frame) as! [CTLine]
            }
            // (a) Bidi analysis switched off: is that where the growth is?
            var forcedRefused = false
            let forcedMs = bestMs(3) {
                let opts = [kCTTypesetterOptionForcedEmbeddingLevel: 0 as CFNumber] as CFDictionary
                // Returns nil past some length — worth knowing on its own.
                guard let ts = CTTypesetterCreateWithAttributedStringAndOptions(attributed as CFAttributedString, opts)
                else { forcedRefused = true; return }
                var start = 0
                let length = attributed.length
                while start < length {
                    var count = CTTypesetterSuggestLineBreak(ts, start, width)
                    if count <= 0 { count = length - start }
                    _ = CTTypesetterCreateLine(ts, CFRangeMake(start, count))
                    start += count
                }
            }
            // (b) A fresh typesetter per chunk, each chunk starting at a line
            //     boundary the previous one produced.
            let chunkedMs = bestMs(3) {
                let length = attributed.length
                var start = 0
                while start < length {
                    let chunkLen = min(1500, length - start)
                    let chunk = attributed.attributedSubstring(from: NSRange(location: start, length: chunkLen))
                    let ts = CTTypesetterCreateWithAttributedString(chunk as CFAttributedString)
                    // Measurement only: the chunk edge cuts its last line short,
                    // which a real implementation would carry into the next
                    // chunk. The cost is what is being asked here.
                    var local = 0
                    while local < chunkLen {
                        var count = CTTypesetterSuggestLineBreak(ts, local, width)
                        if count <= 0 { count = chunkLen - local }
                        _ = CTTypesetterCreateLine(ts, CFRangeMake(local, count))
                        local += count
                    }
                    start += chunkLen
                }
            }
            let s = try! Editor(extensions: fullKit()).schema
            let doc = try! s.node("doc", [:], content: Fragment.from([
                try! s.node("paragraph", [:], content: Fragment.from([s.text(text)]))]))
            let layoutMs = bestMs(3) {
                _ = DocumentLayout(doc: doc, width: Self.width, theme: DocumentTheme())
            }
            row("\(n) words: CTTypesetter loop", typesetterMs)
            row("\(n) words: CTFramesetter frame", framesetterMs)
            row("\(n) words: typesetter, forced embedding level" + (forcedRefused ? " (REFUSED: nil)" : ""), forcedMs)
            row("\(n) words: typesetter, 1500-char chunks", chunkedMs)
            row("\(n) words: DocumentLayout cold", layoutMs)
        }
    }
}
#endif

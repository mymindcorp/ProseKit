#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import EditorStateKit
import SchemaKit
import DocumentTransform
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
        let full = DocumentLayout(doc: view.editor.doc, width: 320, theme: DocumentTheme())
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
                    _ = try? tr.delete(from, min(from + len, size - 1))
                } else {
                    let at = Int.random(in: 1...max(1, size - 1), using: &rng)
                    _ = try? tr.insertText(["a", "b ", "long word ", "x"].randomElement(using: &rng)!, at, at)
                }
                if tr.docChanged { editor.dispatch(tr) }
                assertMatchesFullRebuild(view, "seed \(seed) step \(step)")
            }
        }
    }
    /// A formula only produces a math target when a renderer is wired, and
    /// `EditorUIKit` cannot ship a default one (`EditorMath` depends on it, not
    /// the other way round). Without this the math-target emitter would sit
    /// silently untested.
    private static let guardMathRenderer: MathRenderer = { latex, display, _, _ in
        MathRendering(size: CGSize(width: CGFloat(latex.count) * 7, height: display ? 24 : 14),
                      ascent: display ? 18 : 11) { _, _ in }
    }

    /// A comparable projection of a drawing primitive: which kind it is, where
    /// it lands, and any text it carries. Rounded, because two layouts of the
    /// same content agree to well within a point.
    private func describe(_ d: DecorationItem) -> String {
        func r(_ rect: CGRect) -> String {
            "(\(rect.minX.rounded()),\(rect.minY.rounded()),\(rect.width.rounded()),\(rect.height.rounded()))"
        }
        switch d {
        case let .fill(rect, color): return "fill\(r(rect))\(colorKey(color))"
        case let .text(string, point, _): return "text[\(string)](\(point.x.rounded()),\(point.y.rounded()))"
        case let .stroke(rect, color, w): return "stroke\(r(rect))\(colorKey(color))\(w)"
        case let .image(_, rect): return "image\(r(rect))"
        case let .icon(_, rect): return "icon\(r(rect))"
        case let .math(_, rect): return "math\(r(rect))"
        case let .roundedFill(rect, color, radius): return "roundedFill\(r(rect))\(colorKey(color))\(radius)"
        case let .roundedStroke(rect, color, w, radius): return "roundedStroke\(r(rect))\(colorKey(color))\(w)\(radius)"
        case let .checkmark(rect, color, w): return "checkmark\(r(rect))\(colorKey(color))\(w)"
        }
    }

    /// A dynamic colour's `description` carries its object address, and
    /// `withAlphaComponent` mints a fresh one each call — so compare what it
    /// actually paints.
    private func colorKey(_ color: UIColor) -> String {
        let cg = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).cgColor
        let raw: [CGFloat] = cg.components ?? []
        let components = raw.map { "\((($0 * 1000).rounded() / 1000))" }
        return "\(cg.numberOfComponents):\(components.joined(separator: ","))"
    }

    private func rectKey(_ rect: CGRect) -> [CGFloat] {
        [rect.minX.rounded(), rect.minY.rounded(), rect.width.rounded(), rect.height.rounded()]
    }

    /// Every positioned thing the layout produces, compared against a rebuild
    /// from scratch — in full, not by identity alone.
    ///
    /// The narrow version of this check — block ranges and geometry only — is
    /// what let a cached block keep stale `segments` through a list deletion:
    /// the blocks lined up perfectly while the segments inside them pointed at
    /// the positions the items used to occupy, so the caret drew at the end of
    /// the line. Comparing a `pos` but not the `rect` beside it leaves the same
    /// door open, so everything here is compared whole.
    ///
    /// `pendingImages` is deliberately absent: it is a work list rather than
    /// positioned output, and reused entries legitimately don't re-emit it.
    private func assertFullyMatchesRebuild(_ view: EditorTextView, _ context: String) {
        let inc = view.ensureLayout()
        let full = DocumentLayout(doc: view.editor.doc, width: 320, theme: view.theme,
                                  mathRenderer: view.mathRenderer)

        XCTAssertEqual(inc.height, full.height, accuracy: 0.5, "height \(context)")
        XCTAssertEqual(inc.entries.map(\.docStart), full.entries.map(\.docStart), "entry docStarts \(context)")
        XCTAssertEqual(inc.entries.map { $0.topY.rounded() }, full.entries.map { $0.topY.rounded() },
                       "entry topYs \(context)")
        XCTAssertEqual(inc.entries.map { $0.height.rounded() }, full.entries.map { $0.height.rounded() },
                       "entry heights \(context)")

        XCTAssertEqual(inc.blocks.count, full.blocks.count, "block count \(context)")
        for i in 0..<min(inc.blocks.count, full.blocks.count) {
            let a = inc.blocks[i], b = full.blocks[i]
            XCTAssertEqual(a.contentStart, b.contentStart, "block \(i) contentStart \(context)")
            XCTAssertEqual(a.contentEnd, b.contentEnd, "block \(i) contentEnd \(context)")
            XCTAssertEqual(rectKey(a.frame), rectKey(b.frame), "block \(i) frame \(context)")
            XCTAssertEqual(a.attributed.string, b.attributed.string, "block \(i) text \(context)")
            // Lines, whole: the caret's x comes off the baseline origin and
            // `selectionRects` slices by the string range.
            XCTAssertEqual(a.lines.count, b.lines.count, "block \(i) line count \(context)")
            for (j, pair) in zip(a.lines, b.lines).enumerated() {
                XCTAssertEqual(pair.0.baselineOrigin.x.rounded(), pair.1.baselineOrigin.x.rounded(),
                               "block \(i) line \(j) baseline x \(context)")
                XCTAssertEqual(pair.0.baselineOrigin.y.rounded(), pair.1.baselineOrigin.y.rounded(),
                               "block \(i) line \(j) baseline y \(context)")
                XCTAssertEqual(pair.0.stringRange, pair.1.stringRange, "block \(i) line \(j) range \(context)")
                XCTAssertEqual(pair.0.height.rounded(), pair.1.height.rounded(), "block \(i) line \(j) height \(context)")
            }
            // Segments, whole — `docPos(forAttrIndex:)` reads `attrLen` and `text`.
            XCTAssertEqual(a.segments.map(\.docStart), b.segments.map(\.docStart), "block \(i) segment docStarts \(context)")
            XCTAssertEqual(a.segments.map(\.docLen), b.segments.map(\.docLen), "block \(i) segment docLens \(context)")
            XCTAssertEqual(a.segments.map(\.attrStart), b.segments.map(\.attrStart), "block \(i) segment attrStarts \(context)")
            XCTAssertEqual(a.segments.map(\.attrLen), b.segments.map(\.attrLen), "block \(i) segment attrLens \(context)")
            XCTAssertEqual(a.segments.map { $0.text ?? "<atom>" }, b.segments.map { $0.text ?? "<atom>" },
                           "block \(i) segment texts \(context)")
            // The answers themselves, both directions, rather than the parts.
            for pos in a.contentStart...a.contentEnd {
                XCTAssertEqual(a.attrIndex(forDocPos: pos), b.attrIndex(forDocPos: pos),
                               "block \(i) attrIndex(\(pos)) \(context)")
            }
            for index in 0...a.attributed.length {
                XCTAssertEqual(a.docPos(forAttrIndex: index), b.docPos(forAttrIndex: index),
                               "block \(i) docPos(\(index)) \(context)")
            }
        }

        // Ranges carry a color, and the color is what a highlight *is*.
        XCTAssertEqual(inc.highlights.map { "\($0.from)-\($0.to)-\(colorKey($0.color))" },
                       full.highlights.map { "\($0.from)-\($0.to)-\(colorKey($0.color))" }, "highlights \(context)")
        XCTAssertEqual(inc.codeBackgrounds.map { "\($0.from)-\($0.to)-\(colorKey($0.color))" },
                       full.codeBackgrounds.map { "\($0.from)-\($0.to)-\(colorKey($0.color))" }, "code backgrounds \(context)")
        // Hit targets: the rect is half the answer, so compare it too.
        XCTAssertEqual(inc.checkboxes.map { "\($0.pos)\(rectKey($0.rect))\($0.checked)" },
                       full.checkboxes.map { "\($0.pos)\(rectKey($0.rect))\($0.checked)" }, "checkboxes \(context)")
        XCTAssertEqual(inc.disclosures.map { "\($0.pos)\(rectKey($0.rect))\($0.open)" },
                       full.disclosures.map { "\($0.pos)\(rectKey($0.rect))\($0.open)" }, "disclosures \(context)")
        XCTAssertEqual(inc.mathTargets.map { "\($0.pos)\(rectKey($0.rect))" },
                       full.mathTargets.map { "\($0.pos)\(rectKey($0.rect))" }, "math targets \(context)")
        // Column geometry drives border hit-testing and resize.
        XCTAssertEqual(inc.tables.map { "\($0.tablePos)@\($0.originX.rounded())/\($0.widths.map { $0.rounded() })/\($0.top.rounded())-\($0.bottom.rounded())" },
                       full.tables.map { "\($0.tablePos)@\($0.originX.rounded())/\($0.widths.map { $0.rounded() })/\($0.top.rounded())-\($0.bottom.rounded())" },
                       "tables \(context)")
        // Everything drawn that isn't text in a block: markers, bars, rules,
        // badges, checkmarks, images, formulas — by position, not just count.
        XCTAssertEqual(inc.decorations.map(describe), full.decorations.map(describe), "decorations \(context)")

        for pos in 0...view.editor.doc.content.size {
            let x = inc.caretRect(at: pos), y = full.caretRect(at: pos)
            XCTAssertEqual(x?.minX ?? -1, y?.minX ?? -1, accuracy: 0.5, "caret x at \(pos) \(context)")
            XCTAssertEqual(x?.minY ?? -1, y?.minY ?? -1, accuracy: 0.5, "caret y at \(pos) \(context)")
        }
        // Selection geometry, which reads lines and segments by a different route.
        let size = view.editor.doc.content.size
        XCTAssertEqual(inc.selectionRects(from: 0, to: size).map(rectKey),
                       full.selectionRects(from: 0, to: size).map(rectKey), "selection rects \(context)")
    }

    /// A comparison between two empty arrays proves nothing, so pin that the
    /// document actually drives every emitter before trusting the equality above.
    private func assertExercisesEveryEmitter(_ layout: DocumentLayout) {
        XCTAssertFalse(layout.blocks.isEmpty, "no blocks")
        XCTAssertFalse(layout.decorations.isEmpty, "no decorations — list markers, bars and rules untested")
        XCTAssertFalse(layout.checkboxes.isEmpty, "no checkboxes — task items untested")
        XCTAssertFalse(layout.disclosures.isEmpty, "no disclosures — details untested")
        XCTAssertFalse(layout.mathTargets.isEmpty, "no math targets — inline math untested")
        XCTAssertFalse(layout.highlights.isEmpty, "no highlights — highlight marks untested")
        XCTAssertFalse(layout.codeBackgrounds.isEmpty, "no code backgrounds — inline code untested")
        XCTAssertFalse(layout.tables.isEmpty, "no tables — table geometry untested")
        XCTAssertTrue(layout.blocks.contains { $0.segments.contains { $0.text == nil } },
                      "no inline atom — the atom branch of attrIndex/docPos untested")
    }

    /// A document that exercises every emitter of positioned output: blocks and
    /// their segments, list markers and quote bars (decorations), task
    /// checkboxes, details disclosures, tables, math targets, and the highlight
    /// and inline-code backgrounds. If a node type isn't here, nothing checks
    /// that its output rebases when its block moves.
    private func richDoc(_ s: Schema) -> Node {
        func text(_ t: String, _ mark: String? = nil) -> Node {
            mark.map { s.text(t, [s.mark($0)]) } ?? s.text(t)
        }
        func p(_ kids: Node...) -> Node { try! s.node("paragraph", [:], content: Fragment.from(kids)) }
        func li(_ kids: Node...) -> Node { try! s.node("listItem", [:], content: Fragment.from(kids)) }
        func ti(_ t: String, _ checked: Bool) -> Node {
            try! s.node("taskItem", ["checked": .bool(checked)], content: Fragment.from([p(text(t))]))
        }
        func cell(_ t: String) -> Node {
            try! s.node("tableCell", [:], content: Fragment.from([p(text(t))]))
        }
        return try! s.node("doc", [:], content: Fragment.from([
            try! s.node("heading", ["level": .int(1)], content: Fragment.from([text("A title")])),
            p(text("intro paragraph with "), text("highlighted", "highlight"), text(" and "),
              text("code", "code"), text(" in it")),
            try! s.node("bulletList", [:], content: Fragment.from([
                li(p(text("first item"))),
                li(p(text("second item with "), text("a highlight", "highlight"))),
                li(p(text("third item")), try! s.node("bulletList", [:], content: Fragment.from([
                    li(p(text("nested one"))), li(p(text("nested two"))),
                ]))),
                li(p(text("fourth item with "), text("inline code", "code"))),
                li(p(text("fifth item")), p(text("and its second paragraph"))),
            ])),
            try! s.node("taskList", [:], content: Fragment.from([
                ti("task one", false), ti("task two", true), ti("task three", false),
            ])),
            try! s.node("orderedList", [:], content: Fragment.from([
                li(p(text("numbered one"))), li(p(text("numbered two"))),
            ])),
            try! s.node("blockquote", [:], content: Fragment.from([p(text("a quoted line"))])),
            try! s.node("codeBlock", ["language": .string("swift")],
                        content: Fragment.from([s.text("let x = 1\nprint(x)")])),
            try! s.node("details", [:], content: Fragment.from([
                try! s.node("detailsSummary", [:], content: Fragment.from([text("Summary line")])),
                try! s.node("detailsContent", [:], content: Fragment.from([p(text("hidden body"))])),
            ])),
            try! s.node("table", [:], content: Fragment.from([
                try! s.node("tableRow", [:], content: Fragment.from([cell("r1c1"), cell("r1c2")])),
                try! s.node("tableRow", [:], content: Fragment.from([cell("r2c1"), cell("r2c2")])),
            ])),
            p(text("paragraph with a formula "),
              try! s.node("inlineMath", ["latex": .string("x^2")], content: Fragment.empty),
              text(" after it")),
            p(text("a page mentioning "),
              try! s.node("wikiLink", ["target": .string("Some Page")], content: Fragment.empty),
              text(" mid-sentence")),
            p(text("outro paragraph")),
        ]))
    }

    /// Deleting a list item leaves every item below it an unchanged node at a
    /// new document position — the exact shape that makes the block cache serve
    /// a block built for somewhere else.
    func testStructuralEditsOnARichDocumentMatchFullRebuild() throws {
        for seed in UInt64(1)...12 {
            var rng = RNG(state: seed)
            let editor = try Editor(extensions: fullKit())
            editor.setContent(richDoc(editor.schema))
            let view = EditorTextView(editor: editor)
            view.mathRenderer = Self.guardMathRenderer
            // A styled wiki-link chip: its pill is a decoration positioned from
            // its run, so a reused block has to bring it along.
            var theme = DocumentTheme()
            theme.wikiLink.background = .secondarySystemFill
            view.theme = theme
            view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
            view.layoutIfNeeded()
            assertExercisesEveryEmitter(DocumentLayout(doc: editor.doc, width: 320, theme: view.theme,
                                                       mathRenderer: view.mathRenderer))
            assertFullyMatchesRebuild(view, "seed \(seed) initial")

            for step in 0..<12 {
                let size = editor.doc.content.size
                guard size > 8 else { break }
                // Ranged deletions, which is what removes whole list items and
                // shifts everything below them.
                let a = Int.random(in: 1..<size, using: &rng)
                let b = Int.random(in: 1..<size, using: &rng)
                let tr = editor.state.tr
                tr.setSelection(TextSelection.between(editor.doc.resolve(min(a, b)),
                                                      editor.doc.resolve(max(a, b))))
                _ = tr.deleteSelection()
                if tr.docChanged { editor.dispatch(tr) }
                _ = view.ensureLayout()
                assertFullyMatchesRebuild(view, "seed \(seed) step \(step)")
            }
        }
    }

    /// Past `lazyThreshold` top-level children the layout estimates what is off
    /// screen and realizes it on demand — a third reuse path, with its own
    /// mixture of shifted, realized and still-estimated entries. It typesets
    /// through the same block cache, so a block that failed to rebase would
    /// land here too.
    func testLazyLayoutRealizationMatchesFullRebuild() throws {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        func p(_ t: String) -> Node { try! s.node("paragraph", [:], content: Fragment.from([s.text(t)])) }
        func li(_ t: String) -> Node {
            try! s.node("listItem", [:], content: Fragment.from([p(t)]))
        }
        // Well past the lazy threshold, with lists interleaved so the reused
        // blocks are the repeated-node kind that moves position on a delete.
        var top: [Node] = []
        for i in 0..<40 {
            top.append(p("paragraph number \(i) with some text in it"))
            top.append(try! s.node("bulletList", [:], content: Fragment.from([
                li("list \(i) item one"), li("list \(i) item two"), li("list \(i) item three"),
            ])))
        }
        editor.setContent(try! s.node("doc", [:], content: Fragment.from(top)))

        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        view.layoutIfNeeded()
        XCTAssertTrue(view.ensureLayout().hasEstimatedContent, "expected a lazily estimated layout")

        // Delete a whole list item well inside the document, then realize the
        // region around it — the caret must still draw where it belongs.
        var itemStarts: [Int] = []
        editor.doc.descendants { node, pos, _, _ in
            if node.type.name == "listItem" { itemStarts.append(pos) }
            return true
        }
        let target = itemStarts[12]
        let tr = editor.state.tr
        _ = try? tr.delete(target, target + editor.doc.nodeAt(target)!.nodeSize)
        editor.dispatch(tr)

        let layout = view.ensureLayout()
        _ = layout.realize(aroundPos: target, viewportHeight: 480)
        _ = layout.realize(window: 0 ... .greatestFiniteMagnitude)

        let full = DocumentLayout(doc: editor.doc, width: 320, theme: DocumentTheme())
        XCTAssertEqual(layout.blocks.count, full.blocks.count, "block count after realization")
        for i in 0..<min(layout.blocks.count, full.blocks.count) {
            let a = layout.blocks[i], b = full.blocks[i]
            XCTAssertEqual(a.contentStart, b.contentStart, "block \(i) contentStart")
            XCTAssertEqual(a.segments.map(\.docStart), b.segments.map(\.docStart), "block \(i) segment docStarts")
            for pos in a.contentStart...a.contentEnd {
                XCTAssertEqual(a.attrIndex(forDocPos: pos), b.attrIndex(forDocPos: pos), "block \(i) attrIndex(\(pos))")
            }
        }
        XCTAssertEqual(layout.highlights.map { [$0.from, $0.to] }, full.highlights.map { [$0.from, $0.to] })
        XCTAssertEqual(layout.checkboxes.map(\.pos), full.checkboxes.map(\.pos))
    }
}
#endif

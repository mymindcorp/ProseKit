#if canImport(UIKit)
import XCTest
import DocumentModel
import DocumentTransform
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

@MainActor
final class HighlightRenderTests: XCTestCase {
    private func render(_ view: EditorTextView) -> UIImage {
        UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            view.layer.render(in: UIGraphicsGetCurrentContext()!)
        }
    }
    private func hasPixel(_ image: UIImage, _ predicate: (UInt8, UInt8, UInt8) -> Bool) -> Bool {
        guard let cg = image.cgImage else { return false }
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = unsafe CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        for i in stride(from: 0, to: data.count, by: 4) where predicate(data[i], data[i + 1], data[i + 2]) { return true }
        return false
    }

    private func view(highlightColor: String?) throws -> EditorTextView {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        var attrs: Attrs = [:]
        if let highlightColor { attrs["color"] = .string(highlightColor) }
        let mark = s.marks["highlight"]!.create(attrs)
        let para = try s.node("paragraph", [:], content: Fragment.from([
            s.text("plain "), s.text("HIGHLIGHTED", [mark]), s.text(" plain"),
        ]))
        editor.setContent(try s.node("doc", [:], content: Fragment.from([para])))
        let v = EditorTextView(editor: editor)
        v.frame = CGRect(x: 0, y: 0, width: 320, height: 120)
        v.backgroundColor = .white
        v.layoutIfNeeded()
        return v
    }

    func testDefaultHighlightRendersYellowBackground() throws {
        let image = render(try view(highlightColor: nil))
        // systemYellow @ 0.40 over white ≈ (255, 234, 153): bright, low-ish blue.
        XCTAssertTrue(hasPixel(image) { r, g, b in r > 235 && g > 205 && b < 195 && b < g },
                      "expected a yellow highlight background")
    }

    func testGreenHighlightRendersGreenBackground() throws {
        let image = render(try view(highlightColor: "green"))
        XCTAssertTrue(hasPixel(image) { r, g, b in g > 190 && g > r && g > b },
                      "expected a green highlight background")
    }

    func testNoHighlightNoColoredBackground() throws {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        editor.setContent(try s.node("doc", [:], content: Fragment.from([
            try s.node("paragraph", [:], content: Fragment.from([s.text("plain text only")])),
        ])))
        let v = EditorTextView(editor: editor)
        v.frame = CGRect(x: 0, y: 0, width: 320, height: 120)
        v.backgroundColor = .white
        v.layoutIfNeeded()
        let image = render(v)
        XCTAssertFalse(hasPixel(image) { r, g, b in r > 235 && g > 205 && b < 195 && b < g },
                       "no yellow background without a highlight")
    }

    private func markView(_ markName: String, _ color: String) throws -> EditorTextView {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        let mark = s.marks[markName]!.create(["color": .string(color)])
        editor.setContent(try s.node("doc", [:], content: Fragment.from([
            try s.node("paragraph", [:], content: Fragment.from([s.text("COLORED", [mark])])),
        ])))
        let v = EditorTextView(editor: editor)
        v.frame = CGRect(x: 0, y: 0, width: 320, height: 120)
        v.backgroundColor = .white
        v.layoutIfNeeded()
        return v
    }

    func testTextColorRendersForegroundColor() throws {
        let image = render(try markView("textColor", "#ff0000"))
        XCTAssertTrue(hasPixel(image) { r, g, b in r > 180 && g < 90 && b < 90 },
                      "text drawn in its red foreground color")
    }

    func testBackgroundColorPaintsBehindText() throws {
        let image = render(try markView("backgroundColor", "#00ff00"))
        XCTAssertTrue(hasPixel(image) { r, g, b in g > 180 && r < 120 && b < 120 },
                      "a green background painted behind the run")
    }

    private func codeView(language: String?) throws -> EditorTextView {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        var attrs: Attrs = [:]
        if let language { attrs["language"] = .string(language) }
        let code = try s.node("codeBlock", attrs, content: Fragment.from([s.text("let x = 1")]))
        editor.setContent(try s.node("doc", [:], content: Fragment.from([code])))
        let v = EditorTextView(editor: editor)
        v.frame = CGRect(x: 0, y: 0, width: 320, height: 120)
        v.backgroundColor = .white
        return v
    }

    func testSyntaxHighlighterColorsCodeBlockAndReceivesLanguage() throws {
        let v = try codeView(language: "swift")
        // Only colors when the language arrives as "swift" → red proves both the
        // hook ran and the language attribute was passed through.
        v.syntaxHighlighter = { _, lang in
            lang == "swift" ? [SyntaxToken(range: 0..<3, color: .systemRed)] : []
        }
        v.layoutIfNeeded()
        let image = render(v)
        XCTAssertTrue(hasPixel(image) { r, g, b in r > 150 && g < 110 && b < 110 },
                      "code-block token rendered in the highlighter's color")
    }

    func testNoSyntaxHighlighterLeavesCodePlain() throws {
        let v = try codeView(language: "swift")
        v.layoutIfNeeded()
        let image = render(v)
        XCTAssertFalse(hasPixel(image) { r, g, b in r > 150 && g < 110 && b < 110 },
                       "no red without a highlighter")
    }

    func testCodeLanguageBadgeAppearsWhenLabelProvided() throws {
        let v = try codeView(language: "swift")
        v.codeLanguageLabel = { _, language in language == nil ? nil : "Swift" }
        v.layoutIfNeeded()
        let decos = v.ensureLayout().decorations
        let hasBadge = decos.contains {
            if case let .text(str, _, _) = $0 { return str == "Swift" }
            return false
        }
        XCTAssertTrue(hasBadge, "a language badge is drawn for the code block")
    }

    func testNoBadgeWithoutLabelHook() throws {
        let v = try codeView(language: "swift")
        v.layoutIfNeeded()
        let decos = v.ensureLayout().decorations
        let hasBadge = decos.contains {
            if case let .text(str, _, _) = $0 { return str == "Swift" }
            return false
        }
        XCTAssertFalse(hasBadge, "no badge without a codeLanguageLabel hook")
    }

    // MARK: - Per-line runs

    func testAWrappedHighlightYieldsOneRunPerLineEachWithItsOwnRange() throws {
        // A highlight long enough to wrap, so the renderer sees several runs.
        let editor = try Editor(extensions: fullKit())
        let sc = editor.schema
        let mark = sc.marks["highlight"]!.create([:])
        let long = String(repeating: "wrap ", count: 40)
        let para = try sc.node("paragraph", [:], content: Fragment.from([sc.text(long, [mark])]))
        editor.setContent(try sc.node("doc", [:], content: Fragment.from([para])))
        let v = EditorTextView(editor: editor)
        v.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        v.layoutIfNeeded()

        var runs: [HighlightRun] = []
        v.highlightRenderer = { _, r in runs.append(contentsOf: r) }
        _ = UIGraphicsImageRenderer(bounds: v.bounds).image { _ in
            v.layer.render(in: UIGraphicsGetCurrentContext()!)
        }

        XCTAssertGreaterThan(runs.count, 1, "a wrapped highlight is drawn as several runs")
        // Every run reports the same whole-highlight identity...
        XCTAssertEqual(Set(runs.map(\.from)).count, 1)
        XCTAssertEqual(Set(runs.map(\.to)).count, 1)
        // ...but its own distinct slice, and the slices tile the highlight in order.
        XCTAssertEqual(Set(runs.map(\.lineFrom)).count, runs.count, "each run has its own start")
        for run in runs {
            XCTAssertLessThan(run.lineFrom, run.lineTo)
            XCTAssertGreaterThanOrEqual(run.lineFrom, run.from)
            XCTAssertLessThanOrEqual(run.lineTo, run.to)
        }
        let ordered = runs.sorted { $0.lineFrom < $1.lineFrom }
        XCTAssertEqual(ordered.first?.lineFrom, ordered.first?.from, "the first run starts the highlight")
        XCTAssertEqual(ordered.last?.lineTo, ordered.last?.to, "the last run ends it")
        for (a, b) in zip(ordered, ordered.dropFirst()) {
            XCTAssertLessThanOrEqual(a.lineTo, b.lineFrom, "slices advance without overlapping")
        }
    }

    func testAHighlightOnOneLineReportsTheWholeRangeAsItsLine() throws {
        let v = try view(highlightColor: nil)
        var runs: [HighlightRun] = []
        v.highlightRenderer = { _, r in runs.append(contentsOf: r) }
        _ = render(v)
        let run = try XCTUnwrap(runs.first)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(run.lineFrom, run.from)
        XCTAssertEqual(run.lineTo, run.to)
    }

    // MARK: - onDocumentChange (host-state mapping, the highlightRenderer companion)

    func testDocumentChangeHookDeliversAUsableMapping() throws {
        // A host recording "the highlighted range" before an edit above it should
        // be able to map that range onto the same text afterwards.
        let v = try view(highlightColor: nil)
        let highlighted = v.ensureLayout().highlights.first.map { ($0.from, $0.to) }
        let range = try XCTUnwrap(highlighted)

        var mapped: (Int, Int)?
        v.onDocumentChange = { tr in
            mapped = (tr.mapping.map(range.0, 1), tr.mapping.map(range.1, -1))
        }
        let tr = v.editor.state.tr
        try tr.insertText("XX", 1)
        v.editor.dispatch(tr)

        let after = try XCTUnwrap(mapped)
        XCTAssertEqual(after.0, range.0 + 2, "start shifts by the inserted length")
        XCTAssertEqual(after.1, range.1 + 2, "end shifts by the inserted length")
        // And the mapped range is where the highlight actually ended up.
        v.layoutIfNeeded()
        let now = try XCTUnwrap(v.ensureLayout().highlights.first)
        XCTAssertEqual(now.from, after.0)
        XCTAssertEqual(now.to, after.1)
    }

    func testDocumentChangeHookIgnoresSelectionOnlyTransactions() throws {
        let v = try view(highlightColor: nil)
        var fired = 0
        v.onDocumentChange = { _ in fired += 1 }

        let move = v.editor.state.tr
        move.setSelection(TextSelection.create(move.doc, 2))
        v.editor.dispatch(move)
        XCTAssertEqual(fired, 0, "moving the caret moves nothing to map")

        let edit = v.editor.state.tr
        try edit.insertText("X", 1)
        v.editor.dispatch(edit)
        XCTAssertEqual(fired, 1, "a document change does fire")
    }

    func testHighlightTracksTheWordAfterAnEditBefore() throws {
        // The highlight range maps with edits (incremental layout shifts it).
        let v = try view(highlightColor: nil)
        let tr = v.editor.state.tr
        try tr.insertText("XX", 1)
        v.editor.dispatch(tr)
        let image = render(v)
        XCTAssertTrue(hasPixel(image) { r, g, b in r > 235 && g > 205 && b < 195 && b < g },
                      "highlight still renders after an edit before it")
    }

    // MARK: - One highlight, one background

    private func paragraphView(_ inline: (Schema) throws -> [Node]) throws -> EditorTextView {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        editor.setContent(try s.node("doc", [:], content: Fragment.from([
            try s.node("paragraph", [:], content: Fragment.from(try inline(s))),
        ])))
        let v = EditorTextView(editor: editor)
        v.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        v.backgroundColor = .white
        v.layoutIfNeeded()
        return v
    }

    /// The pixel at a point of the view, as (r, g, b).
    private func pixel(_ image: UIImage, _ point: CGPoint) throws -> [UInt8] {
        let cg = try XCTUnwrap(image.cgImage)
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = try XCTUnwrap(unsafe CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                                 space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let i = (Int(point.y * image.scale) * w + Int(point.x * image.scale)) * 4
        return [data[i], data[i + 1], data[i + 2]]
    }

    func testABoldWordInsideAHighlightDoesNotCutIt() throws {
        let v = try paragraphView { s in
            let h = s.marks["highlight"]!.create([:]), b = s.marks["bold"]!.create([:])
            return [s.text("AAAA", [h]), s.text("BBBB", [b, h]), s.text("CCCC", [h])]
        }
        XCTAssertEqual(v.ensureLayout().highlights.map { [$0.from, $0.to] }, [[1, 13]])
        var runs: [HighlightRun] = []
        v.highlightRenderer = { _, r in runs.append(contentsOf: r) }
        _ = render(v)
        XCTAssertEqual(runs.map { [$0.from, $0.to, $0.lineFrom, $0.lineTo] }, [[1, 13, 1, 13]])
    }

    func testHighlightsOfDifferentColorsStaySeparate() throws {
        let v = try paragraphView { s in
            [s.text("AAAA", [s.marks["highlight"]!.create(["color": .string("yellow")])]),
             s.text("BBBB", [s.marks["highlight"]!.create(["color": .string("green")])])]
        }
        XCTAssertEqual(v.ensureLayout().highlights.count, 2)
    }

    func testAHighlightCoversTheAtomsInsideIt() throws {
        let v = try paragraphView { s in
            let h = s.marks["highlight"]!.create([:])
            return [s.text("one", [h]), try s.node("wikiLink", [:], content: .empty, marks: [h]),
                    s.text("two", [h])]
        }
        XCTAssertEqual(v.ensureLayout().highlights.map { [$0.from, $0.to] }, [[1, 8]])
    }

    func testWrappedLinesDoNotPaintADarkStripeBetweenThem() throws {
        let v = try paragraphView { s in
            [s.text(String(repeating: "wrap ", count: 40), [s.marks["highlight"]!.create([:])])]
        }
        let layout = v.ensureLayout()
        let h = try XCTUnwrap(layout.highlights.first)
        let rects = layout.selectionRects(from: h.from, to: h.to)
        XCTAssertGreaterThan(rects.count, 1)
        let image = render(v)
        // "wrap" has a descender, but the seam's row and the line's top are both
        // clear of glyphs, so they should show the same single coat of ink.
        let x = rects[0].midX
        let seam = try pixel(image, CGPoint(x: x, y: rects[0].maxY))
        let band = try pixel(image, CGPoint(x: x, y: rects[0].minY + 0.5))
        XCTAssertEqual(seam, band, "the overlap between two lines must not paint twice")
    }

    func testABackgroundColorMarkStaysOutOfTheHostRenderer() throws {
        let v = try paragraphView { s in
            let bg = s.marks["backgroundColor"]!.create(["color": .string("#00ff00")])
            return [s.text("back", [bg]), s.text(" high", [s.marks["highlight"]!.create([:])])]
        }
        var runs: [HighlightRun] = []
        v.highlightRenderer = { _, r in runs.append(contentsOf: r) }
        let image = render(v)
        XCTAssertEqual(runs.map { [$0.from, $0.to] }, [[5, 10]], "only the highlight mark is the host's to draw")
        XCTAssertTrue(hasPixel(image) { r, g, b in g > 180 && r < 120 && b < 120 },
                      "the background color still paints, as a flat fill")
    }

    func testABackgroundColorUnderAHighlightStillPaints() throws {
        let v = try paragraphView { s in
            [s.text("both", [s.marks["backgroundColor"]!.create(["color": .string("#00ff00")]),
                             s.marks["highlight"]!.create([:])])]
        }
        XCTAssertEqual(v.ensureLayout().highlights.map(\.isHighlight), [false, true])
    }

    // MARK: - Right-to-left

    /// Each case is (before, highlighted, after); widths are from the plain run
    /// measured alone, so a zero-width rect can't pass.
    func testAHighlightCoversRightToLeftTextWhereverItSits() throws {
        let cases: [(String, String, String)] = [
            ("abc ", "אבג דהו", " def"),   // a whole Hebrew run in Latin text
            ("abc ", "مرحبا", " def"),     // and Arabic
            ("אבג ", "abc", " דהו"),       // Latin inside Hebrew
            ("", "אבג דהו", ""),           // a wholly right-to-left paragraph
            ("אבג ", "דהו", " זחט"),       // a word inside one
        ]
        for (before, marked, after) in cases {
            let v = try paragraphView { s in
                var nodes: [Node] = []
                if !before.isEmpty { nodes.append(s.text(before)) }
                nodes.append(s.text(marked, [s.marks["highlight"]!.create([:])]))
                if !after.isEmpty { nodes.append(s.text(after)) }
                return nodes
            }
            let layout = v.ensureLayout()
            let h = try XCTUnwrap(layout.highlights.first)
            let rects = layout.selectionRects(from: h.from, to: h.to)
            let plain = (marked as NSString).size(withAttributes: [.font: v.theme.bodyFont]).width
            guard rects.count == 1 else { XCTFail("\(before)|\(marked)|\(after): \(rects)"); continue }
            XCTAssertEqual(rects[0].width, plain, accuracy: 2, "\(before)|\(marked)|\(after)")
        }
    }

    func testARangeAcrossADirectionChangeIsPaintedInBothPieces() throws {
        // Logical "bc אב" of "abc אבג": the Hebrew's first two letters sit at its
        // right, so `ג` between them and the Latin stays unpainted.
        let v = try paragraphView { s in
            [s.text("a"), s.text("bc אב", [s.marks["highlight"]!.create([:])]), s.text("ג")]
        }
        let layout = v.ensureLayout()
        let h = try XCTUnwrap(layout.highlights.first)
        let rects = layout.selectionRects(from: h.from, to: h.to)
        guard rects.count == 2 else { return XCTFail("expected two pieces, got \(rects)") }
        XCTAssertTrue(rects.allSatisfy { $0.width > 0 })
        XCTAssertGreaterThan(rects[1].minX, rects[0].maxX, "a gap for the unmarked letter between them")
    }

    func testRightToLeftRunsReportTheirOwnSliceToTheRenderer() throws {
        let v = try paragraphView { s in
            [s.text("abc "), s.text("אבג", [s.marks["highlight"]!.create([:])]), s.text(" def")]
        }
        var runs: [HighlightRun] = []
        v.highlightRenderer = { _, r in runs.append(contentsOf: r) }
        _ = render(v)
        XCTAssertEqual(runs.map { [$0.lineFrom, $0.lineTo] }, [[5, 8]])
        XCTAssertGreaterThan(try XCTUnwrap(runs.first).rect.width, 1)
    }

    // MARK: - Imported colors

    func testAHighlightFromAnotherEditorPaintsItsOwnColor() throws {
        for color in ["#ff0000", "rgb(255, 0, 0)"] {
            let v = try paragraphView { s in
                [s.text("IMPORTED", [s.marks["highlight"]!.create(["color": .string(color)])])]
            }
            XCTAssertTrue(hasPixel(render(v)) { r, g, b in r > 200 && g < 60 && b < 60 }, color)
        }
    }

    func testAHighlighterNameTheThemeLacksStillFallsBack() {
        let theme = DocumentTheme()
        for name in ["brand-2", "chartreuse", "beef"] {
            XCTAssertEqual(theme.highlightColor(name), theme.highlightColor(nil), name)
        }
    }
}
#endif

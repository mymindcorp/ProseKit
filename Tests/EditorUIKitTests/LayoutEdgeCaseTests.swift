#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import SchemaKit
@testable import EditorUIKit

/// `DocumentLayout` on the inputs the everyday suites don't reach: positions
/// past the end, blocks that are only estimated, a cache over its cap, a
/// formula that doesn't parse, lines that end in a hard break.
@MainActor
final class LayoutEdgeCaseTests: XCTestCase {
    private lazy var schema: Schema = try! Editor(extensions: fullKit()).schema

    private func paragraph(_ text: String) -> Node {
        try! schema.node("paragraph", [:], content: Fragment.from(text.isEmpty ? [] : [schema.text(text)]))
    }
    private func doc(_ children: [Node]) -> Node {
        try! schema.node("doc", [:], content: Fragment.from(children))
    }
    /// Enough paragraphs to clear the lazy-layout threshold (60 children).
    private func filler(_ n: Int = 80) -> [Node] {
        (0 ..< n).map { paragraph("Filler paragraph \($0) with a few words in it.") }
    }

    // MARK: - Mapping a position past every segment

    func testAPositionPastEverySegmentMapsToTheEndOfTheString() {
        let segments = [
            Segment(docStart: 0, docLen: 3, attrStart: 0, attrLen: 3, text: "abc"),
            Segment(docStart: 3, docLen: 1, attrStart: 3, attrLen: 2, text: nil), // an atom drawn as 2 glyphs
        ]
        XCTAssertEqual(attrIndex(forDocPos: 10, in: segments), 5, "clamped to the end of the last segment")
        XCTAssertEqual(attrIndex(forDocPos: 3, in: []), 0, "an empty block maps everything to 0")
    }

    // MARK: - The block cache

    func testEvictDropsOnlyTheBlocksAndItemsWhoseNodeMatches() {
        let cache = TextBlockLayoutCache()
        let item = try! schema.node("listItem", [:], content: Fragment.from([paragraph("drop")]))
        let d = doc([paragraph("keep"), try! schema.node("bulletList", [:], content: Fragment.from([item]))])
        _ = DocumentLayout(doc: d, width: 320, theme: DocumentTheme(), blockCache: cache)
        XCTAssertEqual(cache.debugEntryCount, 2, "one block per paragraph")
        XCTAssertEqual(cache.debugItemCount, 1, "one list item")

        cache.evict { $0.textContent == "drop" }
        XCTAssertEqual(cache.debugEntryCount, 1, "the item's paragraph went, the other stayed")
        XCTAssertEqual(cache.debugItemCount, 0, "the list item holding it went too")
    }

    func testOverTheCapTheOlderHalfIsDroppedAndRecentBlocksSurvive() {
        let cache = TextBlockLayoutCache()
        let theme = DocumentTheme()
        let old = (0 ..< 2100).map { paragraph("old \($0)") }
        let recent = (0 ..< 2100).map { paragraph("recent \($0)") }
        _ = DocumentLayout(doc: doc(old), width: 320, theme: theme, blockCache: cache)
        XCTAssertEqual(cache.debugEntryCount, 2100)
        // A second pass takes the cache to 4200, over the 4096 cap.
        let recentDoc = doc(recent)
        _ = DocumentLayout(doc: recentDoc, width: 320, theme: theme, blockCache: cache)
        XCTAssertEqual(cache.debugEntryCount, 2100, "the older generation was dropped")

        // The survivors are the recent ones: laying them out again adds nothing…
        _ = DocumentLayout(doc: recentDoc, width: 320, theme: theme, blockCache: cache)
        XCTAssertEqual(cache.debugEntryCount, 2100)
        // …while the old ones have to be typeset and stored afresh.
        _ = DocumentLayout(doc: doc(Array(old.prefix(50))), width: 320, theme: theme, blockCache: cache)
        XCTAssertEqual(cache.debugEntryCount, 2150)
    }

    func testListItemsOverTheCapAreEvictedByGeneration() {
        let cache = TextBlockLayoutCache()
        let theme = DocumentTheme()
        func list(_ prefix: String) -> Node {
            let items = (0 ..< 2100).map { i in
                try! schema.node("listItem", [:], content: Fragment.from([paragraph("\(prefix) \(i)")]))
            }
            return doc([try! schema.node("bulletList", [:], content: Fragment.from(items))])
        }
        _ = DocumentLayout(doc: list("old"), width: 320, theme: theme, blockCache: cache)
        XCTAssertEqual(cache.debugItemCount, 2100)
        _ = DocumentLayout(doc: list("new"), width: 320, theme: theme, blockCache: cache)
        XCTAssertEqual(cache.debugItemCount, 2100, "the older half of 4200 items was dropped")
    }

    // MARK: - Estimated blocks

    /// The height an eager layout gives the last top-level child of `d`.
    private func realizedLastHeight(_ d: Node, theme: DocumentTheme = DocumentTheme()) throws -> CGFloat {
        try XCTUnwrap(DocumentLayout(doc: d, width: 390, theme: theme).entries.last).height
    }

    func testAnEstimatedRuleIsExactlyAsTallAsARealizedOne() throws {
        let d = doc(filler() + [try schema.node("horizontalRule")])
        let lazy = DocumentLayout(doc: d, width: 390, theme: DocumentTheme(), realizeWindow: 0 ... 200)
        let entry = try XCTUnwrap(lazy.entries.last)
        XCTAssertTrue(entry.estimated)
        XCTAssertEqual(entry.height, try realizedLastHeight(d), accuracy: 0.01)
    }

    func testAnEstimatedCodeBlockCountsItsPadding() throws {
        var theme = DocumentTheme()
        theme.code.block.padding = EmInsets(2.0) // 2em a side: far more than a line
        let code = try schema.node("codeBlock", [:], content: Fragment.from([schema.text("x = 1")]))
        let d = doc(filler() + [code])
        let lazy = DocumentLayout(doc: d, width: 390, theme: theme, realizeWindow: 0 ... 200)
        let entry = try XCTUnwrap(lazy.entries.last)
        XCTAssertTrue(entry.estimated)
        let padding = theme.points(theme.code.block.padding)
        XCTAssertGreaterThan(entry.height, padding.top + padding.bottom, "the padding is in the estimate")
        XCTAssertEqual(entry.height, try realizedLastHeight(d, theme: theme), accuracy: 2)
    }

    func testAnEstimatedHeadingCountsItsRule() throws {
        var theme = DocumentTheme()
        theme.heading.rule = DocumentTheme.Heading.Rule(thickness: 10, spacing: .points(20))
        let heading = try schema.node("heading", ["level": .int(1)], content: Fragment.from([schema.text("Title")]))
        let d = doc(filler() + [heading])
        let lazy = DocumentLayout(doc: d, width: 390, theme: theme, realizeWindow: 0 ... 200)
        let entry = try XCTUnwrap(lazy.entries.last)
        XCTAssertTrue(entry.estimated)
        // Leaving the 30pt rule out would miss by more than the tolerance.
        XCTAssertEqual(entry.height, try realizedLastHeight(d, theme: theme), accuracy: 5)
    }

    func testRelayingAnImageShiftsTheEstimatedBlocksBelowIt() throws {
        var bytes: UIImage?
        let image = try schema.node("image", ["src": .string("asset://late")])
        let d = doc([image] + filler())
        let layout = DocumentLayout(doc: d, width: 390, theme: DocumentTheme(),
                                    imageProvider: { _ in bytes }, realizeWindow: 0 ... 300)
        let before = layout.entries
        let lastBefore = try XCTUnwrap(before.last)
        XCTAssertTrue(lastBefore.estimated)

        bytes = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 400)).image { _ in }
        XCTAssertTrue(layout.relayoutImages(matching: { $0.attrs["src"]?.stringValue == "asset://late" }))

        let grew = layout.entries[0].height - before[0].height
        XCTAssertGreaterThan(grew, 0, "the image now lays out at its own size")
        let lastAfter = try XCTUnwrap(layout.entries.last)
        XCTAssertTrue(lastAfter.estimated, "an estimated block stays estimated")
        XCTAssertEqual(lastAfter.height, lastBefore.height, accuracy: 0.01)
        XCTAssertEqual(lastAfter.topY - lastBefore.topY, grew, accuracy: 0.5, "and moves down by what the image grew")
        XCTAssertEqual(layout.height - lastAfter.topY - lastAfter.height,
                       DocumentTheme().pageInsets.bottom, accuracy: 0.5)
    }

    func testAPositionPastTheEndRealizesTheLastBlock() throws {
        let d = doc(filler(200))
        let layout = DocumentLayout(doc: d, width: 390, theme: DocumentTheme(), realizeWindow: 0 ... 300)
        let past = d.content.size + 50
        XCTAssertTrue(layout.isEstimated(pos: d.content.size - 3), "the end is still estimated")
        XCTAssertFalse(layout.isEstimated(pos: past), "no block holds a position past the end")
        XCTAssertTrue(layout.realize(aroundPos: past, viewportHeight: 300))
        XCTAssertFalse(try XCTUnwrap(layout.entries.last).estimated, "the last block is typeset now")
    }

    // MARK: - A stray list item

    func testAListItemOutsideAListStillLaysOutItsText() throws {
        // Not a valid document, but `create` doesn't validate content, so an
        // importer can hand the renderer one. Its text must still be drawn.
        for name in ["listItem", "taskItem"] {
            let item = try schema.node(name, [:], content: Fragment.from([paragraph("stray")]))
            let layout = DocumentLayout(doc: doc([item]), width: 320, theme: DocumentTheme())
            let block = try XCTUnwrap(layout.blocks.first, name)
            XCTAssertEqual(block.attributed.string, "stray", name)
            XCTAssertEqual(block.contentStart, 2, "inside the item and its paragraph")
        }
    }

    // MARK: - Math

    func testAFormulaThatDoesNotParseIsRedrawnInTheCodeColor() throws {
        var colors: [UIColor] = []
        var widths: [CGFloat] = [30, 42]
        let renderer: MathRenderer = { _, _, _, color in
            colors.append(color)
            return MathRendering(size: CGSize(width: widths.removeFirst(), height: 10), ascent: 8,
                                 isError: true) { _, _ in }
        }
        let theme = DocumentTheme()
        let d = doc([try schema.node("blockMath", ["latex": .string("\\frac{a")])])
        let layout = DocumentLayout(doc: d, width: 320, theme: theme, mathRenderer: renderer)
        XCTAssertEqual(colors, [theme.textColor, theme.code.color], "typeset once, then again in the code color")
        let drawn = layout.decorations.compactMap { item -> CGRect? in
            if case let .math(_, rect) = item { return rect }
            return nil
        }
        XCTAssertEqual(drawn.map(\.width), [42], "the recolored rendering is the one drawn")
    }

    func testIfTheRecolorFailsTheFirstRenderingIsKept() throws {
        var calls = 0
        let renderer: MathRenderer = { _, _, _, _ in
            calls += 1
            guard calls == 1 else { return nil }
            return MathRendering(size: CGSize(width: 30, height: 10), ascent: 8, isError: true) { _, _ in }
        }
        let d = doc([try schema.node("blockMath", ["latex": .string("\\frac{a")])])
        let layout = DocumentLayout(doc: d, width: 320, theme: DocumentTheme(), mathRenderer: renderer)
        XCTAssertEqual(calls, 2)
        let widths = layout.decorations.compactMap { item -> CGFloat? in
            if case let .math(_, rect) = item { return rect.width }
            return nil
        }
        XCTAssertEqual(widths, [30])
    }

    func testMathHitTestingAnswersOnlyOverAFormula() throws {
        let renderer: MathRenderer = { _, _, _, _ in
            MathRendering(size: CGSize(width: 40, height: 20), ascent: 15) { _, _ in }
        }
        let d = doc([paragraph("above"), try schema.node("blockMath", ["latex": .string("x")])])
        let layout = DocumentLayout(doc: d, width: 320, theme: DocumentTheme(), mathRenderer: renderer)
        let target = try XCTUnwrap(layout.mathTargets.first)
        XCTAssertEqual(layout.math(at: CGPoint(x: target.rect.midX, y: target.rect.midY)), 7)
        XCTAssertNil(layout.math(at: CGPoint(x: target.rect.maxX + 50, y: target.rect.midY)))
        XCTAssertNil(layout.math(at: CGPoint(x: 5, y: 5)), "not over the paragraph above it")
    }

    // MARK: - Syntax tokens that restyle the face

    func testBoldAndItalicTokensRestyleTheMonoFace() throws {
        let highlighter: SyntaxHighlighter = { _, _ in
            [SyntaxToken(range: 0 ..< 3, bold: true), SyntaxToken(range: 4 ..< 7, italic: true)]
        }
        let code = try schema.node("codeBlock", [:], content: Fragment.from([schema.text("let foo")]))
        let theme = DocumentTheme()
        let layout = DocumentLayout(doc: doc([code]), width: 320, theme: theme, syntaxHighlighter: highlighter)
        let attributed = try XCTUnwrap(layout.blocks.first).attributed
        func traits(at i: Int) -> UIFontDescriptor.SymbolicTraits {
            (unsafe attributed.attribute(.font, at: i, effectiveRange: nil) as? UIFont)?.fontDescriptor.symbolicTraits ?? []
        }
        XCTAssertTrue(traits(at: 0).contains(.traitBold), "`let` is bold")
        XCTAssertFalse(traits(at: 3).contains(.traitBold), "the space after it is not")
        XCTAssertEqual((unsafe attributed.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?.pointSize,
                       theme.monoFont.pointSize, "at the mono size")
        if theme.monoFont.fontDescriptor.withSymbolicTraits(.traitItalic) != nil {
            XCTAssertTrue(traits(at: 4).contains(.traitItalic), "`foo` is italic")
        }
    }

    // MARK: - Tables and vertical movement

    func testLeavingAColumnWithNoCellUnderTheCaretPicksTheNearestCell() throws {
        func cell(_ text: String) -> Node {
            try! schema.node("tableCell", [:], content: Fragment.from([paragraph(text)]))
        }
        func row(_ cells: [Node]) -> Node { try! schema.node("tableRow", [:], content: Fragment.from(cells)) }
        let table = try schema.node("table", [:], content: Fragment.from([
            row([cell("a"), cell("b")]), row([cell("c"), cell("d")]),
        ]))
        let layout = DocumentLayout(doc: doc([table]), width: 320, theme: DocumentTheme())
        func cellText(at pos: Int) -> String? { layout.blockContaining(pos)?.attributed.string }
        let a = try XCTUnwrap(layout.blocks.first { $0.attributed.string == "a" }).contentStart

        // A preferred column far right of every cell: the right-hand cell below.
        let right = try XCTUnwrap(layout.verticalPosition(from: a, up: false, preferredX: 10_000))
        XCTAssertEqual(cellText(at: right), "d")
        // Far left of every cell: the left-hand one.
        let left = try XCTUnwrap(layout.verticalPosition(from: a, up: false, preferredX: -10_000))
        XCTAssertEqual(cellText(at: left), "c")
    }

    // MARK: - Lines ending in a hard break

    /// "ab⏎cd": the break is at 3, "c" starts the second line at 4.
    private func hardBreakLayout() throws -> DocumentLayout {
        let p = try schema.node("paragraph", [:], content: Fragment.from([
            schema.text("ab"), try schema.node("hardBreak"), schema.text("cd"),
        ]))
        return DocumentLayout(doc: doc([p]), width: 320, theme: DocumentTheme())
    }

    func testEndOfLineStopsBeforeAHardBreak() throws {
        let layout = try hardBreakLayout()
        XCTAssertEqual(layout.lineBoundary(from: 2, toEnd: true), 3, "before the break, not past it")
        XCTAssertEqual(layout.lineBoundary(from: 2, toEnd: false), 1)
        XCTAssertEqual(layout.lineBoundary(from: 5, toEnd: true), 6, "the last line has no break to stop at")
    }

    func testATapPastTheEndOfALineEndingInABreakLandsBeforeIt() throws {
        let layout = try hardBreakLayout()
        let caret = try XCTUnwrap(layout.caretRect(at: 2))
        let pos = layout.position(at: CGPoint(x: 300, y: caret.midY))
        XCTAssertEqual(pos, 3, "the position the caret at the end of the line is drawn at")
        XCTAssertEqual(layout.caretRect(at: 3)?.minY ?? -1, caret.minY, accuracy: 0.5, "on the tapped line")
    }

    // MARK: - Node-selection rects for block atoms

    func testARuleSelectsAsItsWholeRow() throws {
        let d = doc([paragraph("a"), try schema.node("horizontalRule"), paragraph("b")])
        let layout = DocumentLayout(doc: d, width: 320, theme: DocumentTheme())
        let entry = layout.entries[1]
        XCTAssertEqual(layout.blockAtomRect(at: entry.docStart),
                       CGRect(x: 0, y: entry.topY, width: 320, height: entry.height))
        XCTAssertNil(layout.blockAtomRect(at: 0), "a paragraph is not a block atom")
    }
}
#endif

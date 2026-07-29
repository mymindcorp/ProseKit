#if canImport(UIKit)
import XCTest
import DocumentModel
import EditorStateKit
import SchemaKit
import EditorMath
import EditorStateKit
@testable import EditorUIKit

@MainActor
final class MathRenderTests: XCTestCase {
    /// A document with an inline formula in a sentence, then a block formula.
    private func mathView(renderer: MathRenderer? = makeMathRenderer()) throws -> EditorTextView {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        let paragraph = try s.node("paragraph", [:], content: Fragment.from([
            s.text("let "),
            try s.node("inlineMath", ["latex": .string("x^2")]),
            s.text(" be it"),
        ]))
        let block = try s.node("blockMath", ["latex": .string("\\frac{a}{b}")])
        editor.setContent(try s.node("doc", [:], content: Fragment.from([paragraph, block])))
        let view = EditorTextView(editor: editor)
        view.mathRenderer = renderer
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        view.layoutIfNeeded()
        return view
    }

    /// The document position of the first node of the given type.
    private func position(of name: String, in view: EditorTextView) throws -> Int {
        var found: Int?
        view.editor.doc.descendants { node, pos, _, _ in
            if found == nil, node.type.name == name { found = pos }
            return found == nil
        }
        return try XCTUnwrap(found, "no \(name) in the document")
    }

    // MARK: - Layout

    func testBothFormulasProduceMathDecorations() throws {
        let view = try mathView()
        var count = 0
        for decoration in view.ensureLayout().decorations {
            if case .math = decoration { count += 1 }
        }
        XCTAssertEqual(count, 2, "one decoration each for the inline and block formula")
    }

    func testABlockFormulaTakesVerticalSpace() throws {
        let view = try mathView()
        let entry = try XCTUnwrap(view.ensureLayout().entries.last)
        XCTAssertEqual(entry.node.type.name, "blockMath")
        XCTAssertGreaterThan(entry.height, 10, "a display fraction is taller than a bare line")
    }

    func testAnInlineFormulaSharesTheLineBaseline() throws {
        let view = try mathView()
        let layout = view.ensureLayout()
        let block = try XCTUnwrap(layout.blocks.first)
        let line = try XCTUnwrap(block.lines.first)
        var mathRect: CGRect?
        for decoration in layout.decorations {
            if case let .math(rendering, rect) = decoration, rect.minY < line.baselineOrigin.y {
                // The inline one: its baseline must land on the line's baseline.
                XCTAssertEqual(rect.minY + rendering.ascent, line.baselineOrigin.y, accuracy: 0.5)
                mathRect = rect
                break
            }
        }
        XCTAssertNotNil(mathRect, "the inline formula was laid out on the first line")
    }

    func testAnInlineFormulaReservesRoomInTheLine() throws {
        // The run delegate must widen the line; without it the text would
        // overlap the formula.
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        func doc(_ inline: [Node]) throws -> Node {
            try s.node("doc", [:], content: Fragment.from([
                try s.node("paragraph", [:], content: Fragment.from(inline)),
            ]))
        }
        let view = EditorTextView(editor: editor)
        view.mathRenderer = makeMathRenderer()
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)

        editor.setContent(try doc([s.text("ab")]))
        view.layoutIfNeeded()
        let bare = try XCTUnwrap(view.ensureLayout().blocks.first).lines.first!.ctLine
        let bareWidth = CTLineGetTypographicBounds(bare, nil, nil, nil)

        editor.setContent(try doc([
            s.text("a"), try s.node("inlineMath", ["latex": .string("x^2")]), s.text("b"),
        ]))
        view.layoutIfNeeded()
        let withMath = try XCTUnwrap(view.ensureLayout().blocks.first).lines.first!.ctLine
        XCTAssertGreaterThan(CTLineGetTypographicBounds(withMath, nil, nil, nil), bareWidth + 4)
    }

    func testWithoutARendererTheSourceIsShownInstead() throws {
        let view = try mathView(renderer: nil)
        let layout = view.ensureLayout()
        for decoration in layout.decorations {
            if case .math = decoration { XCTFail("no renderer should mean no math decorations") }
        }
        // The inline formula falls back to its `$…$` source in the text run.
        XCTAssertTrue(layout.blocks.contains { $0.attributed.string.contains("$x^2$") })
    }

    func testUnparseableSourceStillRendersAndIsMarkedAnError() throws {
        let renderer = makeMathRenderer()
        let rendering = try XCTUnwrap(renderer("\\frac{a}", false, UIFont.systemFont(ofSize: 17), .label))
        XCTAssertTrue(rendering.isError)
        XCTAssertGreaterThan(rendering.size.width, 0, "the verbatim source is still drawn")
    }

    // MARK: - The renderer's cache

    func testTheSameFormulaAtTwoSizesRendersAtTwoSizes() throws {
        // Laid-out formulas are cached, so the key has to include the font size.
        // A key that didn't would serve the first size for every later one, and
        // every formula in the document would be the wrong size but consistent
        // — which is exactly the kind of bug that looks like a theme problem.
        let renderer = makeMathRenderer()
        let small = try XCTUnwrap(renderer("x^2", false, UIFont.systemFont(ofSize: 12), .label))
        let large = try XCTUnwrap(renderer("x^2", false, UIFont.systemFont(ofSize: 36), .label))
        XCTAssertGreaterThan(large.size.width, small.size.width * 2)
        XCTAssertGreaterThan(large.ascent, small.ascent)
    }

    func testDisplayAndInlineOfTheSameSourceDifferAndDontShareACacheEntry() throws {
        let renderer = makeMathRenderer()
        let font = UIFont.systemFont(ofSize: 17)
        let inline = try XCTUnwrap(renderer("\\sum_{i=1}^{n} i", false, font, .label))
        let display = try XCTUnwrap(renderer("\\sum_{i=1}^{n} i", true, font, .label))
        XCTAssertGreaterThan(display.size.height, inline.size.height,
                             "display style stacks the limits; the two can't share an entry")
    }

    func testRepeatingAFormulaGivesTheSameGeometry() throws {
        // The cached result has to be usable as-is, since a second occurrence of
        // a formula is laid out from the cache rather than re-typeset.
        let renderer = makeMathRenderer()
        let font = UIFont.systemFont(ofSize: 17)
        let first = try XCTUnwrap(renderer("\\frac{a}{b}", true, font, .label))
        for _ in 0..<5 {
            let again = try XCTUnwrap(renderer("\\frac{a}{b}", true, font, .label))
            XCTAssertEqual(again.size.width, first.size.width, accuracy: 0.001)
            XCTAssertEqual(again.size.height, first.size.height, accuracy: 0.001)
            XCTAssertEqual(again.ascent, first.ascent, accuracy: 0.001)
        }
    }

    func testTheColourIsNotCachedWithTheGeometry() throws {
        // Colour is resolved when drawing, so light and dark share one entry —
        // a theme switch must not need a re-layout.
        let renderer = makeMathRenderer()
        let font = UIFont.systemFont(ofSize: 17)
        let dark = try XCTUnwrap(renderer("x^2", false, font, .white))
        let light = try XCTUnwrap(renderer("x^2", false, font, .black))
        XCTAssertEqual(dark.size, light.size, "same geometry regardless of colour")
    }

    func testDeletingBackwardOverAnInlineFormulaRemovesIt() throws {
        // The formula is an atom, so there is no caret position inside it to
        // delete into character by character.
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        editor.setContent(try s.node("doc", [:], content: Fragment.from([
            try s.node("paragraph", [:], content: Fragment.from([
                s.text("ab"), try s.node("inlineMath", ["latex": .string("x^2")]),
            ])),
        ])))
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        view.layoutIfNeeded()
        // Put the caret directly after the formula.
        let end = editor.doc.content.size - 1
        editor.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.doc, end)))

        view.deleteBackward()
        var stillThere = false
        editor.doc.descendants { node, _, _, _ in
            if node.type.name == "inlineMath" { stillThere = true }
            return true
        }
        XCTAssertFalse(stillThere, "the formula went")
        XCTAssertEqual(editor.doc.child(0).textContent, "ab", "and took nothing else with it")
    }

    // MARK: - Activation (Tiptap's onClick)

    func testTappingAFormulaHitTestsToItsPosition() throws {
        let view = try mathView()
        let layout = view.ensureLayout()
        XCTAssertEqual(layout.mathTargets.count, 2)
        for target in layout.mathTargets {
            let hit = layout.math(at: CGPoint(x: target.rect.midX, y: target.rect.midY))
            XCTAssertEqual(hit, target.pos)
            let node = try XCTUnwrap(view.editor.doc.nodeAt(target.pos))
            XCTAssertTrue(["inlineMath", "blockMath"].contains(node.type.name))
        }
    }

    func testActivationHandsTheNodeAndPositionToTheHost() throws {
        let view = try mathView()
        var seen: [(name: String, latex: String, pos: Int)] = []
        view.onActivateMath = { node, pos in
            seen.append((node.type.name, node.attrs["latex"]?.stringValue ?? "", pos))
        }
        let inlinePos = try position(of: "inlineMath", in: view)
        view.activateMathForTesting(at: inlinePos)
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen[0].name, "inlineMath")
        XCTAssertEqual(seen[0].latex, "x^2")
        XCTAssertEqual(seen[0].pos, inlinePos)

        let blockPos = try position(of: "blockMath", in: view)
        view.activateMathForTesting(at: blockPos)
        XCTAssertEqual(seen.count, 2)
        XCTAssertEqual(seen[1].name, "blockMath")
        XCTAssertEqual(seen[1].latex, "\\frac{a}{b}")
    }

    func testActivationSelectsTheNodeSoUpdateAddressesIt() throws {
        // Tiptap's documented flow is `setNodeSelection(pos).updateInlineMath(…)`;
        // activation must leave the selection where a position-less update lands
        // on the tapped formula.
        let view = try mathView()
        view.onActivateMath = { _, _ in }
        let pos = try position(of: "inlineMath", in: view)
        view.activateMathForTesting(at: pos)
        XCTAssertEqual((view.editor.state.selection as? NodeSelection)?.from, pos)
        XCTAssertTrue(view.editor.updateInlineMath(latex: "y^3"))
        XCTAssertEqual(view.editor.doc.nodeAt(pos)?.attrs["latex"], .string("y^3"))
    }

    func testActivationIgnoresPositionsThatArentMath() throws {
        let view = try mathView()
        var called = false
        view.onActivateMath = { _, _ in called = true }
        view.activateMathForTesting(at: 1) // inside the leading text run
        XCTAssertFalse(called)
    }

    func testTheTapGestureOnlyClaimsFormulasWhenAHandlerIsSet() throws {
        let view = try mathView()
        let target = try XCTUnwrap(view.ensureLayout().mathTargets.first)
        let point = CGPoint(x: target.rect.midX, y: target.rect.midY)
        XCTAssertNil(view.mathNodePosition(at: point).flatMap { _ in view.onActivateMath })
        view.onActivateMath = { _, _ in }
        XCTAssertEqual(view.mathNodePosition(at: point), target.pos)
    }

    func testHitTargetsFollowAnEditAboveThem() throws {
        // The targets are shifted with their entries by the incremental layout,
        // so they must still address the right node after text is inserted.
        let view = try mathView()
        let before = try position(of: "blockMath", in: view)
        let tr = view.editor.state.tr
        try tr.insertText("much longer prefix ", 1)
        view.editor.dispatch(tr)
        view.layoutIfNeeded()
        let after = try position(of: "blockMath", in: view)
        XCTAssertGreaterThan(after, before)
        let target = try XCTUnwrap(view.ensureLayout().mathTargets.first { $0.pos == after })
        XCTAssertEqual(view.ensureLayout().math(at: CGPoint(x: target.rect.midX, y: target.rect.midY)), after)
    }

    func testInlineTargetsAreCorrectWhenTwoIdenticalFormulasShareADocument() throws {
        // Identical nodes can share a cached typeset block, so an inline
        // formula's document position has to be derived from where the block
        // actually sits — not baked into the cache entry.
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        func para() throws -> Node {
            try s.node("paragraph", [:], content: Fragment.from([
                s.text("x"), try s.node("inlineMath", ["latex": .string("a^2")]),
            ]))
        }
        let shared = try para()
        editor.setContent(try s.node("doc", [:], content: Fragment.from([shared, shared])))
        let view = EditorTextView(editor: editor)
        view.mathRenderer = makeMathRenderer()
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        view.layoutIfNeeded()

        let layout = view.ensureLayout()
        XCTAssertEqual(layout.mathTargets.count, 2)
        XCTAssertNotEqual(layout.mathTargets[0].pos, layout.mathTargets[1].pos,
                          "the two formulas are at different positions")
        for target in layout.mathTargets {
            XCTAssertEqual(view.editor.doc.nodeAt(target.pos)?.type.name, "inlineMath",
                           "target at \(target.pos) should address a formula")
        }
    }
}
#endif

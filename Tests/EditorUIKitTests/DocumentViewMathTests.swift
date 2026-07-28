#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import SchemaKit
import EditorMath
@testable import EditorUIKit

/// The read-only renderer's math hook.
///
/// `DocumentView` shares the layout engine with the editable view, so it can
/// draw formulas — it just had no way to be told how. Without the hook a
/// preview, thumbnail or feed row shows raw LaTeX where the maths should be.
@MainActor
final class DocumentViewMathTests: XCTestCase {
    private func mathDocument() throws -> Node {
        let s = try Editor(extensions: fullKit()).schema
        return try s.node("doc", [:], content: Fragment.from([
            try s.node("paragraph", [:], content: Fragment.from([
                s.text("let "), try s.node("inlineMath", ["latex": .string("x^2")]), s.text(" be"),
            ])),
            try s.node("blockMath", ["latex": .string("\\frac{a}{b}")]),
        ]))
    }

    private func view(renderer: MathRenderer?) throws -> DocumentView {
        let view = DocumentView(document: try mathDocument())
        view.mathRenderer = renderer
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        view.layoutIfNeeded()
        return view
    }

    private func mathDecorations(_ view: DocumentView) throws -> Int {
        var count = 0
        for decoration in try XCTUnwrap(view.ensureLayout()).decorations {
            if case .math = decoration { count += 1 }
        }
        return count
    }

    func testWithoutAHookFormulasFallBackToTheirSource() throws {
        let view = try view(renderer: nil)
        XCTAssertEqual(try mathDecorations(view), 0)
        let text = try XCTUnwrap(view.ensureLayout()).blocks.map(\.attributed.string).joined()
        XCTAssertTrue(text.contains("$x^2$"), "the inline formula shows its source: \(text)")
    }

    func testTheHookTypesetsBothInlineAndBlockFormulas() throws {
        let view = try view(renderer: makeMathRenderer())
        XCTAssertEqual(try mathDecorations(view), 2, "one each for the inline and block formula")
    }

    func testSettingTheHookLaterRetypesetsWhatWasAlreadyLaidOut() throws {
        // An inline formula is baked into its paragraph's cached block, so this
        // only works if setting the hook drops that cache.
        let view = try view(renderer: nil)
        XCTAssertEqual(try mathDecorations(view), 0)
        view.mathRenderer = makeMathRenderer()
        XCTAssertEqual(try mathDecorations(view), 2, "the cached paragraph was re-typeset")
    }

    func testABlockFormulaTakesVerticalSpace() throws {
        let plain = try XCTUnwrap(try view(renderer: nil).ensureLayout()).height
        let typeset = try XCTUnwrap(try view(renderer: makeMathRenderer()).ensureLayout()).height
        XCTAssertNotEqual(plain, typeset, "a typeset display fraction isn't one line of text")
    }
}
#endif

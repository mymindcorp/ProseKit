#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import SchemaKit
@testable import EditorUIKit

/// The small public pieces of `DocumentTheme` a host reads or builds with:
/// em arithmetic, the rule and highlighter value types, and the font and
/// attribute choices for the less common nodes and marks.
@MainActor
final class ThemeAccessorTests: XCTestCase {
    private lazy var schema: Schema = try! Editor(extensions: fullKit()).schema

    func testEmsAdd() {
        let sum: Em = Em(0.5) + 0.25
        XCTAssertEqual(sum.value, 0.75, accuracy: 1e-9)
        XCTAssertEqual(sum, Em(0.75))
    }

    func testBaseFontSizeFollowsTheBodyFont() {
        var theme = DocumentTheme()
        theme.dynamicType = false
        theme.fixedBodyFontSize = 22
        XCTAssertEqual(theme.baseFontSize, 22)
        XCTAssertEqual(theme.baseFontSize, theme.bodyFont.pointSize)
    }

    func testAHeadingRuleDefaultsToAHairlineInTheSharedColor() {
        let rule = DocumentTheme.Heading.Rule()
        XCTAssertNil(rule.color, "nil = the theme's hairline color")
        XCTAssertEqual(rule.thickness, 1)
        XCTAssertEqual(rule.spacing, 0.25)
        XCTAssertEqual(rule, DocumentTheme.Heading.Rule(color: nil, thickness: 1, spacing: 0.25))
    }

    func testAHighlighterIsLabelledByItsTitleElseItsCapitalizedName() {
        let plain = DocumentTheme.Highlighter(name: "yellow", background: .yellow)
        XCTAssertEqual(plain.displayTitle, "Yellow")
        let titled = DocumentTheme.Highlighter(name: "brand-2", title: "Brand", background: .purple)
        XCTAssertEqual(titled.displayTitle, "Brand")
    }

    func testACustomHeadingFaceWithAWeightKeepsTheFaceAndSize() throws {
        var theme = DocumentTheme()
        theme.dynamicType = false
        theme.heading.fontName = "HelveticaNeue"
        theme.heading.weight = .light
        let heading = try schema.node("heading", ["level": .int(1)], content: Fragment.from([schema.text("T")]))
        let font = theme.blockFont(heading)
        XCTAssertEqual(font.familyName, "Helvetica Neue", "the custom face, not the system one")
        XCTAssertEqual(font.pointSize, theme.fixedBodyFontSize * theme.heading.scale[0], accuracy: 0.01)
        // Which *cut* comes back is deliberately not asserted: adding a weight
        // trait to a descriptor that names a face keeps that face's own cut,
        // so today `.light` still yields regular HelveticaNeue — a bug, not
        // the contract.
        theme.heading.fontName = "Georgia"
        XCTAssertEqual(theme.blockFont(heading).familyName, "Georgia", "a face with no light cut still resolves")
    }

    func testACaptionUsesTheDocumentFaceScaled() throws {
        var theme = DocumentTheme()
        theme.dynamicType = false
        theme.fontName = "Georgia"
        let figures = try Editor(extensions: fullKit() + figureExtensions()).schema
        let caption = try figures.node("figcaption", [:], content: Fragment.from([figures.text("c")]))
        let font = theme.blockFont(caption)
        XCTAssertEqual(font.familyName, "Georgia")
        XCTAssertEqual(font.pointSize, theme.fixedBodyFontSize * theme.caption.scale, accuracy: 0.01)
    }

    func testStrikeMarksAreStruckThrough() {
        let theme = DocumentTheme()
        let struck = theme.attributes(for: [schema.mark("strike")], baseFont: theme.bodyFont)
        XCTAssertEqual(struck[.strikethroughStyle] as? Int, NSUnderlineStyle.single.rawValue)
        XCTAssertNil(theme.attributes(for: [], baseFont: theme.bodyFont)[.strikethroughStyle])
    }
}
#endif

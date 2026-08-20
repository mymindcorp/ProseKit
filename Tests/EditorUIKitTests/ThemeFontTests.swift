#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import SchemaKit
@testable import EditorUIKit

@MainActor
final class ThemeFontTests: XCTestCase {
    private func heading(_ level: Int) -> Node {
        let schema = try! Editor(extensions: starterKit()).schema
        return try! schema.node("heading", ["level": .int(level)], content: Fragment.from([schema.text("x")]))
    }
    private func paragraph() -> Node {
        let schema = try! Editor(extensions: starterKit()).schema
        return try! schema.node("paragraph", [:], content: Fragment.from([schema.text("x")]))
    }

    func testDefaultUsesSystemFont() {
        let theme = DocumentTheme()
        XCTAssertTrue(theme.bodyFont.familyName.contains("System") || theme.bodyFont.fontName.hasPrefix("."),
                      "default body font should be the system font")
    }

    func testCustomBodyFontIsApplied() {
        var theme = DocumentTheme()
        theme.dynamicType = false
        theme.fontName = "Georgia"
        XCTAssertEqual(theme.bodyFont.familyName, "Georgia")
        XCTAssertEqual(theme.bodyFont.pointSize, theme.fixedBodyFontSize, accuracy: 0.01)
        // Headings use the same family, bolded and scaled.
        let h1 = theme.blockFont(heading(1))
        XCTAssertEqual(h1.familyName, "Georgia")
        XCTAssertGreaterThan(h1.pointSize, theme.bodyFont.pointSize)
        XCTAssertTrue(h1.fontDescriptor.symbolicTraits.contains(.traitBold))
        // Body paragraphs use the custom family too.
        XCTAssertEqual(theme.blockFont(paragraph()).familyName, "Georgia")
    }

    func testHeadingFaceOverridesBodyFace() {
        var theme = DocumentTheme()
        theme.dynamicType = false
        theme.fontName = "Georgia"
        theme.heading.fontName = "Avenir Next"
        XCTAssertEqual(theme.bodyFont.familyName, "Georgia")
        XCTAssertEqual(theme.blockFont(heading(1)).familyName, "Avenir Next")
        // Body blocks keep the document face.
        XCTAssertEqual(theme.blockFont(paragraph()).familyName, "Georgia")
    }

    func testHeadingFaceAppliesOverSystemBodyFont() {
        var theme = DocumentTheme()
        theme.dynamicType = false
        theme.heading.fontName = "Georgia"
        let h2 = theme.blockFont(heading(2))
        XCTAssertEqual(h2.familyName, "Georgia")
        XCTAssertEqual(h2.pointSize, theme.fixedBodyFontSize * theme.heading.scale[1], accuracy: 0.01)
    }

    func testUnavailableHeadingFaceFallsBackToBodyFace() {
        var theme = DocumentTheme()
        theme.dynamicType = false
        theme.fontName = "Georgia"
        theme.heading.fontName = "ThisFontDoesNotExist-XYZ"
        // Falls through to the document face rather than all the way to system.
        XCTAssertEqual(theme.blockFont(heading(1)).familyName, "Georgia")
    }

    func testHeadingScaleDrivesSize() {
        var theme = DocumentTheme()
        theme.dynamicType = false
        theme.fontName = "Georgia"
        theme.heading.scale[0] = 3
        XCTAssertEqual(theme.blockFont(heading(1)).pointSize,
                       theme.fixedBodyFontSize * 3, accuracy: 0.01)
    }

    func testShortHeadingScaleFallsBackToBodySize() {
        var theme = DocumentTheme()
        theme.dynamicType = false
        theme.fontName = "Georgia"
        theme.heading.scale = [2]  // levels 2…6 unspecified
        XCTAssertEqual(theme.blockFont(heading(1)).pointSize,
                       theme.fixedBodyFontSize * 2, accuracy: 0.01)
        XCTAssertEqual(theme.blockFont(heading(4)).pointSize,
                       theme.fixedBodyFontSize, accuracy: 0.01)
    }

    func testHeadingLineHeightMultipliesAndBodyStillAdds() {
        var theme = DocumentTheme()
        theme.lineSpacing = 5
        // Unset: a heading leads like any other block.
        XCTAssertEqual(theme.lineHeight(for: heading(1), naturalHeight: 40), 45, accuracy: 0.01)
        XCTAssertEqual(theme.lineHeight(for: paragraph(), naturalHeight: 20), 25, accuracy: 0.01)
        // Set: the heading multiplies its natural height instead.
        theme.heading.lineHeight = 0.9
        XCTAssertEqual(theme.lineHeight(for: heading(1), naturalHeight: 40), 36, accuracy: 0.01)
        // Body text is unaffected.
        XCTAssertEqual(theme.lineHeight(for: paragraph(), naturalHeight: 20), 25, accuracy: 0.01)
    }

    func testCustomMonoFontIsApplied() {
        var theme = DocumentTheme()
        theme.code.fontName = "Courier New"
        XCTAssertEqual(theme.monoFont.familyName, "Courier New")
    }

    func testInvalidFontNameFallsBackToSystem() {
        var theme = DocumentTheme()
        theme.fontName = "ThisFontDoesNotExist-XYZ"
        // Falls back to the system font rather than crashing or returning nil.
        XCTAssertGreaterThan(theme.bodyFont.pointSize, 0)
    }
}
#endif

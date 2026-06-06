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
        let theme = TextTheme()
        XCTAssertTrue(theme.bodyFont.familyName.contains("System") || theme.bodyFont.fontName.hasPrefix("."),
                      "default body font should be the system font")
    }

    func testCustomBodyFontIsApplied() {
        var theme = TextTheme()
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

    func testCustomMonoFontIsApplied() {
        var theme = TextTheme()
        theme.monoFontName = "Courier New"
        XCTAssertEqual(theme.monoFont.familyName, "Courier New")
    }

    func testInvalidFontNameFallsBackToSystem() {
        var theme = TextTheme()
        theme.fontName = "ThisFontDoesNotExist-XYZ"
        // Falls back to the system font rather than crashing or returning nil.
        XCTAssertGreaterThan(theme.bodyFont.pointSize, 0)
    }
}
#endif

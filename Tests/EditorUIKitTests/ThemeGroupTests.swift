#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

/// The nested `link` / `code` / `quote` / `selection` groups, and the hairline
/// that used to be spelled `quoteBarColor` everywhere.
@MainActor
final class ThemeGroupTests: XCTestCase {
    private lazy var editor: Editor = try! Editor(extensions: fullKit())
    private var schema: Schema { editor.schema }

    /// A theme pinned to the size ems are authored against, so `.points(n)`
    /// resolves to exactly n and geometry can be asserted in plain points.
    private func referenceTheme() -> DocumentTheme {
        var theme = DocumentTheme()
        theme.dynamicType = false
        theme.fixedBodyFontSize = DocumentTheme.referenceBodySize
        return theme
    }

    private func text(_ s: String) -> Node { schema.text(s) }

    // MARK: - Link

    func testLinkColorAndUnderline() {
        var theme = referenceTheme()
        theme.link.color = .systemPurple
        let mark = schema.marks["link"]!.create(["href": .string("https://example.com")])
        var attrs = theme.attributes(for: [mark], baseFont: theme.bodyFont)
        XCTAssertEqual(attrs[.foregroundColor] as? UIColor, .systemPurple)
        XCTAssertEqual(attrs[.underlineStyle] as? Int, NSUnderlineStyle.single.rawValue)
        // Off gives color-only links.
        theme.link.underline = false
        attrs = theme.attributes(for: [mark], baseFont: theme.bodyFont)
        XCTAssertNil(attrs[.underlineStyle])
    }

    // MARK: - Code

    func testCodeFaceAndColor() {
        var theme = referenceTheme()
        theme.code.fontName = "Courier New"
        theme.code.color = .systemGreen
        XCTAssertEqual(theme.monoFont.familyName, "Courier New")
        let mark = schema.marks["code"]!.create([:])
        let attrs = theme.attributes(for: [mark], baseFont: theme.bodyFont)
        XCTAssertEqual(attrs[.foregroundColor] as? UIColor, .systemGreen)
        XCTAssertEqual((attrs[.font] as? UIFont)?.familyName, "Courier New")
    }

    func testCodeBackgroundIsOptOut() throws {
        var theme = referenceTheme()
        let doc = try schema.node("doc", [:], content: Fragment.from([
            try schema.node("paragraph", [:], content: Fragment.from([
                schema.text("x", [schema.marks["code"]!.create([:])]),
            ])),
        ]))
        editor.setContent(doc)
        XCTAssertTrue(DocumentLayout(doc: editor.doc, width: 320, theme: theme).codeBackgrounds.isEmpty,
                      "no pill unless the theme asks for one")
        theme.code.inline.background = .systemFill
        XCTAssertEqual(DocumentLayout(doc: editor.doc, width: 320, theme: theme).codeBackgrounds.count, 1)
    }

    func testCodeBlockPaddingInsetsTheTextAndSizesTheBackground() throws {
        let code = try schema.node("codeBlock", [:], content: Fragment.from([text("let x = 1")]))
        editor.setContent(try schema.node("doc", [:], content: Fragment.from([code])))
        var theme = referenceTheme()
        // Default: no background, no inset — a block sits where it always has.
        let plain = DocumentLayout(doc: editor.doc, width: 320, theme: theme)
        XCTAssertEqual(try XCTUnwrap(plain.blocks.first).frame.minX, theme.pageInsets.left, accuracy: 0.01)
        XCTAssertTrue(plain.decorations.isEmpty)

        theme.code.block.background = .systemFill
        theme.code.block.padding = EmInsets(top: .points(10), left: .points(12),
                                            bottom: .points(14), right: .points(16))
        let padded = DocumentLayout(doc: editor.doc, width: 320, theme: theme)
        let block = try XCTUnwrap(padded.blocks.first)
        XCTAssertEqual(block.frame.minX, theme.pageInsets.left + 12, accuracy: 0.01)
        XCTAssertEqual(block.frame.minY, theme.pageInsets.top + 10, accuracy: 0.01)
        XCTAssertEqual(block.frame.width, 320 - theme.pageInsets.left - theme.pageInsets.right - 12 - 16,
                       accuracy: 0.01)
        // The background wraps the padded box, not the text.
        let fill = try XCTUnwrap(padded.decorations.compactMap { item -> CGRect? in
            if case let .roundedFill(rect, _, _) = item { return rect }
            return nil
        }.first)
        XCTAssertEqual(fill.minY, theme.pageInsets.top, accuracy: 0.01)
        XCTAssertEqual(fill.maxY, block.frame.maxY + 14, accuracy: 0.01)
        XCTAssertEqual(padded.height - plain.height, 24, accuracy: 0.01, "top + bottom padding")
    }

    func testCodeBlockBackgroundPaintsUnderItsOwnText() throws {
        let code = try schema.node("codeBlock", ["language": .string("swift")],
                                   content: Fragment.from([text("let x = 1")]))
        editor.setContent(try schema.node("doc", [:], content: Fragment.from([code])))
        var theme = referenceTheme()
        theme.code.block.background = .systemFill
        let layout = DocumentLayout(doc: editor.doc, width: 320, theme: theme)
        // Decorations paint in order, so the block's background must come first
        // — otherwise it covers the language badge drawn over it.
        guard case .roundedFill(_, let color, _) = layout.decorations[0] else {
            return XCTFail("the block background is the first decoration")
        }
        XCTAssertEqual(color, .systemFill)
    }

    func testCodeBlockTextColorFallsBackToTheDocumentColor() throws {
        let code = try schema.node("codeBlock", [:], content: Fragment.from([text("let x = 1")]))
        editor.setContent(try schema.node("doc", [:], content: Fragment.from([code])))
        var theme = referenceTheme()
        theme.textColor = .systemBrown
        theme.code.color = .systemGreen // the inline color, which a block ignores
        func rendered(_ theme: DocumentTheme) throws -> UIColor {
            let block = try XCTUnwrap(DocumentLayout(doc: editor.doc, width: 320, theme: theme).blocks.first)
            return try XCTUnwrap(unsafe block.attributed
                .attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor)
        }
        XCTAssertEqual(try rendered(theme), .systemBrown, "nil takes the document's text color")
        theme.code.block.color = .systemPink
        XCTAssertEqual(try rendered(theme), .systemPink)
    }

    // MARK: - Table

    private func table2x2() throws -> Node {
        func cell(_ s: String) throws -> Node {
            try schema.node("tableCell", [:], content: Fragment.from([
                try schema.node("paragraph", [:], content: Fragment.from([text(s)])),
            ]))
        }
        return try schema.node("table", [:], content: Fragment.from([
            try schema.node("tableRow", [:], content: Fragment.from([try cell("A"), try cell("B")])),
            try schema.node("tableRow", [:], content: Fragment.from([try cell("C"), try cell("D")])),
        ]))
    }

    func testCellPaddingInsetsCellContent() throws {
        editor.setContent(try schema.node("doc", [:], content: Fragment.from([try table2x2()])))
        var theme = referenceTheme()
        theme.table.cellPadding = EmInsets(top: .points(20), left: .points(18),
                                           bottom: .points(4), right: .points(2))
        let layout = DocumentLayout(doc: editor.doc, width: 320, theme: theme)
        let first = try XCTUnwrap(layout.blocks.first)
        XCTAssertEqual(first.frame.minX, theme.pageInsets.left + 18, accuracy: 0.01)
        XCTAssertEqual(first.frame.minY, theme.pageInsets.top + 20, accuracy: 0.01)
    }

    func testRowGrowsPastItsMinimumForTallPadding() throws {
        editor.setContent(try schema.node("doc", [:], content: Fragment.from([try table2x2()])))
        var theme = referenceTheme()
        let base = theme.points(theme.table.cellPadding)
        let short = DocumentLayout(doc: editor.doc, width: 320, theme: theme).height
        theme.table.cellPadding = EmInsets(top: .points(30), left: .points(6),
                                           bottom: .points(30), right: .points(6))
        let tall = DocumentLayout(doc: editor.doc, width: 320, theme: theme).height
        // Two rows, each gaining the extra top and bottom padding.
        let extra = (30 - base.top) + (30 - base.bottom)
        XCTAssertEqual(tall - short, extra * 2, accuracy: 0.01)
    }

    func testMinimumRowHeightHoldsAnEmptyRowOpen() throws {
        editor.setContent(try schema.node("doc", [:], content: Fragment.from([try table2x2()])))
        var theme = referenceTheme()
        theme.table.minimumRowHeight = .points(100)
        let layout = DocumentLayout(doc: editor.doc, width: 320, theme: theme)
        let borders = layout.decorations.compactMap { item -> CGRect? in
            if case let .stroke(rect, _, _) = item { return rect }
            return nil
        }
        XCTAssertEqual(try XCTUnwrap(borders.first).height, 100, accuracy: 0.01)
    }

    func testTableBorderColorAndWidth() throws {
        editor.setContent(try schema.node("doc", [:], content: Fragment.from([try table2x2()])))
        var theme = referenceTheme()
        theme.hairlineColor = .systemTeal
        let followed = DocumentLayout(doc: editor.doc, width: 320, theme: theme).decorations
            .compactMap { item -> (UIColor, CGFloat)? in
                if case let .stroke(_, color, width) = item { return (color, width) }
                return nil
            }
        XCTAssertEqual(followed.first?.0, .systemTeal, "borders follow the shared hairline")
        theme.table.borderColor = .systemPink
        theme.table.borderWidth = 3
        let own = DocumentLayout(doc: editor.doc, width: 320, theme: theme).decorations
            .compactMap { item -> (UIColor, CGFloat)? in
                if case let .stroke(_, color, width) = item { return (color, width) }
                return nil
            }
        XCTAssertEqual(own.first?.0, .systemPink)
        XCTAssertEqual(own.first?.1, 3)
    }

    // MARK: - Quote and the shared hairline

    func testQuoteBarFollowsTheHairlineUntilItNamesItsOwn() {
        var theme = referenceTheme()
        theme.hairlineColor = .systemTeal
        XCTAssertEqual(theme.quoteBarColor, .systemTeal, "one hairline styles the bar too")
        theme.quote.barColor = .systemPink
        XCTAssertEqual(theme.quoteBarColor, .systemPink)
        XCTAssertEqual(theme.hairlineColor, .systemTeal, "the bar's own color doesn't leak back")
    }

    func testQuoteBarWidthAndIndentDriveLayout() throws {
        let quote = try schema.node("blockquote", [:], content: Fragment.from([
            try schema.node("paragraph", [:], content: Fragment.from([text("quoted")])),
        ]))
        editor.setContent(try schema.node("doc", [:], content: Fragment.from([quote])))
        var theme = referenceTheme()
        theme.quote.barWidth = 7
        theme.quote.indent = .points(40)
        let layout = DocumentLayout(doc: editor.doc, width: 320, theme: theme)
        let bars = layout.decorations.compactMap { item -> CGRect? in
            if case let .fill(rect, _) = item { return rect }
            return nil
        }
        XCTAssertEqual(try XCTUnwrap(bars.first).width, 7)
        let block = try XCTUnwrap(layout.blocks.first)
        XCTAssertEqual(block.frame.minX, theme.pageInsets.left + 40, accuracy: 0.5)
    }

    // MARK: - Horizontal rule

    private func ruleLayout(_ theme: DocumentTheme) throws -> DocumentLayout {
        editor.setContent(try schema.node("doc", [:], content: Fragment.from([
            try schema.node("horizontalRule", [:]),
        ])))
        return DocumentLayout(doc: editor.doc, width: 320, theme: theme)
    }
    private func ruleRect(_ layout: DocumentLayout) throws -> CGRect {
        try XCTUnwrap(layout.decorations.compactMap { item -> CGRect? in
            if case let .fill(rect, _) = item { return rect }
            return nil
        }.first)
    }

    func testDefaultRuleGeometryComesFromItsEms() throws {
        let theme = referenceTheme()
        let layout = try ruleLayout(theme)
        let rect = try ruleRect(layout)
        let above = theme.points(theme.horizontalRule.spacingBefore)
        let below = theme.points(theme.horizontalRule.spacingAfter)
        XCTAssertEqual(rect.minY, theme.pageInsets.top + above, accuracy: 0.01)
        // The line is a hairline in points: it answers to the device, not the type.
        XCTAssertEqual(rect.height, 1)
        XCTAssertEqual(rect.minX, theme.pageInsets.left, accuracy: 0.01)
        XCTAssertEqual(rect.width, 320 - theme.pageInsets.left - theme.pageInsets.right, accuracy: 0.01)
        XCTAssertEqual(layout.height,
                       theme.pageInsets.top + above + 1 + below + theme.pageInsets.bottom, accuracy: 0.01)
    }

    func testRuleGrowsWithTheBodySize() throws {
        var big = referenceTheme()
        big.fixedBodyFontSize = DocumentTheme.referenceBodySize * 2
        let small = try ruleLayout(referenceTheme()).height - referenceTheme().pageInsets.top
            - referenceTheme().pageInsets.bottom
        let large = try ruleLayout(big).height - big.pageInsets.top - big.pageInsets.bottom
        // Twice the type: the air doubles, the hairline doesn't.
        XCTAssertEqual(large - 1, (small - 1) * 2, accuracy: 0.01)
    }

    func testRuleSpacingThicknessAndColorAreConfigurable() throws {
        var theme = referenceTheme()
        theme.horizontalRule.spacingBefore = .points(20)
        theme.horizontalRule.spacingAfter = .points(30)
        theme.horizontalRule.thickness = 4
        theme.horizontalRule.color = .systemPink
        let layout = try ruleLayout(theme)
        let rect = try ruleRect(layout)
        XCTAssertEqual(rect.minY, theme.pageInsets.top + 20, accuracy: 0.01)
        XCTAssertEqual(rect.height, 4)
        XCTAssertEqual(layout.height, theme.pageInsets.top + 54 + theme.pageInsets.bottom, accuracy: 0.01)
        let color = layout.decorations.compactMap { item -> UIColor? in
            if case let .fill(_, color) = item { return color }
            return nil
        }.first
        XCTAssertEqual(color, .systemPink)
    }

    func testRuleInsetShortensItFromBothEnds() throws {
        var theme = referenceTheme()
        theme.horizontalRule.inset = .points(60)
        let rect = try ruleRect(try ruleLayout(theme))
        XCTAssertEqual(rect.minX, theme.pageInsets.left + 60, accuracy: 0.01)
        XCTAssertEqual(rect.width, 320 - theme.pageInsets.left - theme.pageInsets.right - 120, accuracy: 0.01)
    }

    func testRuleFollowsTheHairlineUnlessItNamesAColor() throws {
        var theme = referenceTheme()
        theme.hairlineColor = .systemTeal
        let color = try ruleLayout(theme).decorations.compactMap { item -> UIColor? in
            if case let .fill(_, color) = item { return color }
            return nil
        }.first
        XCTAssertEqual(color, .systemTeal)
    }

    // MARK: - Selection

    func testSelectionDefaultsAreUnchanged() {
        let theme = referenceTheme()
        XCTAssertEqual(theme.selection.caret, .tintColor)
        XCTAssertEqual(theme.selection.fill, UIColor.tintColor.withAlphaComponent(0.25))
    }
}
#endif

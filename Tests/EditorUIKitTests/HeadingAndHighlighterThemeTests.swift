#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

/// The theme knobs added for headings and highlighters, plus the checkbox's
/// alignment to the text beside it.
@MainActor
final class HeadingAndHighlighterThemeTests: XCTestCase {
    /// One editor per test, so nodes and the document they're set into share a
    /// schema — a node built from a second `Editor`'s schema doesn't satisfy
    /// `doc`'s content expression and is dropped on the way in.
    private lazy var editor: Editor = try! Editor(extensions: fullKit())
    private var schema: Schema { editor.schema }

    private func heading(_ level: Int, _ text: String = "Title") throws -> Node {
        try schema.node("heading", ["level": .int(level)], content: Fragment.from([schema.text(text)]))
    }
    private func paragraph(_ text: String = "body") throws -> Node {
        try schema.node("paragraph", [:], content: Fragment.from([schema.text(text)]))
    }
    private func setDoc(_ children: [Node]) throws {
        editor.setContent(try schema.node("doc", [:], content: Fragment.from(children)))
        XCTAssertEqual(editor.doc.childCount, children.count, "document kept every block it was given")
    }

    // MARK: - Weight, tracking, alignment

    func testWeightReplacesTheDefaultBold() throws {
        var theme = DocumentTheme()
        theme.dynamicType = false
        // Default: bold, as headings have always been.
        XCTAssertTrue(try theme.blockFont(heading(1)).fontDescriptor.symbolicTraits.contains(.traitBold))
        theme.heading.weight = .light
        let light = try theme.blockFont(heading(1))
        let weights = light.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
        XCTAssertEqual(try XCTUnwrap(weights?[.weight] as? CGFloat),
                       UIFont.Weight.light.rawValue, accuracy: 0.01)
    }

    func testTrackingBecomesKernScaledToTheRunSize() throws {
        var theme = DocumentTheme()
        theme.dynamicType = false
        theme.heading.tracking = -0.02
        let font = try theme.blockFont(heading(1))
        let attrs = theme.attributes(for: [], baseFont: font, tracking: theme.heading.tracking)
        XCTAssertEqual(try XCTUnwrap(attrs[.kern] as? CGFloat), font.pointSize * -0.02, accuracy: 0.001)
        // Body text asks for no tracking and gets none.
        XCTAssertNil(theme.attributes(for: [], baseFont: theme.bodyFont)[.kern])
    }

    func testAlignmentAppliesToHeadingsOnly() throws {
        var theme = DocumentTheme()
        theme.heading.alignment = .center
        XCTAssertEqual(try theme.alignment(for: heading(1)), .center)
        XCTAssertNil(try theme.alignment(for: paragraph()))
    }

    // MARK: - Spacing

    func testHeadingSpacingCollapsesToTheLargerSide() throws {
        var theme = DocumentTheme()
        theme.paragraphSpacing = 10
        let h = try heading(1), p = try paragraph()
        // Neither side asks: the document's paragraph spacing.
        XCTAssertEqual(theme.spacing(before: p, after: p), 10)
        // The first block in a container opens flush.
        XCTAssertEqual(theme.spacing(before: h, after: nil), 0)
        // One side asks — even for less than paragraphSpacing — and is honoured.
        theme.heading.spacingAfter = 4
        XCTAssertEqual(theme.spacing(before: p, after: h), 4)
        theme.heading.spacingBefore = 30
        XCTAssertEqual(theme.spacing(before: h, after: p), 30)
        // Both sides ask: the larger wins, so two gaps never stack.
        XCTAssertEqual(theme.spacing(before: h, after: h), 30)
    }

    func testHeadingSpacingMovesTheNextBlockDown() throws {
        try setDoc([try heading(1), try paragraph()])
        var theme = DocumentTheme()
        theme.heading.spacingAfter = 40
        let wide = DocumentLayout(doc: editor.doc, width: 320, theme: theme)
        let tight = DocumentLayout(doc: editor.doc, width: 320, theme: DocumentTheme())
        let wideGap = wide.blocks[1].frame.minY - wide.blocks[0].frame.maxY
        let tightGap = tight.blocks[1].frame.minY - tight.blocks[0].frame.maxY
        XCTAssertEqual(wideGap - tightGap, 40 - DocumentTheme().paragraphSpacing, accuracy: 0.5)
    }

    // MARK: - Rule

    func testRuleDrawsUnderTheHeadingAndTakesSpace() throws {
        try setDoc([try heading(2)])
        var theme = DocumentTheme()
        theme.heading.rule = DocumentTheme.Heading.Rule(thickness: 2, spacing: 6)
        let ruled = DocumentLayout(doc: editor.doc, width: 320, theme: theme)
        let plain = DocumentLayout(doc: editor.doc, width: 320, theme: DocumentTheme())
        XCTAssertEqual(ruled.height - plain.height, 8, accuracy: 0.5, "rule occupies spacing + thickness")
        let block = try XCTUnwrap(ruled.blocks.first)
        let fills = ruled.decorations.compactMap { item -> CGRect? in
            if case let .fill(rect, _) = item { return rect }
            return nil
        }
        let rule = try XCTUnwrap(fills.first { $0.height == 2 })
        XCTAssertEqual(rule.minY, block.frame.maxY + 6, accuracy: 0.5)
        XCTAssertTrue(plain.decorations.isEmpty, "no rule unless the theme asks for one")
    }

    // MARK: - Per-level overrides

    func testLevelOverrideWinsOverTheHeadingWideValue() throws {
        var theme = DocumentTheme()
        theme.dynamicType = false
        theme.heading.fontName = "Georgia"
        var h1 = DocumentTheme.Heading.Level()
        h1.fontName = "Avenir Next"
        theme.heading.levels[1] = h1
        XCTAssertEqual(try theme.blockFont(heading(1)).familyName, "Avenir Next")
        XCTAssertEqual(try theme.blockFont(heading(2)).familyName, "Georgia")
    }

    func testHeadingWideColorSkipsTheTitleButALevelColorDoesNot() {
        var theme = DocumentTheme()
        theme.heading.color = .systemRed
        XCTAssertNil(theme.heading.resolved(forLevel: 1).color, "the h1 title keeps textColor")
        XCTAssertEqual(theme.heading.resolved(forLevel: 2).color, .systemRed)
        var h1 = DocumentTheme.Heading.Level()
        h1.color = .systemBlue
        theme.heading.levels[1] = h1
        XCTAssertEqual(theme.heading.resolved(forLevel: 1).color, .systemBlue,
                       "naming a color for level 1 is explicit, so it applies")
    }

    /// The rendered counterpart of the resolver test above: the layout must ask
    /// the theme which color a level takes, not re-decide it.
    func testLevelColorReachesTheRenderedTitle() throws {
        try setDoc([try heading(1), try heading(2)])
        var theme = DocumentTheme()
        theme.heading.color = .systemRed
        func color(_ index: Int, _ theme: DocumentTheme) throws -> UIColor {
            let block = DocumentLayout(doc: editor.doc, width: 320, theme: theme).blocks[index]
            return try XCTUnwrap(unsafe block.attributed
                .attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor)
        }
        XCTAssertEqual(try color(0, theme), theme.textColor, "the h1 title keeps textColor")
        XCTAssertEqual(try color(1, theme), .systemRed)

        var h1 = DocumentTheme.Heading.Level()
        h1.color = .systemBlue
        theme.heading.levels[1] = h1
        XCTAssertEqual(try color(0, theme), .systemBlue,
                       "a color named for level 1 renders, rather than being overruled in layout")
    }

    func testHeadingTrackingReachesTheRenderedRunButNotBodyText() throws {
        try setDoc([try heading(1), try paragraph()])
        var theme = DocumentTheme()
        theme.heading.tracking = -0.03
        let layout = DocumentLayout(doc: editor.doc, width: 320, theme: theme)
        let font = try XCTUnwrap(unsafe layout.blocks[0].attributed
            .attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        let kern = try XCTUnwrap(unsafe layout.blocks[0].attributed
            .attribute(.kern, at: 0, effectiveRange: nil) as? CGFloat)
        XCTAssertEqual(kern, font.pointSize * -0.03, accuracy: 0.01)
        XCTAssertNil(unsafe layout.blocks[1].attributed.attribute(.kern, at: 0, effectiveRange: nil),
                     "body text is untracked")
    }

    func testDynamicTypeStylesAreDistinctPerLevel() throws {
        var theme = DocumentTheme()
        theme.dynamicType = true
        let sizes = try (1...6).map { try theme.blockFont(heading($0)).pointSize }
        XCTAssertEqual(sizes, sizes.sorted(by: >), "the ramp descends")
        XCTAssertNotEqual(sizes[3], sizes[4], "h4 and h5 used to share .headline")
    }

    // MARK: - Highlighters

    func testHighlighterLookupFallsBackToTheFirst() {
        let theme = DocumentTheme()
        XCTAssertEqual(theme.highlighter("green")?.name, "green")
        XCTAssertEqual(theme.highlighter(nil)?.name, theme.highlighters.first?.name)
        XCTAssertEqual(theme.highlighter("chartreuse")?.name, theme.highlighters.first?.name,
                       "a name this theme doesn't have falls back rather than vanishing")
    }

    func testHighlighterResolvesLightAndDarkInk() {
        var theme = DocumentTheme()
        theme.highlighters = [
            .init(name: "ink",
                  light: .init(background: .white, text: .black),
                  dark: .init(background: .black, text: .white)),
        ]
        let light = UITraitCollection(userInterfaceStyle: .light)
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        let background = theme.highlightColor("ink")
        XCTAssertEqual(background.resolvedColor(with: light), .white)
        XCTAssertEqual(background.resolvedColor(with: dark), .black)
        let text = try? XCTUnwrap(theme.highlightTextColor("ink"))
        XCTAssertEqual(text?.resolvedColor(with: light), .black)
        XCTAssertEqual(text?.resolvedColor(with: dark), .white)
    }

    func testHighlighterTextColorIsNilUnlessAsked() {
        let theme = DocumentTheme()
        XCTAssertNil(theme.highlightTextColor("yellow"),
                     "the stock set tints the background only, leaving the run's color")
    }

    func testHighlighterTextColorOverridesTheRunColor() throws {
        let s = schema
        var theme = DocumentTheme()
        theme.highlighters = [.init(name: "ink", background: .yellow, text: .black)]
        let marks = [
            s.marks["textColor"]!.create(["color": .string("#FF0000")]),
            s.marks["highlight"]!.create(["color": .string("ink")]),
        ]
        let attrs = theme.attributes(for: marks, baseFont: theme.bodyFont)
        XCTAssertEqual(attrs[.foregroundColor] as? UIColor, .black,
                       "the highlighter picked its text color against its own background")
        // Reversed mark order changes nothing — precedence isn't array order.
        let reversed = theme.attributes(for: marks.reversed(), baseFont: theme.bodyFont)
        XCTAssertEqual(reversed[.foregroundColor] as? UIColor, .black)
    }

    func testRunColorSurvivesAHighlighterThatNamesNoTextColor() throws {
        let s = schema
        let theme = DocumentTheme()
        let marks = [
            s.marks["textColor"]!.create(["color": .string("#FF0000")]),
            s.marks["highlight"]!.create(["color": .string("yellow")]),
        ]
        let attrs = theme.attributes(for: marks, baseFont: theme.bodyFont)
        XCTAssertEqual(attrs[.foregroundColor] as? UIColor, UIColor(hex: "#FF0000"))
    }

    // MARK: - Checkbox alignment

    func testCheckboxCentresOnTheFirstLineAcrossFontSizes() throws {
        let item = try schema.node("taskItem", ["checked": .bool(false)],
                                   content: Fragment.from([try paragraph("Buy milk")]))
        try setDoc([try schema.node("taskList", [:], content: Fragment.from([item]))])
        for size in [13.0, 17.0, 24.0, 28.0] as [CGFloat] {
            var theme = DocumentTheme()
            theme.dynamicType = false
            theme.fixedBodyFontSize = size
            let layout = DocumentLayout(doc: editor.doc, width: 320, theme: theme)
            // The stored rect is padded for touch; the drawn box is 6pt inside it.
            let box = try XCTUnwrap(layout.checkboxes.first).rect.insetBy(dx: 6, dy: 6)
            let line = try XCTUnwrap(layout.blocks.first?.lines.first)
            let font = theme.bodyFont
            let midline = line.baselineOrigin.y - font.capHeight / 2
            XCTAssertEqual(box.midY, midline, accuracy: 1.0,
                           "checkbox should sit on the text midline at \(size)pt")
            XCTAssertEqual(box.height, (font.capHeight * 1.55).rounded(), accuracy: 0.01,
                           "and scale with the text at \(size)pt")
        }
    }
}
#endif

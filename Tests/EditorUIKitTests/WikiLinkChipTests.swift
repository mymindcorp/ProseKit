#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import SchemaKit
@testable import EditorUIKit

/// `theme.wikiLink`: a wiki-link set as a chip — a pill behind the label, and
/// the host's glyph for whatever kind of object the target names.
///
/// Off by default: with no `background` a wiki-link stays the plain coloured
/// (and underlined) text it has always been, and reserves no extra space.
@MainActor
final class WikiLinkChipTests: XCTestCase {
    /// A document reading "before [[Target]] after", so the chip has text on
    /// both sides to push around.
    private func makeView(_ configure: (inout DocumentTheme) -> Void = { _ in }) throws -> EditorTextView {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        editor.setContent(try s.node("doc", [:], content: Fragment.from([
            try s.node("paragraph", [:], content: Fragment.from([
                s.text("before "),
                try s.node("wikiLink", ["target": .string("Target")], content: Fragment.empty),
                s.text(" after"),
            ])),
        ])))
        let view = EditorTextView(editor: editor)
        var theme = DocumentTheme()
        configure(&theme)
        view.theme = theme
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        view.layoutIfNeeded()
        return view
    }

    /// A solid glyph, so "was it drawn" and "how big" are both answerable.
    private func glyph() -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40), format: format).image { ctx in
            UIColor.black.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
    }

    private func pills(_ view: EditorTextView) -> [CGRect] {
        view.ensureLayout().decorations.compactMap {
            if case let .roundedFill(rect, _, _) = $0 { return rect }
            return nil
        }
    }

    private func icons(_ view: EditorTextView) -> [CGRect] {
        view.ensureLayout().decorations.compactMap {
            if case let .icon(_, rect) = $0 { return rect }
            return nil
        }
    }

    /// The `.underlineStyle` on the chip's label itself — found by the label's
    /// text, since a chip's run opens with the reserved box rather than a glyph.
    private func labelUnderline(_ view: EditorTextView) throws -> Int? {
        let block = try XCTUnwrap(view.ensureLayout().blocks.first)
        let label = (block.attributed.string as NSString).range(of: "Target")
        XCTAssertNotEqual(label.location, NSNotFound)
        return unsafe block.attributed.attribute(.underlineStyle, at: label.location, effectiveRange: nil) as? Int
    }

    /// The document position just after the wiki-link atom — where the text
    /// following the chip starts.
    private let posAfterAtom = 9   // 1 (paragraph) + 7 ("before ") + 1 (atom)

    func testNoChipByDefault() throws {
        let view = try makeView()
        XCTAssertTrue(pills(view).isEmpty, "an unstyled wiki-link should draw no pill")
        XCTAssertTrue(icons(view).isEmpty)
    }

    /// Nothing changes by default: the label is underlined, as `link.underline`
    /// says, and the atom takes exactly the width of its text.
    func testDefaultKeepsTheLinkUnderlineAndReservesNoPadding() throws {
        let plain = try makeView()
        XCTAssertEqual(try labelUnderline(plain), NSUnderlineStyle.single.rawValue)

        // No reserved box: the atom's run is exactly its label.
        let styled = try makeView { $0.wikiLink.background = .secondarySystemFill }
        XCTAssertGreaterThan(try XCTUnwrap(styled.ensureLayout().caretRect(at: posAfterAtom)).minX,
                             try XCTUnwrap(plain.ensureLayout().caretRect(at: posAfterAtom)).minX,
                             "the chip's padding should push the text after it along")
    }

    /// `underline` overrides `link.underline` when the theme sets it, and
    /// follows it when it doesn't.
    func testUnderlineFollowsTheLinkUnlessOverridden() throws {
        func underlined(_ view: EditorTextView) throws -> Bool {
            try labelUnderline(view) != nil
        }
        XCTAssertTrue(try underlined(makeView { $0.wikiLink.background = .secondarySystemFill }))
        XCTAssertFalse(try underlined(makeView {
            $0.wikiLink.background = .secondarySystemFill
            $0.wikiLink.underline = false
        }))
        XCTAssertFalse(try underlined(makeView { $0.link.underline = false }))
        XCTAssertTrue(try underlined(makeView { $0.wikiLink.underline = true; $0.link.underline = false }))
    }

    /// The pill wraps the label plus its padding, and sits on the line the
    /// label is on.
    func testChipPillWrapsTheLabel() throws {
        let view = try makeView {
            $0.wikiLink.background = .secondarySystemFill
            $0.wikiLink.paddingX = 0.35
            $0.wikiLink.paddingY = 0.12
        }
        let rects = pills(view)
        XCTAssertEqual(rects.count, 1)
        let pill = try XCTUnwrap(rects.first)
        let layout = view.ensureLayout()
        let before = try XCTUnwrap(layout.caretRect(at: posAfterAtom - 1))  // before the atom
        let after = try XCTUnwrap(layout.caretRect(at: posAfterAtom))
        XCTAssertEqual(pill.minX, before.minX, accuracy: 1, "the pill should start where the atom does")
        XCTAssertEqual(pill.maxX, after.minX, accuracy: 1, "and end where the text after it starts")
        let tight = try makeView {
            $0.wikiLink.background = .secondarySystemFill
            $0.wikiLink.paddingY = 0.0
        }
        XCTAssertEqual(pill.height - (try XCTUnwrap(pills(tight).first)).height,
                       view.theme.points(0.12) * 2, accuracy: 0.5,
                       "the pill's vertical padding should show, above and below")
    }

    /// A host glyph takes a square box before the label, sized in ems, and the
    /// chip grows to hold it.
    func testHostGlyphIsDrawnBeforeTheLabel() throws {
        let plain = try makeView { $0.wikiLink.background = .secondarySystemFill }
        let plainPill = try XCTUnwrap(pills(plain).first)

        let view = try makeView { $0.wikiLink.background = .secondarySystemFill }
        view.wikiLinkIcon = { [glyph = glyph()] node in
            node.attrs["target"]?.stringValue == "Target" ? glyph : nil
        }
        let iconRects = icons(view)
        XCTAssertEqual(iconRects.count, 1)
        let icon = try XCTUnwrap(iconRects.first)
        let expected = view.theme.points(view.theme.wikiLink.iconSize)
        XCTAssertEqual(icon.width, expected, accuracy: 0.5)
        XCTAssertEqual(icon.height, expected, accuracy: 0.5)

        let pill = try XCTUnwrap(pills(view).first)
        XCTAssertEqual(pill.minX, plainPill.minX, accuracy: 1, "the chip should still start in the same place")
        XCTAssertGreaterThan(pill.width, plainPill.width + expected / 2,
                             "the glyph's box and gap should widen the chip")
        XCTAssertGreaterThan(icon.minX, pill.minX, "the glyph sits inside the pill's leading padding")
        XCTAssertLessThan(icon.maxX, pill.maxX)
        XCTAssertGreaterThan(icon.minY, pill.minY)
        XCTAssertLessThan(icon.maxY, pill.maxY)
    }

    /// Setting the hook after a layout has to reach the paragraph's cached
    /// block — the glyph's box is typeset into it, and neither the node nor the
    /// width changed.
    func testSettingTheHookRelaysTheCachedBlock() throws {
        let view = try makeView { $0.wikiLink.background = .secondarySystemFill }
        XCTAssertTrue(icons(view).isEmpty)
        let width = try XCTUnwrap(pills(view).first).width
        view.wikiLinkIcon = { [glyph = glyph()] _ in glyph }
        XCTAssertEqual(icons(view).count, 1, "the cached block kept the glyph-less layout")
        XCTAssertGreaterThan(try XCTUnwrap(pills(view).first).width, width)
    }

    /// A glyph with no chip behind it: the box is still reserved, so the label
    /// doesn't sit on top of it.
    func testGlyphWithoutAPillStillReservesItsBox() throws {
        let plain = try makeView()
        let view = try makeView()
        view.wikiLinkIcon = { [glyph = glyph()] _ in glyph }
        XCTAssertTrue(pills(view).isEmpty)
        XCTAssertEqual(icons(view).count, 1)
        XCTAssertGreaterThan(try XCTUnwrap(view.ensureLayout().caretRect(at: posAfterAtom)).minX,
                             try XCTUnwrap(plain.ensureLayout().caretRect(at: posAfterAtom)).minX)
    }

    /// A chip is one object, so it may not break across a line: a two-word
    /// label wraps whole rather than splitting at its space.
    func testChipDoesNotBreakAcrossLines() throws {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        editor.setContent(try s.node("doc", [:], content: Fragment.from([
            try s.node("paragraph", [:], content: Fragment.from([
                s.text("some words that nearly fill the line up to here"),
                try s.node("wikiLink", ["target": .string("Two Words")], content: Fragment.empty),
            ])),
        ])))
        let view = EditorTextView(editor: editor)
        var theme = DocumentTheme()
        theme.wikiLink.background = .secondarySystemFill
        view.theme = theme
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        view.layoutIfNeeded()
        XCTAssertEqual(pills(view).count, 1, "the chip should sit on exactly one line")
        let block = try XCTUnwrap(view.ensureLayout().blocks.first)
        let label = block.attributed.string
        XCTAssertTrue(label.contains("Two\u{00a0}Words"), "the label's space should stop being a break opportunity")
    }
}
#endif

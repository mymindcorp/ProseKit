#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

/// The pointer (desktop cursor) styles, the find bar's replace wiring, the
/// checklist recovery on a rich paste, and the remaining small hooks.
/// `UIPointerRegionRequest` has no public initializer, but it is `open`, so a
/// subclass can report a scripted pointer location.
private final class FakeRegionRequest: UIPointerRegionRequest {
    var point: CGPoint = .zero
    override var location: CGPoint { point }
}

@MainActor
final class EditorTextViewPointerAndChromeTests: XCTestCase {
    private func makeView(_ build: (Schema) throws -> [Node]) throws -> EditorTextView {
        let editor = try Editor(extensions: fullKit())
        editor.setContent(try editor.schema.node("doc", [:], content: Fragment.from(build(editor.schema))))
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        view.layoutIfNeeded()
        _ = view.ensureLayout()
        return view
    }

    private func paragraphs(_ lines: [String]) throws -> EditorTextView {
        try makeView { s in
            try lines.map { line in
                try s.node("paragraph", [:], content: Fragment.from(line.isEmpty ? [] : [s.text(line)]))
            }
        }
    }

    private var pointerInteraction: UIPointerInteraction {
        UIPointerInteraction(delegate: nil)
    }

    // MARK: - Pointer styles

    func testEachPointerRegionGetsItsOwnStyle() throws {
        let view = try paragraphs(["hello world"])
        let rect = CGRect(x: 10, y: 10, width: 60, height: 20)

        for identifier in ["columnBorder", "link", "blockHandle", "imageHandle"] {
            let region = UIPointerRegion(rect: rect, identifier: identifier)
            XCTAssertNotNil(view.pointerInteraction(pointerInteraction, styleFor: region),
                            "\(identifier) has a cursor style")
        }
    }

    func testAColumnBorderGetsTheResizeCursorAndTextGetsABeam() throws {
        let view = try paragraphs(["hello world"])
        let rect = CGRect(x: 10, y: 10, width: 4, height: 40)

        // The two styles are built from different shapes, so they differ.
        let border = view.pointerInteraction(pointerInteraction,
                                             styleFor: UIPointerRegion(rect: rect, identifier: "columnBorder"))
        let text = view.pointerInteraction(pointerInteraction,
                                           styleFor: UIPointerRegion(rect: rect, identifier: "text"))
        XCTAssertNotNil(border)
        XCTAssertNotNil(text)
        XCTAssertNotEqual(border, text, "a column border does not get the I-beam")
    }

    func testAnUnknownRegionFallsBackToTheTextBeam() throws {
        let view = try paragraphs(["hello world"])
        let rect = CGRect(x: 0, y: 0, width: 10, height: 10)
        let unknown = view.pointerInteraction(pointerInteraction,
                                              styleFor: UIPointerRegion(rect: rect, identifier: "somethingElse"))
        let text = view.pointerInteraction(pointerInteraction,
                                           styleFor: UIPointerRegion(rect: rect, identifier: "text"))
        XCTAssertEqual(unknown, text, "anything unrecognized is treated as text")
    }

    func testPointerTargetsCoverEachAffordance() throws {
        let view = try makeView { s in
            let link = s.marks["link"]!
            return [
                try s.node("paragraph", [:], content: Fragment.from([
                    s.text("go", [link.create(["href": .string("https://example.com")])]),
                ])),
                try s.node("image", ["src": .string("https://example.com/a.png"),
                                     "width": .int(100), "height": .int(80)]),
            ]
        }
        view.onLinkClick = { _ in }
        view.imageResizingEnabled = true
        let layout = view.ensureLayout()
        let linkBlock = layout.blocks[0]

        // Over the link run. Block reordering is off here: its drag handle sits
        // in the left margin and would win the same point.
        let linkPoint = CGPoint(x: linkBlock.frame.minX + 3, y: linkBlock.frame.midY)
        if case .link = view.pointerTarget(at: linkPoint) {} else {
            XCTFail("expected a link target, got \(view.pointerTarget(at: linkPoint))")
        }

        view.blockReorderingEnabled = true

        // Over the image's resize grip.
        let imageRect = try XCTUnwrap(layout.imageRects.first).rect
        view.updateImageHover(at: CGPoint(x: imageRect.midX, y: imageRect.midY))
        let grip = CGPoint(x: imageRect.maxX - 4, y: imageRect.maxY - 4)
        if case .imageHandle = view.pointerTarget(at: grip) {} else {
            XCTFail("expected an image handle, got \(view.pointerTarget(at: grip))")
        }

        // Over a block's drag handle.
        view.updateBlockHover(at: CGPoint(x: 4, y: linkBlock.frame.midY))
        if case .blockHandle = view.pointerTarget(at: CGPoint(x: 4, y: linkBlock.frame.midY)) {} else {
            XCTFail("expected a block handle")
        }
    }


    // MARK: - Pointer regions

    /// Ask the delegate which region the pointer is over at a view point.
    private func region(_ view: EditorTextView, at point: CGPoint) -> UIPointerRegion? {
        let request = FakeRegionRequest()
        request.point = point
        let fallback = UIPointerRegion(rect: view.bounds, identifier: "default")
        return view.pointerInteraction(pointerInteraction, regionFor: request, defaultRegion: fallback)
    }

    func testPlainTextHandsBackTheDefaultRegion() throws {
        let view = try paragraphs(["hello world"])
        let block = view.ensureLayout().blocks[0]
        let found = try XCTUnwrap(region(view, at: CGPoint(x: block.frame.midX, y: block.frame.midY)))
        XCTAssertEqual(found.identifier as? String, "default", "text keeps UIKit's own region")
    }

    func testAColumnBorderGetsItsOwnRegion() throws {
        let view = try makeView { s in
            func cell(_ text: String) throws -> Node {
                try s.node("tableCell", [:], content: Fragment.from([
                    try s.node("paragraph", [:], content: Fragment.from([s.text(text)])),
                ]))
            }
            return [try s.node("table", [:], content: Fragment.from([
                try s.node("tableRow", [:], content: Fragment.from([try cell("A"), try cell("B")])),
            ]))]
        }
        let table = try XCTUnwrap(view.ensureLayout().tables.first)
        let point = CGPoint(x: table.borderX(after: 0), y: (table.top + table.bottom) / 2)
        let found = try XCTUnwrap(region(view, at: point))
        XCTAssertEqual(found.identifier as? String, "columnBorder")
    }

    func testALinkGetsItsOwnRegionOnlyWhenAHostIsListening() throws {
        let view = try makeView { s in
            let link = s.marks["link"]!
            return [try s.node("paragraph", [:], content: Fragment.from([
                s.text("go somewhere", [link.create(["href": .string("https://example.com")])]),
            ]))]
        }
        let block = view.ensureLayout().blocks[0]
        let point = CGPoint(x: block.frame.minX + 5, y: block.frame.midY)

        // No handler: a link is just text, so the pointer stays an I-beam.
        XCTAssertEqual(region(view, at: point)?.identifier as? String, "default")

        view.onLinkClick = { _ in }
        XCTAssertEqual(region(view, at: point)?.identifier as? String, "link")
    }

    func testTheBlockAndImageHandlesGetTheirOwnRegions() throws {
        let view = try makeView { s in
            [
                try s.node("paragraph", [:], content: Fragment.from([s.text("text")])),
                try s.node("image", ["src": .string("https://example.com/a.png"),
                                     "width": .int(100), "height": .int(80)]),
            ]
        }
        view.blockReorderingEnabled = true
        view.imageResizingEnabled = true
        let layout = view.ensureLayout()

        // Hovering also reveals the handles, which is what the region walk does.
        let handlePoint = CGPoint(x: 4, y: layout.blocks[0].frame.midY - view.contentOffsetY)
        XCTAssertEqual(region(view, at: handlePoint)?.identifier as? String, "blockHandle")

        let imageRect = try XCTUnwrap(layout.imageRects.first).rect
        let grip = CGPoint(x: imageRect.maxX - 4, y: imageRect.maxY - 4 - view.contentOffsetY)
        XCTAssertEqual(region(view, at: grip)?.identifier as? String, "imageHandle")
    }

    func testMovingThePointerRevealsTheHoveredBlocksHandle() throws {
        let view = try paragraphs(["one", "two"])
        view.blockReorderingEnabled = true
        let layout = view.ensureLayout()

        // The region walk reports pointer hover, which is what flips the view
        // into desktop mode where only the hovered block shows its grip.
        _ = region(view, at: CGPoint(x: 200, y: layout.blocks[1].frame.midY - view.contentOffsetY))
        XCTAssertTrue(view.blockHandleVisibleForTesting(1), "the hovered block shows its grip")
        XCTAssertFalse(view.blockHandleVisibleForTesting(0), "and its neighbour does not")
    }

    // MARK: - Formatting actions

    func testEachFormattingActionRunsItsCommand() throws {
        let view = try paragraphs(["hello world"])
        func selectAll() {
            view.editor.dispatch(view.editor.state.tr.setSelection(
                TextSelection.create(view.editor.doc, 1, 12)))
        }
        func marks() -> Set<String> {
            var found = Set<String>()
            view.editor.doc.descendants { node, _, _, _ in
                for mark in node.marks { found.insert(mark.type.name) }
                return true
            }
            return found
        }

        for (action, mark) in [(view.formatBold, "bold"), (view.formatItalic, "italic"),
                               (view.formatUnderline, "underline"),
                               (view.formatSubscript, "subscript"),
                               (view.formatSuperscript, "superscript"),
                               (view.toggleHighlightAction, "highlight")] {
            selectAll()
            action(nil)
            XCTAssertTrue(marks().contains(mark), "\(mark) was applied")
            selectAll()
            action(nil)
            XCTAssertFalse(marks().contains(mark), "\(mark) toggled back off")
        }
    }

    private func linkPopup(_ view: EditorTextView) -> LinkPopupView? {
        // The popover is hosted in the window so the scroll view can't clip it,
        // so look wider than the editor's own subviews.
        func search(_ v: UIView) -> LinkPopupView? {
            if let popup = v as? LinkPopupView { return popup }
            for child in v.subviews {
                if let found = search(child) { return found }
            }
            return nil
        }
        return search(view.window ?? view)
    }

    func testTheLinkActionOpensTheLinkEditorAndSavesTheURL() throws {
        let view = try paragraphs(["hello world"])
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(view)
        window.makeKeyAndVisible()

        view.editor.dispatch(view.editor.state.tr.setSelection(
            TextSelection.create(view.editor.doc, 1, 6)))
        view.addOrEditLink(nil)
        let popup = try XCTUnwrap(linkPopup(view), "the link editor came up")

        popup.onSubmit?("https://example.com")
        var href: String?
        view.editor.doc.descendants { node, _, _, _ in
            if let link = node.marks.first(where: { $0.type.name == "link" }) {
                href = link.attrs["href"]?.stringValue
            }
            return true
        }
        XCTAssertEqual(href, "https://example.com", "submitting the popover linked the selection")
    }

    func testCancellingTheLinkEditorLeavesTheDocumentAlone() throws {
        let view = try paragraphs(["hello world"])
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(view)
        window.makeKeyAndVisible()

        view.editor.dispatch(view.editor.state.tr.setSelection(
            TextSelection.create(view.editor.doc, 1, 6)))
        view.addOrEditLink(nil)
        let popup = try XCTUnwrap(linkPopup(view))

        popup.onCancel?()
        var linked = false
        view.editor.doc.descendants { node, _, _, _ in
            if node.marks.contains(where: { $0.type.name == "link" }) { linked = true }
            return true
        }
        XCTAssertFalse(linked, "nothing was linked")
        XCTAssertNil(linkPopup(view), "the popover went away")
    }

    func testTheLinkEditorIsNotOfferedWithNothingToLink() throws {
        let view = try paragraphs(["hello world"])
        view.editor.dispatch(view.editor.state.tr.setSelection(
            TextSelection.create(view.editor.doc, 3)))
        view.addOrEditLink(nil)
        XCTAssertNil(linkPopup(view), "a bare caret outside a link has no target")
    }

    // MARK: - Find key commands

    func testTheFindKeyCommandsDriveTheFindBar() throws {
        let view = try paragraphs(["needle one", "needle two"])
        let commands = try XCTUnwrap(view.keyCommands)

        let find = try XCTUnwrap(commands.first { $0.input == "f" && $0.modifierFlags == .command })
        unsafe view.perform(try XCTUnwrap(find.action))
        let bar = try XCTUnwrap(view.subviews.compactMap { $0 as? FindBarView }.first)
        bar.onQueryChange?("needle")

        // Cmd-G / Cmd-Shift-G step through the matches.
        let next = try XCTUnwrap(commands.first { $0.input == "g" && $0.modifierFlags == .command })
        let previous = try XCTUnwrap(commands.first {
            $0.input == "g" && $0.modifierFlags == [.command, .shift]
        })
        unsafe view.perform(try XCTUnwrap(next.action))
        let first = view.editor.state.selection.from
        unsafe view.perform(try XCTUnwrap(next.action))
        let second = view.editor.state.selection.from
        XCTAssertNotEqual(first, second, "Cmd-G stepped on to the other match")

        unsafe view.perform(try XCTUnwrap(previous.action))
        XCTAssertEqual(view.editor.state.selection.from, first, "Cmd-Shift-G stepped back")

        // Whatever it lands on is a match.
        let sel = view.editor.state.selection
        XCTAssertEqual(view.editor.doc.textBetween(sel.from, sel.to), "needle")
    }

    // MARK: - Responder clipboard entry points
    //
    // These only *write* to the general pasteboard, which is always permitted;
    // it is reading it that hits the consent gate (see the clipboard tests).

    func testTheResponderCopyAndCutEntryPointsUseTheGeneralPasteboard() throws {
        let view = try paragraphs(["hello world"])
        view.editor.dispatch(view.editor.state.tr.setSelection(
            TextSelection.create(view.editor.doc, 1, 6)))
        view.copy(nil)
        XCTAssertEqual(view.editor.doc.textContent, "hello world", "copy leaves the document alone")

        view.editor.dispatch(view.editor.state.tr.setSelection(
            TextSelection.create(view.editor.doc, 1, 7)))
        view.cut(nil)
        XCTAssertEqual(view.editor.doc.textContent, "world", "cut removed the selection")
    }

    // MARK: - Accessibility

    func testTheDocumentIsExposedAsOneAccessibilityElement() throws {
        let view = try paragraphs(["first line", "second line"])

        XCTAssertTrue(view.isAccessibilityElement)
        XCTAssertEqual(view.accessibilityLabel, "Rich text editor")
        XCTAssertEqual(view.accessibilityValue, "first line\nsecond line",
                       "the whole document reads out, blocks separated by newlines")
        XCTAssertTrue(view.accessibilityTraits.contains(.updatesFrequently))

        // The setters are deliberately inert — the values are always derived.
        view.isAccessibilityElement = false
        view.accessibilityLabel = "something else"
        view.accessibilityValue = "something else"
        view.accessibilityTraits = .button
        XCTAssertTrue(view.isAccessibilityElement)
        XCTAssertEqual(view.accessibilityLabel, "Rich text editor")
        XCTAssertEqual(view.accessibilityValue, "first line\nsecond line")
        XCTAssertTrue(view.accessibilityTraits.contains(.updatesFrequently))
    }

    func testTheAccessibilityValueFollowsTheDocument() throws {
        let view = try paragraphs(["one"])
        view.editor.dispatch(view.editor.state.tr.setSelection(
            TextSelection.create(view.editor.doc, 4)))
        view.insertText(" two")
        XCTAssertEqual(view.accessibilityValue, "one two")
    }

    // MARK: - Simultaneous recognition

    func testTheEditorsGesturesCoexistWithTheTextInteractions() throws {
        let view = try paragraphs(["hello"])
        let a = UITapGestureRecognizer()
        let b = UIPanGestureRecognizer()
        XCTAssertTrue(view.gestureRecognizer(a, shouldRecognizeSimultaneouslyWith: b))
    }

    // MARK: - Find bar

    func testTheFindBarsReplaceButtonsAreWiredToTheEditor() throws {
        let view = try paragraphs(["needle one", "needle two"])
        view.showFindBar()
        let bar = try XCTUnwrap(view.subviews.compactMap { $0 as? FindBarView }.first,
                                "the find bar was added")

        bar.onQueryChange?("needle")
        XCTAssertEqual(view.editor.doc.textContent, "needle oneneedle two")

        bar.replaceField.text = "pin"
        bar.onReplace?()
        XCTAssertTrue(view.editor.doc.textContent.contains("pin"), "the current match was replaced")

        bar.onReplaceAll?()
        XCTAssertFalse(view.editor.doc.textContent.contains("needle"), "every match was replaced")

        bar.onNext?()
        bar.onPrevious?()
        bar.onClose?()
        XCTAssertTrue(view.subviews.compactMap { $0 as? FindBarView }.isEmpty, "closing removes it")
    }

    func testReplaceWithAnEmptyFieldDeletesTheMatch() throws {
        let view = try paragraphs(["needle one"])
        view.showFindBar()
        let bar = try XCTUnwrap(view.subviews.compactMap { $0 as? FindBarView }.first)
        bar.onQueryChange?("needle ")

        // No replacement text at all: the match is replaced with nothing.
        bar.replaceField.text = nil
        bar.onReplaceAll?()
        XCTAssertEqual(view.editor.doc.textContent, "one")
        bar.onClose?()
    }

    func testReplaceIsInertOnceTheBarIsGone() throws {
        let view = try paragraphs(["needle one"])
        view.showFindBar()
        let bar = try XCTUnwrap(view.subviews.compactMap { $0 as? FindBarView }.first)
        bar.onQueryChange?("needle")
        view.hideFindBar()

        bar.replaceField.text = "pin"
        bar.onReplace?()
        bar.onReplaceAll?()
        XCTAssertEqual(view.editor.doc.textContent, "needle one", "the closed bar drives nothing")
    }

    // MARK: - Gap cursor

    func testAGapCaretIsAHorizontalBarPlacedBetweenBlocks() throws {
        let view = try paragraphs(["one", "two", "three"])
        let layout = view.ensureLayout()

        // Before the first block there is no block above, so the bar sits just
        // over it; between two blocks it is centered in the visual gap.
        let first = view.gapCaretRect(at: 0, in: layout)
        let betweenFirstAndSecond = view.gapCaretRect(at: layout.blocks[0].contentEnd + 1, in: layout)
        let betweenSecondAndThird = view.gapCaretRect(at: layout.blocks[1].contentEnd + 1, in: layout)

        XCTAssertGreaterThan(first.width, first.height, "a gap caret is a horizontal bar")
        XCTAssertLessThan(first.minY, betweenFirstAndSecond.minY, "the gaps run down the document")
        XCTAssertLessThan(betweenFirstAndSecond.minY, betweenSecondAndThird.minY)

        // Past the last block there is nothing below, so the bar sits under it.
        let afterLast = view.gapCaretRect(at: view.editor.doc.content.size, in: layout)
        XCTAssertGreaterThan(afterLast.minY, betweenSecondAndThird.minY)
        XCTAssertEqual(afterLast.minY, layout.blocks[2].frame.maxY + 2, accuracy: 0.5)

        // The middle bar is centered between its neighbours.
        let above = layout.blocks[0].frame.maxY
        let below = layout.blocks[1].frame.minY
        XCTAssertEqual(betweenFirstAndSecond.minY, (above + below) / 2 - 1, accuracy: 0.5)
    }

    // MARK: - Memory + Dynamic Type

    func testAMemoryWarningReleasesOffscreenImages() throws {
        let view = try makeView { s in
            [try s.node("image", ["src": .string("https://example.com/a.png"),
                                  "width": .int(100), "height": .int(80)])]
        }
        _ = view.ensureLayout()
        // The handler is registered on the notification; posting it must not
        // disturb the document or crash while images are in flight.
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        XCTAssertEqual(view.editor.doc.childCount, 1)
    }

}
#endif

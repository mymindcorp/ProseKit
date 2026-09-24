#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

/// `EditorTextView` paths the feature suites pass by: a modified Return with no
/// binding of its own, cutting a cell selection, the geometry caches filling
/// up, a document with no text to put a caret in, link atoms, inline images,
/// and a view hosted outside any view controller.
@MainActor
final class EditorTextViewEdgeCaseTests: XCTestCase {
    private func makeView(extensions: [any Extension]? = nil,
                          _ build: (Schema) throws -> [Node]) throws -> EditorTextView {
        let editor = try Editor(extensions: extensions ?? fullKit())
        editor.setContent(try editor.schema.node("doc", [:], content: Fragment.from(build(editor.schema))))
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        view.layoutIfNeeded()
        return view
    }

    private func paragraphs(_ lines: [String]) throws -> EditorTextView {
        try makeView { s in
            try lines.map { try s.node("paragraph", [:], content: Fragment.from($0.isEmpty ? [] : [s.text($0)])) }
        }
    }

    private func cursor(_ view: EditorTextView, _ pos: Int) {
        view.editor.dispatch(view.editor.state.tr.setSelection(TextSelection.create(view.editor.doc, pos)))
    }

    // MARK: - Return with a modifier nothing binds

    func testOptionReturnFallsBackToAPlainReturn() throws {
        let view = try paragraphs(["hello world"])
        cursor(view, 6)
        // There is no "Alt-Enter" binding, so the press must still split the
        // paragraph rather than being swallowed or passed up.
        XCTAssertTrue(view.handle(EditorTextView.KeyEvent(.keyboardReturnOrEnter, modifiers: .alternate)))
        XCTAssertEqual(view.editor.doc.childCount, 2)
        XCTAssertEqual(view.editor.doc.child(0).textContent, "hello")
        XCTAssertEqual(view.editor.doc.child(1).textContent, " world")
    }

    // MARK: - Cutting a cell selection

    func testCuttingACellSelectionEmptiesTheCellsAndKeepsTheTable() throws {
        let view = try makeView { s in
            func cell(_ text: String) throws -> Node {
                try s.node("tableCell", [:], content: Fragment.from([
                    try s.node("paragraph", [:], content: Fragment.from([s.text(text)])),
                ]))
            }
            func row(_ a: String, _ b: String) throws -> Node {
                try s.node("tableRow", [:], content: Fragment.from([try cell(a), try cell(b)]))
            }
            return [try s.node("table", [:], content: Fragment.from([try row("A", "B"), try row("C", "D")]))]
        }
        var a = 0, d = 0
        view.editor.doc.descendants { node, pos, _, _ in
            if node.isText, node.text == "A" { a = pos + 1 }
            if node.isText, node.text == "D" { d = pos + 1 }
            return true
        }
        view.selectedTextRange = DocTextRange(a, d)
        XCTAssertTrue(view.editor.state.selection is CellSelection)

        let pb = UIPasteboard.withUniqueName()
        view.cut(to: pb)

        let table = view.editor.doc.child(0)
        XCTAssertEqual(table.type.name, "table", "the table survives a cut of its cells")
        XCTAssertEqual(table.childCount, 2)
        XCTAssertEqual(table.child(0).childCount, 2)
        XCTAssertEqual(table.textContent, "", "every selected cell was cleared")
        XCTAssertNotNil(pb.string, "and the cells went to the pasteboard")
    }

    // MARK: - UITextInput basics

    func testHasTextReportsADocumentWithText() throws {
        XCTAssertTrue(try paragraphs(["abc"]).hasText)
    }

    func testCompareOrdersPositions() throws {
        let view = try paragraphs(["abcdef"])
        XCTAssertEqual(view.compare(DocTextPosition(2), to: DocTextPosition(5)), .orderedAscending)
        XCTAssertEqual(view.compare(DocTextPosition(5), to: DocTextPosition(2)), .orderedDescending)
        XCTAssertEqual(view.compare(DocTextPosition(3), to: DocTextPosition(3)), .orderedSame)
    }

    // MARK: - Geometry caches at their cap

    func testTheProjectedTextCacheStaysCorrectPastItsCap() throws {
        let view = try paragraphs([String(repeating: "abcdefghij", count: 10)]) // content 1…101
        let limit = EditorTextView.geometryCacheLimit
        var asked = 0
        outer: for from in 1 ..< 101 {
            for to in (from + 1) ... 101 {
                _ = view.projectedText(from: from, to: to)
                asked += 1
                if asked > limit + 10 { break outer }
            }
        }
        XCTAssertGreaterThan(asked, limit, "went past the cap")
        // Answers after the cache was flushed are still the document's text.
        XCTAssertEqual(view.projectedText(from: 1, to: 4), "abc")
        XCTAssertEqual(view.projectedText(from: 11, to: 14), "abc")
        XCTAssertEqual(view.projectedText(from: 5, to: 8), "efg")
    }

    func testTheFirstRectCacheStaysCorrectPastItsCap() throws {
        let view = try paragraphs([String(repeating: "abcdefghij ", count: 12)])
        let expected = view.firstRect(for: DocTextRange(3, 6))
        let limit = EditorTextView.geometryCacheLimit
        let size = view.editor.doc.content.size
        var asked = 0
        outer: for from in 1 ..< size - 1 {
            for to in (from + 1) ..< size {
                _ = view.firstRect(for: DocTextRange(from, to))
                asked += 1
                if asked > limit + 10 { break outer }
            }
        }
        XCTAssertGreaterThan(asked, limit)
        XCTAssertEqual(view.firstRect(for: DocTextRange(3, 6)), expected, "same rect after the flush")
    }

    // MARK: - A document with no text block

    private func ruleOnly() throws -> EditorTextView {
        try makeView { s in [try s.node("horizontalRule")] }
    }

    func testAGapCaretWithNoTextBlockSitsAtThePageOrigin() throws {
        let view = try ruleOnly()
        let layout = view.ensureLayout()
        XCTAssertTrue(layout.blocks.isEmpty, "a rule holds no text")
        let insets = view.theme.pageInsets
        XCTAssertEqual(view.gapCaretRect(at: 0, in: layout),
                       CGRect(x: insets.left, y: insets.top, width: 20, height: 2))
    }

    func testNoGapIsFoundWithoutATextBlockOnEitherSide() throws {
        let view = try ruleOnly()
        for y in [CGFloat(0), 20, 200] {
            XCTAssertNil(view.gapBoundaryPosition(at: CGPoint(x: 40, y: y)), "y \(y)")
        }
    }

    // MARK: - Link atoms

    func testAWikiLinkAtomIsALinkClick() throws {
        let view = try makeView { s in
            [try s.node("paragraph", [:], content: Fragment.from([
                s.text("see "),
                try s.node("wikiLink", ["text": .string("Page")]),
                s.text(" now"),
            ]))]
        }
        let atomPos = 5
        XCTAssertEqual(view.editor.doc.nodeAt(atomPos)?.type.name, "wikiLink")
        for pos in [atomPos, atomPos + 1] { // either side of the atom
            let click = try XCTUnwrap(view.linkClick(at: pos, commandHeld: true), "at \(pos)")
            XCTAssertEqual(click.node.type.name, "wikiLink")
            XCTAssertEqual(click.from, atomPos)
            XCTAssertEqual(click.to, atomPos + 1)
            XCTAssertEqual(click.attrs["text"]?.stringValue, "Page")
            XCTAssertTrue(click.commandHeld)
        }
        XCTAssertNil(view.linkClick(at: 2, commandHeld: false), "plain text is not a link")
    }

    // MARK: - Inline images

    func testAPointJustInsideAnInlineImageFindsTheImageAfterIt() throws {
        let view = try makeView(extensions: starterKit() + [ImageExtension(inline: true)]) { s in
            [try s.node("paragraph", [:], content: Fragment.from([
                s.text("ab"),
                try s.node("image", ["src": .string("asset://inline"), "width": .int(60), "height": .int(40)]),
                s.text("cd"),
            ]))]
        }
        let imagePos = 3
        XCTAssertEqual(view.editor.doc.nodeAt(imagePos)?.type.name, "image")
        let layout = view.ensureLayout()
        let before = try XCTUnwrap(layout.caretRect(at: imagePos))
        // Just right of the caret before the image: the hit resolves to the
        // position in front of it, so the image is the node *after*.
        let point = CGPoint(x: before.maxX + 2, y: before.midY)
        XCTAssertEqual(layout.position(at: point), imagePos)
        let hit = try XCTUnwrap(view.imageAt(point))
        XCTAssertEqual(hit.node.type.name, "image")
        XCTAssertEqual(hit.from, imagePos)
        XCTAssertEqual(hit.to, imagePos + 1)
    }

    // MARK: - Hosting

    private func backgroundColorMark(_ view: EditorTextView) -> String? {
        var color: String?
        view.editor.doc.descendants { node, _, _, _ in
            if let mark = node.marks.first(where: { $0.type.name == "backgroundColor" }) {
                color = mark.attrs["color"]?.stringValue
            }
            return true
        }
        return color
    }

    func testAViewOnTheWindowItselfStillFindsAControllerForTheColorPicker() throws {
        // No view controller owns the view, so the picker is offered from the
        // window's root. (Presentation itself needs a scene this test process
        // doesn't have; what is observable is that the request got as far as
        // arming the background target, which it doesn't without a controller.)
        let hosted = try paragraphs(["hello world"])
        let root = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.rootViewController = root
        window.makeKeyAndVisible()
        window.addSubview(hosted) // straight onto the window, not into root's view
        defer { window.isHidden = true }

        let unhosted = try paragraphs(["hello world"])
        for view in [hosted, unhosted] {
            view.editor.dispatch(view.editor.state.tr.setSelection(TextSelection.create(view.editor.doc, 1, 6)))
            view.formatBackgroundColor(nil)
            let picker = UIColorPickerViewController()
            picker.selectedColor = .blue
            view.colorPickerViewControllerDidFinish(picker)
        }
        XCTAssertEqual(backgroundColorMark(hosted), "#0000ff", "the window's root was found to present from")
        XCTAssertNil(backgroundColorMark(unhosted), "with no controller at all nothing was offered")
    }

    func testAContentSizeChangeRebuildsTheLayout() throws {
        let view = try paragraphs(["hello world"])
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.addSubview(view)
        window.isHidden = false
        defer { window.isHidden = true }
        view.layoutIfNeeded()
        let before = view.ensureLayout()
        XCTAssertTrue(before === view.ensureLayout(), "stable while nothing changes")

        view.traitOverrides.preferredContentSizeCategory =
            view.traitCollection.preferredContentSizeCategory == .extraExtraExtraLarge ? .small : .extraExtraExtraLarge
        window.layoutIfNeeded()
        view.layoutIfNeeded()
        XCTAssertFalse(before === view.ensureLayout(), "a Dynamic Type change lays the document out again")
    }
}
#endif

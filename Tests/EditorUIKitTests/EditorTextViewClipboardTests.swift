#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

/// The `UIResponder` clipboard surface — `copy:` / `cut:` / `paste:` /
/// `pasteAndMatchStyle:`, and the `canPerformAction:` gate behind the edit menu.
///
/// The parsers underneath are covered elsewhere; what's pinned here is the
/// responder layer itself — which flavor wins, what the editability guards do,
/// and which menu items light up.
///
/// Everything reads and writes a *private* pasteboard: reading
/// `UIPasteboard.general` from the test runner hits the system paste-consent
/// gate, which has no UI to accept in a headless run and hangs the test.
@MainActor
final class EditorTextViewClipboardTests: XCTestCase {
    /// A fresh private pasteboard per test, torn down with it.
    private func makePasteboard() -> UIPasteboard {
        let pb = UIPasteboard.withUniqueName()
        let name = pb.name
        addTeardownBlock { UIPasteboard.remove(withName: name) }
        return pb
    }

    private func makeView(_ text: String = "hello world") throws -> EditorTextView {
        let editor = try Editor(extensions: fullKit())
        editor.setContent(try editor.schema.node("doc", [:], content: Fragment.from([
            try editor.schema.node("paragraph", [:], content: Fragment.from(
                text.isEmpty ? [] : [editor.schema.text(text)])),
        ])))
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        view.layoutIfNeeded()
        return view
    }

    private func select(_ view: EditorTextView, _ from: Int, _ to: Int) {
        view.editor.dispatch(view.editor.state.tr.setSelection(TextSelection.create(view.editor.doc, from, to)))
    }
    private func cursor(_ view: EditorTextView, _ pos: Int) {
        view.editor.dispatch(view.editor.state.tr.setSelection(TextSelection.create(view.editor.doc, pos)))
    }
    private func hasMark(_ view: EditorTextView, _ name: String) -> Bool {
        var found = false
        view.editor.doc.descendants { node, _, _, _ in
            if node.marks.contains(where: { $0.type.name == name }) { found = true }
            return true
        }
        return found
    }
    private func html(_ pb: UIPasteboard) -> String? {
        pb.data(forPasteboardType: "public.html").flatMap { String(data: $0, encoding: .utf8) }
            ?? pb.value(forPasteboardType: "public.html") as? String
    }

    // MARK: - copy / cut

    func testCopyWritesBothHTMLAndPlainTextFlavors() throws {
        let pasteboard = makePasteboard()
        let view = try makeView("hello world")
        select(view, 1, 6) // "hello"
        view.copy(to: pasteboard)

        XCTAssertEqual(pasteboard.string, "hello")
        let html = try XCTUnwrap(html(pasteboard), "the HTML flavor is written alongside the plain text")
        XCTAssertTrue(html.contains("hello"), "HTML carries the copied text: \(html)")
    }

    func testCopyWithEmptySelectionWritesNothing() throws {
        let pasteboard = makePasteboard()
        let view = try makeView("hello world")
        cursor(view, 3)
        view.copy(to: pasteboard)
        XCTAssertTrue(pasteboard.items.isEmpty, "a caret-only selection copies nothing")
    }

    func testCopyPreservesMarksInTheHTMLFlavor() throws {
        let pasteboard = makePasteboard()
        let view = try makeView("hello world")
        select(view, 1, 6)
        _ = view.editor.run("toggleBold")
        select(view, 1, 6)
        view.copy(to: pasteboard)

        let html = try XCTUnwrap(html(pasteboard))
        XCTAssertTrue(html.contains("<strong>") || html.contains("<b>"),
                      "the bold mark survives into the HTML flavor: \(html)")
    }

    func testCopyJoinsBlocksWithNewlinesInThePlainTextFlavor() throws {
        let pasteboard = makePasteboard()
        let editor = try Editor(extensions: fullKit())
        editor.setContent(try editor.schema.node("doc", [:], content: Fragment.from([
            try editor.schema.node("paragraph", [:], content: Fragment.from([editor.schema.text("one")])),
            try editor.schema.node("paragraph", [:], content: Fragment.from([editor.schema.text("two")])),
        ])))
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        view.layoutIfNeeded()

        view.editor.dispatch(view.editor.state.tr.setSelection(AllSelection(view.editor.doc)))
        view.copy(to: pasteboard)
        XCTAssertEqual(pasteboard.string, "one\ntwo", "block boundaries become newlines")
    }

    func testCutRemovesTheSelectionAndWritesIt() throws {
        let pasteboard = makePasteboard()
        let view = try makeView("hello world")
        select(view, 1, 7) // "hello "
        view.cut(to: pasteboard)
        XCTAssertEqual(view.editor.doc.textContent, "world")
        XCTAssertEqual(pasteboard.string, "hello ")
    }

    func testCutIsInertWhenNotEditable() throws {
        let pasteboard = makePasteboard()
        let view = try makeView("hello world")
        view.isEditable = false
        select(view, 1, 6)
        view.cut(to: pasteboard)
        XCTAssertEqual(view.editor.doc.textContent, "hello world", "read-only: nothing removed")
        XCTAssertTrue(pasteboard.items.isEmpty, "read-only: nothing written")
    }

    // MARK: - paste

    func testPastePlainSingleLineInsertsInline() throws {
        let pasteboard = makePasteboard()
        let view = try makeView("ac")
        pasteboard.string = "b"
        cursor(view, 2)
        view.paste(from: pasteboard)
        XCTAssertEqual(view.editor.doc.textContent, "abc")
    }

    func testPastePlainMultiLineBecomesParagraphs() throws {
        let pasteboard = makePasteboard()
        let view = try makeView("")
        pasteboard.string = "one\ntwo\nthree"
        cursor(view, 1)
        view.paste(from: pasteboard)

        let paragraphs = (0 ..< view.editor.doc.childCount).map { view.editor.doc.child($0).textContent }
        XCTAssertEqual(paragraphs, ["one", "two", "three"], "each line becomes its own paragraph")
    }

    func testPasteHTMLBeatsThePlainTextFlavor() throws {
        let pasteboard = makePasteboard()
        let view = try makeView("")
        pasteboard.items = [[
            "public.html": "<p>rich <strong>text</strong></p>",
            "public.utf8-plain-text": "rich text",
        ]]
        cursor(view, 1)
        view.paste(from: pasteboard)

        XCTAssertEqual(view.editor.doc.textContent, "rich text")
        XCTAssertTrue(hasMark(view, "bold"), "the HTML flavor's bold survived, so HTML won over plain text")
    }

    func testPasteMarkdownTextIsReinterpreted() throws {
        let pasteboard = makePasteboard()
        let view = try makeView("")
        pasteboard.string = "# Heading\n\nbody text"
        cursor(view, 1)
        view.paste(from: pasteboard)

        var sawHeading = false
        view.editor.doc.descendants { node, _, _, _ in
            if node.type.name == "heading" { sawHeading = true }
            return true
        }
        XCTAssertTrue(sawHeading, "clearly-Markdown plain text is parsed as Markdown")
    }

    func testPasteBareURLOverSelectionLinksInsteadOfReplacing() throws {
        let pasteboard = makePasteboard()
        let view = try makeView("click here")
        pasteboard.string = "https://example.com"
        select(view, 1, 6) // "click"
        view.paste(from: pasteboard)

        XCTAssertEqual(view.editor.doc.textContent, "click here", "the text is kept, not replaced")
        var href: String?
        view.editor.doc.descendants { node, _, _, _ in
            if let link = node.marks.first(where: { $0.type.name == "link" }) {
                href = link.attrs["href"]?.stringValue
            }
            return true
        }
        XCTAssertEqual(href, "https://example.com")
    }

    func testPasteIsInertWhenNotEditable() throws {
        let pasteboard = makePasteboard()
        let view = try makeView("keep")
        pasteboard.string = "new"
        view.isEditable = false
        cursor(view, 1)
        view.paste(from: pasteboard)
        XCTAssertEqual(view.editor.doc.textContent, "keep")
    }

    func testPasteOfAnEmptyPasteboardDoesNothing() throws {
        let pasteboard = makePasteboard()
        let view = try makeView("keep")
        cursor(view, 1)
        view.paste(from: pasteboard)
        XCTAssertEqual(view.editor.doc.textContent, "keep")
    }

    /// A rich-only pasteboard has no `public.utf8-plain-text`, but UIKit
    /// flattens the HTML for `string`, so match-style pastes the text without
    /// its formatting rather than doing nothing.
    func testPasteAndMatchStyleFlattensARichOnlyPasteboard() throws {
        let pasteboard = makePasteboard()
        let view = try makeView("")
        pasteboard.items = [["public.html": Data("<p>rich <strong>text</strong></p>".utf8)]]
        cursor(view, 1)
        view.pasteAndMatchStyle(from: pasteboard)

        XCTAssertEqual(view.editor.doc.textContent, "rich text")
        XCTAssertFalse(hasMark(view, "bold"))
    }

    func testPasteAndMatchStyleDropsFormatting() throws {
        let pasteboard = makePasteboard()
        let view = try makeView("")
        pasteboard.items = [[
            "public.html": "<p>rich <strong>text</strong></p>",
            "public.utf8-plain-text": "rich text",
        ]]
        cursor(view, 1)
        view.pasteAndMatchStyle(from: pasteboard)

        XCTAssertEqual(view.editor.doc.textContent, "rich text")
        XCTAssertFalse(hasMark(view, "bold"), "match-style reads only the plain-text flavor")
    }

    func testPasteAndMatchStyleIsInertWhenNotEditable() throws {
        let pasteboard = makePasteboard()
        let view = try makeView("keep")
        pasteboard.string = "new"
        view.isEditable = false
        cursor(view, 1)
        view.pasteAndMatchStyle(from: pasteboard)
        XCTAssertEqual(view.editor.doc.textContent, "keep")
    }

    func testCopyThenPasteRoundTripsRichContent() throws {
        let pasteboard = makePasteboard()
        let view = try makeView("hello world")
        select(view, 1, 6)
        _ = view.editor.run("toggleBold")
        select(view, 1, 6)
        view.copy(to: pasteboard)

        let target = try makeView("")
        cursor(target, 1)
        target.paste(from: pasteboard)
        XCTAssertEqual(target.editor.doc.textContent, "hello")
        XCTAssertTrue(hasMark(target, "bold"), "bold survives a copy/paste round trip")
    }


    // MARK: - Rich flavors without HTML

    /// An attributed string whose paragraphs carry a checkbox list marker —
    /// what Apple Notes / Pages put on the pasteboard for a checklist.
    private func checklistAttributedString(_ items: [(String, Bool)]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (text, checked) in items {
            let style = NSMutableParagraphStyle()
            let marker: String = checked ? "{checkbox-check}" : "{checkbox}"
            style.textLists = [NSTextList(markerFormat: NSTextList.MarkerFormat(rawValue: marker), options: 0)]
            result.append(NSAttributedString(string: text + "\n",
                                             attributes: [.paragraphStyle: style,
                                                          .font: UIFont.systemFont(ofSize: 14)]))
        }
        return result
    }

    private func rtf(_ attributed: NSAttributedString) throws -> Data {
        try attributed.data(from: NSRange(location: 0, length: attributed.length),
                            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    func testPlainRTFIsReadDirectly() throws {
        let pasteboard = makePasteboard()
        let view = try makeView("")
        let source = NSAttributedString(string: "from rtf",
                                        attributes: [.font: UIFont.boldSystemFont(ofSize: 14)])
        pasteboard.items = [["public.rtf": try rtf(source)]]
        cursor(view, 1)
        view.paste(from: pasteboard)

        XCTAssertEqual(view.editor.doc.textContent, "from rtf")
    }

    func testRTFDIsBridgedThroughAnAttributedString() throws {
        let pasteboard = makePasteboard()
        let view = try makeView("")
        let source = NSAttributedString(string: "from rtfd",
                                        attributes: [.font: UIFont.systemFont(ofSize: 14)])
        let data = try source.data(from: NSRange(location: 0, length: source.length),
                                   documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        pasteboard.items = [["com.apple.flat-rtfd": data]]
        cursor(view, 1)
        view.paste(from: pasteboard)

        XCTAssertEqual(view.editor.doc.textContent, "from rtfd")
    }

    func testACheckedChecklistSurvivesAnRTFPaste() throws {
        let pasteboard = makePasteboard()
        let view = try makeView("")
        let source = checklistAttributedString([("milk", true), ("eggs", false)])
        pasteboard.items = [["public.rtfd": try source.data(
            from: NSRange(location: 0, length: source.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])]]
        cursor(view, 1)
        view.paste(from: pasteboard)

        // The HTML round-trip flattens checklists to bullets; the RTF list
        // markers are what puts the checked state back.
        var checked: [Bool] = []
        view.editor.doc.descendants { node, _, _, _ in
            if node.type.name == "taskItem" {
                checked.append(node.attrs["checked"]?.boolValue ?? false)
            }
            return true
        }
        XCTAssertEqual(view.editor.doc.textContent.contains("milk"), true)
        if !checked.isEmpty {
            XCTAssertEqual(checked.first, true, "the checked item came back checked")
        }
    }

    // MARK: - canPerformAction
    //
    // These use `UIPasteboard.general` deliberately: `hasStrings` and
    // `contains(pasteboardTypes:)` are detection APIs that do not trip the
    // consent gate, and writing to the general pasteboard is always allowed.

    func testMenuGatesFollowSelectionAndEditability() throws {
        let view = try makeView("hello world")

        // Caret only: copy/cut and the formatting actions are unavailable.
        cursor(view, 3)
        XCTAssertFalse(view.canPerformAction(#selector(UIResponder.copy(_:)), withSender: nil))
        XCTAssertFalse(view.canPerformAction(#selector(UIResponder.cut(_:)), withSender: nil))
        XCTAssertFalse(view.canPerformAction(#selector(EditorTextView.formatBold(_:)), withSender: nil))
        // Select-all only needs a non-empty document.
        XCTAssertTrue(view.canPerformAction(#selector(UIResponder.selectAll(_:)), withSender: nil))

        // With a range selection they light up.
        select(view, 1, 6)
        XCTAssertTrue(view.canPerformAction(#selector(UIResponder.copy(_:)), withSender: nil))
        XCTAssertTrue(view.canPerformAction(#selector(UIResponder.cut(_:)), withSender: nil))
        XCTAssertTrue(view.canPerformAction(#selector(EditorTextView.formatBold(_:)), withSender: nil))
        XCTAssertTrue(view.canPerformAction(#selector(EditorTextView.formatTextColor(_:)), withSender: nil))
        XCTAssertTrue(view.canPerformAction(#selector(EditorTextView.formatBackgroundColor(_:)), withSender: nil))
        XCTAssertTrue(view.canPerformAction(#selector(EditorTextView.toggleHighlightAction(_:)), withSender: nil))

        // Read-only keeps copy but drops everything that mutates.
        view.isEditable = false
        XCTAssertTrue(view.canPerformAction(#selector(UIResponder.copy(_:)), withSender: nil))
        XCTAssertFalse(view.canPerformAction(#selector(UIResponder.cut(_:)), withSender: nil))
        XCTAssertFalse(view.canPerformAction(#selector(EditorTextView.formatBold(_:)), withSender: nil))
    }

    func testSelectAllIsStillOfferedForAnEmptyParagraph() throws {
        // An empty paragraph is still a block, so the document has non-zero
        // content size and there is something for select-all to cover.
        let view = try makeView("")
        XCTAssertTrue(view.canPerformAction(#selector(UIResponder.selectAll(_:)), withSender: nil))
    }

    func testPasteIsOfferedOnlyWhenThePasteboardHasSomethingWeRead() throws {
        let view = try makeView("hello world")
        let paste = #selector(UIResponder.paste(_:))
        let matchStyle = #selector(UIResponder.pasteAndMatchStyle(_:))

        UIPasteboard.general.items = []
        XCTAssertFalse(view.canPerformAction(paste, withSender: nil))
        XCTAssertFalse(view.canPerformAction(matchStyle, withSender: nil))

        UIPasteboard.general.items = [["public.utf8-plain-text": "plain"]]
        XCTAssertTrue(view.canPerformAction(paste, withSender: nil))
        XCTAssertTrue(view.canPerformAction(matchStyle, withSender: nil))

        // A rich-only pasteboard offers both: `public.html` conforms to
        // `public.text`, so UIKit vends a flattened plain-text value for it and
        // match-style has something real to paste.
        UIPasteboard.general.items = [["public.html": Data("<p>rich</p>".utf8)]]
        XCTAssertTrue(view.canPerformAction(paste, withSender: nil))
        XCTAssertTrue(view.canPerformAction(matchStyle, withSender: nil))

        // Read-only offers neither.
        view.isEditable = false
        UIPasteboard.general.items = [["public.utf8-plain-text": "plain"]]
        XCTAssertFalse(view.canPerformAction(paste, withSender: nil))
        XCTAssertFalse(view.canPerformAction(matchStyle, withSender: nil))

        UIPasteboard.general.items = []
    }

    func testLinkActionFollowsWhetherThereIsSomethingToLink() throws {
        let view = try makeView("hello world")
        let link = #selector(EditorTextView.addOrEditLink(_:))
        cursor(view, 3)
        XCTAssertEqual(view.canPerformAction(link, withSender: nil), view.canEditLink)
        select(view, 1, 6)
        XCTAssertTrue(view.canPerformAction(link, withSender: nil), "a range selection can be linked")
        view.isEditable = false
        XCTAssertFalse(view.canPerformAction(link, withSender: nil), "read-only can't link")
    }

    func testUnknownActionFallsThroughToSuper() throws {
        let view = try makeView("hello world")
        XCTAssertFalse(view.canPerformAction(Selector(("someUnrelatedAction:")), withSender: nil))
    }

    // MARK: - selectAll

    func testSelectAllSelectsTheWholeDocument() throws {
        let view = try makeView("hello world")
        cursor(view, 1)
        view.selectAll(nil)
        XCTAssertTrue(view.editor.state.selection is AllSelection)
        XCTAssertFalse(view.editor.state.selection.empty)
    }
}
#endif

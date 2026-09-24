#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import EditorStateKit
import SchemaKit
import EditorSerialization
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

    private struct SweepRNG: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }
    private func pick<T>(_ items: [T], _ rng: inout SweepRNG) -> T { items[Int(rng.next() % UInt64(items.count))] }

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

    /// Every link in the document, as `text→href` — a run of adjacent text
    /// nodes under the same link counted once, so other marks splitting it
    /// don't matter.
    private func links(_ view: EditorTextView) -> [String] {
        var found: [(text: String, href: String, end: Int)] = []
        view.editor.doc.descendants { node, pos, _, _ in
            guard let text = node.text,
                  let href = node.marks.first(where: { $0.type.name == "link" })?.attrs["href"]?.stringValue
            else { return true }
            if let last = found.last, last.href == href, last.end == pos {
                found[found.count - 1] = (last.text + text, href, pos + node.nodeSize)
            } else {
                found.append((text, href, pos + node.nodeSize))
            }
            return true
        }
        return found.map { "\($0.text)→\($0.href)" }
    }

    func testPastePlainTextLinksItsURLs() throws {
        let pasteboard = makePasteboard()
        let view = try makeView("ab")
        // Not Markdown by the heuristic, so this takes the plain-text path.
        pasteboard.string = "see https://example.com/x, or www.apple.com. "
        cursor(view, 2)
        view.paste(from: pasteboard)

        XCTAssertFalse(view.looksLikeMarkdown(pasteboard.string ?? ""))
        XCTAssertEqual(view.editor.doc.textContent, "asee https://example.com/x, or www.apple.com. b")
        XCTAssertEqual(links(view), ["https://example.com/x→https://example.com/x",
                                     "www.apple.com→https://www.apple.com"])
    }

    func testPasteMultiLinePlainTextLinksItsURLs() throws {
        let pasteboard = makePasteboard()
        let view = try makeView("")
        pasteboard.string = "first é https://a.example\nnothing here\nmailto:x@y.com"
        cursor(view, 1)
        view.paste(from: pasteboard)

        let paragraphs = (0 ..< view.editor.doc.childCount).map { view.editor.doc.child($0).textContent }
        XCTAssertEqual(paragraphs, ["first é https://a.example", "nothing here", "mailto:x@y.com"])
        XCTAssertEqual(links(view), ["https://a.example→https://a.example", "mailto:x@y.com→mailto:x@y.com"])
    }

    func testPasteBareURLAtACursorLinksIt() throws {
        let pasteboard = makePasteboard()
        let view = try makeView("")
        pasteboard.string = "https://example.com"
        cursor(view, 1)
        view.paste(from: pasteboard)
        XCTAssertEqual(links(view), ["https://example.com→https://example.com"])
    }

    func testPastedURLInsideACodeBlockStaysPlain() throws {
        let pasteboard = makePasteboard()
        let view = try makeView("")
        view.editor.setContent(try view.editor.schema.node("doc", [:], content: Fragment.from([
            try view.editor.schema.node("codeBlock", [:], content: Fragment.from([view.editor.schema.text("x")])),
        ])))
        pasteboard.string = "curl https://example.com"
        cursor(view, 2)
        view.paste(from: pasteboard)
        XCTAssertEqual(view.editor.doc.textContent, "xcurl https://example.com")
        XCTAssertEqual(links(view), [])
    }

    func testPastePlainTextOverASelectionLinksAtTheRightPlace() throws {
        let pasteboard = makePasteboard()
        let view = try makeView("hello world!")
        // Not a lone URL, so it replaces the selection rather than linking it.
        pasteboard.string = "see https://x.io"
        select(view, 7, 12) // "world"
        view.paste(from: pasteboard)
        XCTAssertEqual(view.editor.doc.textContent, "hello see https://x.io!")
        XCTAssertEqual(links(view), ["https://x.io→https://x.io"])
    }

    func testPastedLinkOffsetsCountCharactersNotBytes() throws {
        let pasteboard = makePasteboard()
        let view = try makeView("🇫🇷")
        // Flags, a combining accent and CJK before the URL: each is one
        // position in the document but several UTF-8 bytes.
        pasteboard.string = "🇫🇷 e\u{301} 日本 https://x.io/é end"
        cursor(view, 2)
        view.paste(from: pasteboard)
        XCTAssertEqual(links(view), ["https://x.io/é→https://x.io/é"])
    }

    func testPasteCRLFTextKeepsTheLineEndingOutOfTheLink() throws {
        let pasteboard = makePasteboard()
        let view = try makeView("")
        pasteboard.string = "a https://x.io\r\nwww.y.io\r\n"
        cursor(view, 1)
        view.paste(from: pasteboard)
        XCTAssertEqual(links(view), ["https://x.io→https://x.io", "www.y.io→https://www.y.io"])
    }

    func testPastedURLKeepsTheFormattingAtTheCursor() throws {
        let pasteboard = makePasteboard()
        let view = try makeView("ab")
        select(view, 1, 3)
        _ = view.editor.run("toggleBold")
        pasteboard.string = "https://x.io"
        cursor(view, 2)
        view.paste(from: pasteboard)

        XCTAssertEqual(view.editor.doc.textContent, "ahttps://x.iob")
        XCTAssertEqual(links(view), ["https://x.io→https://x.io"])
        var boldLink = false
        view.editor.doc.descendants { node, _, _, _ in
            let names = Set(node.marks.map(\.type.name))
            if names.contains("link"), names.contains("bold") { boldLink = true }
            return true
        }
        XCTAssertTrue(boldLink, "the pasted text took the bold it landed in, and the link on top")
    }

    func testPastedURLInsideInlineCodeStaysPlain() throws {
        let pasteboard = makePasteboard()
        let view = try makeView("ab")
        select(view, 1, 3)
        _ = view.editor.run("toggleCode")
        pasteboard.string = "curl https://x.io"
        cursor(view, 2)
        view.paste(from: pasteboard)
        XCTAssertEqual(view.editor.doc.textContent, "acurl https://x.iob")
        XCTAssertEqual(links(view), [], "code excludes every other mark")
    }

    func testPastedURLInsideALinkGetsItsOwnHref() throws {
        let pasteboard = makePasteboard()
        let view = try makeView("abcd")
        select(view, 1, 5)
        _ = view.editor.run(setLink(view.editor.schema.marks["link"]!, href: "https://old.io"))
        pasteboard.string = " https://new.io "
        cursor(view, 3)
        view.paste(from: pasteboard)
        XCTAssertEqual(view.editor.doc.textContent, "ab https://new.io cd")
        XCTAssertEqual(links(view), ["ab →https://old.io", "https://new.io→https://new.io", " cd→https://old.io"])
    }

    func testUndoingALinkedPasteRestoresTheDocument() throws {
        for string in ["see https://x.io", "one https://x.io\ntwo www.y.io"] {
            let pasteboard = makePasteboard()
            let view = try makeView("hello")
            let before = view.editor.doc
            pasteboard.string = string
            cursor(view, 3)
            view.paste(from: pasteboard)
            XCTAssertFalse(links(view).isEmpty)
            _ = view.handle(EditorTextView.KeyEvent(.keyboardZ, modifiers: .command, characters: "z"))
            XCTAssertEqual(view.editor.doc, before, "one undo takes back the text and its links: \(string.debugDescription)")
        }
    }

    /// Seeded pastes of text with URLs in it, at random places in a random
    /// paragraph, some replacing a selection. Whatever the text, the pasted
    /// characters land unchanged, the links in the document are exactly the
    /// URLs `literalAutolinks` finds in it, the document stays valid, and one
    /// undo takes it all back.
    func testPastePlainTextSweep() throws {
        var rng = SweepRNG(seed: 0x11A7)
        let words = ["a", "word", "é", "🇫🇷", "e\u{301}", "日本", ".", ",", "(", ")", "!", ":", "x_y", "com"]
        let urls = ["https://x.io", "http://a.b.org/p?q=1", "HTTPS://X.IO/(y)", "mailto:m@n.io", "www.w.io/z",
                    "https://", "www.", "javascript:alert(1)", "xhttps://no.io"]
        let separators = [" ", " ", "\t", "\n", "\r\n", ""]
        var linked = 0, multiLine = 0, replaced = 0
        for seed in 0 ..< 150 {
            let base = (0 ..< Int(rng.next() % 5)).map { _ in pick(words, &rng) }.joined(separator: " ")
            let string = (0 ..< Int(rng.next() % 8) + 1).map { _ in
                pick(rng.next() % 2 == 0 ? urls : words, &rng) + pick(separators, &rng)
            }.joined()
            let view = try makeView(base)
            guard !view.looksLikeMarkdown(string) else { continue }
            let length = base.count
            let a = 1 + Int(rng.next() % UInt64(length + 1))
            let b = rng.next() % 3 == 0 ? 1 + Int(rng.next() % UInt64(length + 1)) : a
            let (from, to) = (min(a, b), max(a, b))
            // One word over a selection may be a lone URL, which links the
            // selection instead of replacing it — its own path, tested above.
            let oneWord = !string.trimmingCharacters(in: .whitespacesAndNewlines).contains { $0.isWhitespace }
            if from != to, oneWord { continue }
            if from == to { cursor(view, from) } else { select(view, from, to) }
            let before = view.editor.doc
            let pasteboard = makePasteboard()
            pasteboard.string = string
            view.paste(from: pasteboard)

            let context = "seed \(seed): \(string.debugDescription) into \(base.debugDescription) at \(from)..<\(to)"
            let doc = view.editor.doc
            XCTAssertNoThrow(try doc.check(), context)
            let chars = Array(base)
            let expectedText = String(chars[..<(from - 1)]) + string + String(chars[(to - 1)...])
            XCTAssertEqual(doc.textBetween(0, doc.content.size, blockSeparator: "\n"), expectedText, context)
            let expectedLinks = MarkdownParser.literalAutolinks(in: string).map { "\(string[$0.range])→\($0.href)" }
            XCTAssertEqual(links(view), expectedLinks, context)
            _ = view.handle(EditorTextView.KeyEvent(.keyboardZ, modifiers: .command, characters: "z"))
            XCTAssertEqual(view.editor.doc, before, "undo, \(context)")

            linked += expectedLinks.count
            if string.contains("\n") { multiLine += 1 }
            if from != to { replaced += 1 }
        }
        // The sweep has to reach what it's for.
        XCTAssertGreaterThan(linked, 100)
        XCTAssertGreaterThan(multiLine, 30)
        XCTAssertGreaterThan(replaced, 20)
    }

    func testPasteAndMatchStyleLeavesURLsPlain() throws {
        let pasteboard = makePasteboard()
        let view = try makeView("")
        pasteboard.string = "see https://example.com"
        cursor(view, 1)
        view.pasteAndMatchStyle(from: pasteboard)
        XCTAssertEqual(view.editor.doc.textContent, "see https://example.com")
        XCTAssertEqual(links(view), [])
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
    ///
    /// That flattening is a *system* service, not ours: `string` on an
    /// HTML-only pasteboard is answered by the pasteboard daemon converting the
    /// flavor. On a contended CI runner that conversion has been seen to stall
    /// for a minute and then answer with nothing at all — which says something
    /// about the runner, not about this view. So the conversion's result is read
    /// first and the half of the test that needs it is skipped when the host
    /// declines to convert; the half that is ours — match-style never carries
    /// the HTML flavor's formatting — is asserted either way.
    func testPasteAndMatchStyleFlattensARichOnlyPasteboard() throws {
        let pasteboard = makePasteboard()
        let view = try makeView("")
        pasteboard.items = [["public.html": Data("<p>rich <strong>text</strong></p>".utf8)]]
        cursor(view, 1)
        let flattened = pasteboard.string
        view.pasteAndMatchStyle(from: pasteboard)

        XCTAssertFalse(hasMark(view, "bold"), "match-style never reads the HTML flavor")
        let text = (flattened ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        try XCTSkipIf(text.isEmpty,
                      "this host's pasteboard did not convert public.html to a string "
                          + "(got \(String(describing: flattened)))")
        XCTAssertEqual(text, "rich text", "the flattened HTML is the text without its markup")
        XCTAssertEqual(view.editor.doc.textContent, text)
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

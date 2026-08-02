#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import SchemaKit
import EditorSyntax
@testable import EditorUIKit

/// What the read-only renderer draws in colour.
///
/// `DocumentView` shares the layout engine with the editable view, so it can
/// highlight — it just had no way to be told how. Highlight *marks* always
/// drew, since those are part of the document rather than a host decision; code
/// blocks were the gap.
@MainActor
final class DocumentViewHighlightTests: XCTestCase {
    private func codeDocument(_ language: String? = "swift") throws -> Node {
        let s = try Editor(extensions: fullKit()).schema
        let attrs: Attrs = language.map { ["language": .string($0)] } ?? [:]
        return try s.node("doc", [:], content: Fragment.from([
            try s.node("codeBlock", attrs, content: Fragment.from([
                s.text("let greeting = \"hello\"  // a comment"),
            ])),
        ]))
    }

    private func view(_ document: Node) -> DocumentView {
        let view = DocumentView(document: document)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 400)
        view.layoutIfNeeded()
        return view
    }

    /// The distinct foreground colours in the laid-out code block.
    private func colors(_ view: DocumentView) throws -> Set<String> {
        var found: Set<String> = []
        for block in try XCTUnwrap(view.ensureLayout()).blocks {
            unsafe block.attributed.enumerateAttribute(
                .foregroundColor, in: NSRange(location: 0, length: block.attributed.length)
            ) { value, _, _ in
                if let color = value as? UIColor { found.insert(color.description) }
            }
        }
        return found
    }

    func testWithoutAHookCodeIsOneColour() throws {
        let view = view(try codeDocument())
        XCTAssertEqual(try colors(view).count, 1, "plain monospaced text")
    }

    func testTheHookColoursTheCode() throws {
        let view = view(try codeDocument())
        view.syntaxHighlighter = makeSyntaxHighlighter()
        XCTAssertGreaterThan(try colors(view).count, 1, "keywords, strings and comments differ")
    }

    func testSettingTheHookLaterRetypesetsTheCachedBlock() throws {
        // A code block's colours are baked into its cached typeset block, so
        // this only works if setting the hook drops that cache.
        let view = view(try codeDocument())
        XCTAssertEqual(try colors(view).count, 1)
        view.syntaxHighlighter = makeSyntaxHighlighter()
        XCTAssertGreaterThan(try colors(view).count, 1, "the cached block was re-typeset")
    }

    func testTheLanguageBadgeIsDrawnWhenAskedFor() throws {
        func badges(_ view: DocumentView) throws -> [String] {
            var found: [String] = []
            for decoration in try XCTUnwrap(view.ensureLayout()).decorations {
                if case let .text(string, _, _) = decoration { found.append(string) }
            }
            return found
        }
        let plain = view(try codeDocument())
        XCTAssertFalse(try badges(plain).contains("Swift"))

        let badged = view(try codeDocument())
        badged.codeLanguageLabel = makeCodeLanguageLabel()
        XCTAssertTrue(try badges(badged).contains("Swift"), "the badge names the language")
    }

    func testHighlightMarksDrawWithoutAnyHook() throws {
        // These are part of the document rather than a host decision, so they
        // have always drawn — pinned so that stays true.
        let s = try Editor(extensions: fullKit()).schema
        let document = try s.node("doc", [:], content: Fragment.from([
            try s.node("paragraph", [:], content: Fragment.from([
                s.text("plain "),
                s.text("lit", [s.mark("highlight", ["color": .string("yellow")])]),
            ])),
        ]))
        let layout = try XCTUnwrap(view(document).ensureLayout())
        XCTAssertEqual(layout.highlights.count, 1, "the highlighted run is recorded for drawing")
    }
}
#endif

#if canImport(UIKit)
import XCTest
import DocumentModel
import SchemaKit
import EditorSerialization
@testable import EditorUIKit

/// Whether pasted plain text is reinterpreted as Markdown.
///
/// This is a guess made on the user's behalf, and it is not a cheap one in
/// either direction. Guess yes on ordinary prose and the paste is restructured
/// — headings, lists and emphasis appear where the author wrote none. Guess no
/// on real Markdown and it arrives as literal `#` and `*`, which at least looks
/// like what was copied.
///
/// So the bar is: a marker that plain text does not produce by accident.
@MainActor
final class MarkdownPasteHeuristicTests: XCTestCase {
    private func view() throws -> EditorTextView {
        let editor = try Editor(extensions: fullKit())
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        view.layoutIfNeeded()
        return view
    }

    // MARK: What should be read as Markdown

    func testBlockMarkersAreMarkdown() throws {
        let view = try view()
        let markdown = [
            "# Heading",
            "## Heading",
            "### Heading",          // every level, not only the first two
            "###### Heading",
            "- item",
            "* item",               // the other bullet
            "+ item",
            "1. item",              // ordered lists
            "> quoted",
            "```swift",
            "text\n- then a list",  // a marker anywhere, not only line one
            "  - indented item",    // leading space doesn't hide it
        ]
        for text in markdown {
            XCTAssertTrue(view.looksLikeMarkdown(text), "should be Markdown: \(text.debugDescription)")
        }
    }

    func testPairedEmphasisIsMarkdown() throws {
        let view = try view()
        for text in ["some **bold** words", "**leading**", "a **b** c **d**"] {
            XCTAssertTrue(view.looksLikeMarkdown(text), "should be Markdown: \(text)")
        }
    }

    // MARK: What should not be

    func testOrdinaryProseIsNotMarkdown() throws {
        let view = try view()
        let prose = [
            "Just a sentence.",
            "Two lines\nof plain text.",
            "A dash - in the middle of a line",
            "5 * 3 = 15",
            "He said — with an em dash — nothing.",
            "",
            "   ",
        ]
        for text in prose {
            XCTAssertFalse(view.looksLikeMarkdown(text), "should be plain: \(text.debugDescription)")
        }
    }

    func testCodeIsNotMarkdown() throws {
        let view = try view()
        // The expensive false positives. Copying code out of a terminal or a
        // plain-text editor gives no HTML flavour, so this heuristic is the
        // only thing standing between it and being restructured.
        let code = [
            "x = 2**8",                       // a power, not emphasis
            "int **argv;",                    // a pointer to a pointer
            "printf(\"%d\", a**b);",
        ]
        for text in code {
            XCTAssertFalse(view.looksLikeMarkdown(text), "should be plain: \(text)")
        }
    }

    // MARK: A trade-off worth stating

    func testAHashCommentStillReadsAsAHeading() throws {
        // Recorded, not endorsed. `# ` opens a heading in Markdown and opens a
        // comment in shell, Python, Ruby and YAML, and this heuristic cannot
        // tell them apart from one line. So a script copied out of a terminal —
        // no HTML flavour to go on — still arrives with its comments as
        // headings.
        //
        // Narrowing it further would need more than the text: the pasteboard
        // flavours, or the source application. Left as is so the behaviour is
        // at least written down.
        let view = try view()
        XCTAssertTrue(view.looksLikeMarkdown("# set the path\nexport PATH=/usr/bin"))
    }

    // MARK: The decision it drives

    func testMarkdownTextPastesAsStructure() throws {
        // The heuristic only matters through what it selects, so check the
        // parse it leads to actually produces the structure.
        let view = try view()
        let text = "# Title\n\n- one\n- two"
        XCTAssertTrue(view.looksLikeMarkdown(text))
        let doc = try MarkdownParser.parse(text, schema: view.editor.schema)
        XCTAssertEqual(doc.child(0).type.name, "heading")
        XCTAssertEqual(doc.child(1).type.name, "bulletList")
    }
}
#endif

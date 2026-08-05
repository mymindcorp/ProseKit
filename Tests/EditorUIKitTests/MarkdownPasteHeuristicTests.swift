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

    // MARK: Markers this parser understands

    func testMarkersOurOwnParserSupports() throws {
        // The heuristic exists to decide whether to hand text to
        // `MarkdownParser`, so anything that parser treats as structure is
        // worth recognising — otherwise it pastes as literal punctuation.
        let view = try view()
        let cases = [
            "~~~\ncode\n~~~",                       // the other fence
            "| a | b |\n| --- | --- |\n| 1 | 2 |",  // a pipe table
            "- [ ] todo",                            // a task list
            "- [x] done",
            "1) item",                               // the paren spelling
        ]
        for text in cases {
            XCTAssertTrue(view.looksLikeMarkdown(text), "should be Markdown: \(text.debugDescription)")
        }
    }

    func testLineEndingsFromOtherPlatforms() throws {
        // Text copied from a Windows app arrives with CRLF; the carriage
        // return must not hide the marker at the end of the line.
        let view = try view()
        XCTAssertTrue(view.looksLikeMarkdown("intro\r\n- item\r\n"))
        XCTAssertTrue(view.looksLikeMarkdown("# Heading\r\n"))
        XCTAssertFalse(view.looksLikeMarkdown("plain\r\nlines\r\n"))
    }

    func testOrderedItemsAgreeWithTheParser() throws {
        // The parser stops at nine digits, so a longer run is a sentence that
        // happens to start with a number, not a list.
        let view = try view()
        XCTAssertTrue(view.looksLikeMarkdown("123456789. item"))
        XCTAssertFalse(view.looksLikeMarkdown("1234567890. not a list"))
        // And a number alone isn't one either.
        XCTAssertFalse(view.looksLikeMarkdown("1.5 metres"))
        XCTAssertFalse(view.looksLikeMarkdown("2026 was the year"))
    }

    func testMarkersInsideALongerPaste() throws {
        // A real paste is mostly prose with a marker somewhere in it.
        let view = try view()
        let text = """
        Here are the notes from today. Nothing much happened, but a few
        things are worth writing down before I forget them entirely.

        ## Later that day

        The rest of the afternoon was uneventful.
        """
        XCTAssertTrue(view.looksLikeMarkdown(text))
    }

    func testProseThatMerelyMentionsPunctuation() throws {
        let view = try view()
        let prose = [
            "The ratio was 3:1 (see appendix).",
            "A hyphen-joined word and a 5*3 product.",
            "Rated 4/5 — recommended.",
            "The #1 choice for most people",     // a hash with no space
            "Send it to me@example.com > tomorrow",   // a > mid-line
            "temp_min and temp__max are both fields",  // underscores in code
        ]
        for text in prose {
            XCTAssertFalse(view.looksLikeMarkdown(text), "should be plain: \(text)")
        }
    }

    // MARK: The full table
    //
    // A classifier is judged by breadth, not by depth on a few inputs, so the
    // rest is a table: every marker in its near-miss form, the punctuation
    // prose really contains, and the formats people paste that only look like
    // markup.

    private func check(_ cases: [(String, Bool)], _ file: StaticString = #filePath,
                       _ line: UInt = #line) throws {
        let view = try view()
        for (text, expected) in cases {
            XCTAssertEqual(view.looksLikeMarkdown(text), expected,
                           "\(text.debugDescription) should be \(expected ? "Markdown" : "plain")",
                           file: file, line: line)
        }
    }

    func testHeadingNearMisses() throws {
        try check([
            ("#Heading", false),              // a marker needs its space
            ("#", false),
            ("#### four", true),
            ("####### seven", false),         // past the six levels that exist
            ("  ## indented", true),          // leading space doesn't hide it
            ("\t# tabbed", true),
            ("a # mid-line hash", false),
            ("#1 in the charts", false),
        ])
    }

    func testBulletNearMisses() throws {
        try check([
            ("-item", false),
            ("-", false),
            ("*", false),
            ("+", false),
            ("* item", true),
            ("+ item", true),
            ("  - nested", true),
            ("— em dash item", false),        // a dash that isn't a hyphen
            ("-- double hyphen", false),
        ])
    }

    func testOrderedNearMisses() throws {
        try check([
            ("1. item", true),
            ("1) item", true),
            ("0. item", true),
            ("01. item", true),
            ("1.item", false),                // still needs the space
            ("1 . item", false),
            ("1.5 metres", false),
            ("Chapter 1. The beginning", false),   // not at the start of the line
        ])
    }

    func testQuoteAndFenceNearMisses() throws {
        try check([
            ("> quoted", true),
            ("```", true),
            ("```swift", true),
            ("~~~", true),
            ("~~~~", true),
            ("~~strike~~", false),            // two tildes are strikethrough, not a fence
            ("a > b", false),
            ("x --> y", false),
        ])
    }

    func testEmphasisNearMisses() throws {
        try check([
            ("**bold**", true),
            ("a **b** c", true),
            ("**", false),
            ("****", false),                  // no content between
            ("2**8", false),
            ("**unclosed", false),
            ("char **argv, int **envp", false),  // two openers, not a pair: both follow a space
            ("a ** b ** c", false),             // an opener onto a space isn't one
            ("** **", false),
        ])
    }

    func testTableNearMisses() throws {
        try check([
            ("| a | b |\n| --- | --- |", true),
            ("|---|---|", true),
            ("| :-: | --: |", true),
            ("| a | b |", false),             // pipes alone are not a table
            ("a | b | c", false),
            ("---", false),                   // a rule, and no pipe to make it a table
            ("2 | 4 | 8 are powers", false),
        ])
    }

    func testFormatsThatAreNotMarkdown() throws {
        // Things people paste that contain punctuation but no markup.
        try check([
            ("{\"a\": 1, \"b\": [2, 3]}", false),
            ("name,age,city\nada,36,london", false),
            ("2026-08-04 12:00:01 INFO started", false),
            ("https://example.com/a-b?c=d#e", false),
            ("SELECT * FROM t WHERE a > 1;", false),
            ("if (a > b) { return -1; }", false),
            ("--- a/file.swift", false),      // a diff header, not a bullet
            ("+++ b/file.swift", false),
        ])
    }

    func testWhitespaceOnlyAndEmpty() throws {
        try check([
            ("", false),
            ("\n", false),
            ("   \n  \n", false),
            ("\n\n# heading after blank lines", true),
        ])
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

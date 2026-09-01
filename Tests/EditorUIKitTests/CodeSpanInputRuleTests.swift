#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import DocumentTransform
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

/// Markdown shortcuts must not fire inside an inline code span, and the
/// character that would have triggered them must still be typed.
///
/// The SchemaKit suite covers the plugin's decision not to fire. This covers
/// what the user actually sees: `insertText` falls back to inserting the
/// character itself when no rule claims it, so a suppressed rule has to leave
/// the literal text behind rather than swallowing the keystroke.
@MainActor
final class CodeSpanInputRuleTests: XCTestCase {

    /// A paragraph holding `seed`, optionally all inline code, with the caret
    /// at the end of the text.
    private func makeView(_ seed: String, codeMarked: Bool) throws -> EditorTextView {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        editor.setContent(try s.node("doc", [:], content: Fragment.from([
            try s.node("paragraph", [:], content: Fragment.from([s.text(seed)])),
        ])))
        if codeMarked, let code = s.marks["code"] {
            let tr = editor.state.tr
            try tr.addMark(1, 1 + seed.count, code.create([:]))
            editor.dispatch(tr)
        }
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        view.layoutIfNeeded()
        let end = editor.doc.content.size - 1
        editor.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.doc, end)))
        return view
    }

    func testMarkersSurviveInsideACodeSpan() throws {
        let cases = [("**b*", "*", "**b**"), ("__b_", "_", "__b__"),
                     ("*i", "*", "*i*"), ("~~s~", "~", "~~s~~"),
                     ("==h=", "=", "==h=="), ("`c", "`", "`c`")]
        for (seed, trigger, want) in cases {
            let view = try makeView(seed, codeMarked: true)
            view.insertText(trigger)
            XCTAssertEqual(view.editor.doc.textContent, want,
                           "typing \(trigger) after \(seed) inside a code span")
        }
    }

    func testInlineNodesAreNotCreatedInsideACodeSpan() throws {
        for (seed, trigger, want, nodeName) in [("$x", "$", "$x$", "inlineMath"),
                                                ("[[Page]", "]", "[[Page]]", "wikiLink")] {
            let view = try makeView(seed, codeMarked: true)
            view.insertText(trigger)
            XCTAssertEqual(view.editor.doc.textContent, want)
            var found = 0
            view.editor.doc.descendants { n, _, _, _ in
                if n.type.name == nodeName { found += 1 }
                return true
            }
            XCTAssertEqual(found, 0, "\(nodeName) was created inside a code span")
        }
    }

    func testCodeMarkSurvivesASuppressedRule() throws {
        let view = try makeView("**b*", codeMarked: true)
        view.insertText("*")
        let code = try XCTUnwrap(view.editor.schema.marks["code"])
        let doc = view.editor.doc
        XCTAssertTrue(doc.rangeHasMark(0, doc.content.size, code),
                      "the span is still code after the rule was suppressed")
    }

    /// The control: suppression keys off the code mark, not off proximity to
    /// one. The identical keystroke in plain text must still transform.
    func testTheSameKeystrokeStillTransformsInPlainText() throws {
        let view = try makeView("**b*", codeMarked: false)
        view.insertText("*")
        let bold = try XCTUnwrap(view.editor.schema.marks["bold"])
        let doc = view.editor.doc
        XCTAssertEqual(doc.textContent, "b", "the markers are stripped in plain text")
        XCTAssertTrue(doc.rangeHasMark(0, doc.content.size, bold), "and the text is bold")
    }
}
#endif

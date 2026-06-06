#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

@MainActor
final class SpellCheckTests: XCTestCase {
    private func decoration(_ from: Int, _ to: Int) -> Decoration {
        Decoration(from: from, to: to, attributes: ["spelling": "true"])
    }
    private func view(_ text: String) throws -> EditorTextView {
        let editor = try Editor(extensions: fullKit())
        let para = try! editor.schema.node("paragraph", [:], content: Fragment.from([editor.schema.text(text)]))
        editor.setContent(try! editor.schema.node("doc", [:], content: Fragment.from([para])))
        return EditorTextView(editor: editor)
    }

    func testWordUnderCaretIsNotUnderlined() throws {
        let v = try view("mispeled")           // misspelled word at [1, 9]
        let decos = [decoration(1, 9)]
        // Caret inside the word (still typing it) → not underlined.
        v.editor.dispatch(v.editor.state.tr.setSelection(TextSelection.create(v.editor.doc, 9)))
        XCTAssertTrue(v.visibleSpellingRanges(decos).isEmpty, "the word being typed should not be flagged")
        // Caret moved past the word (e.g. after a space) → underlined.
        v.editor.dispatch(v.editor.state.tr.setSelection(TextSelection.create(v.editor.doc, 1)))
        // place caret well before by selecting elsewhere: use a range selection
        v.editor.dispatch(v.editor.state.tr.setSelection(TextSelection.create(v.editor.doc, 0)))
        XCTAssertEqual(v.visibleSpellingRanges(decos).count, 1, "a word the caret has left should be flagged")
    }

    func testOtherMisspellingsStillUnderlinedWhileTypingAnother() throws {
        let v = try view("teh mispeled")        // two misspellings
        let decos = [decoration(1, 4), decoration(5, 13)]
        v.editor.dispatch(v.editor.state.tr.setSelection(TextSelection.create(v.editor.doc, 13))) // in the 2nd word
        let visible = v.visibleSpellingRanges(decos)
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible.first?.0, 1, "the other misspelled word stays flagged")
    }

    func testRangeSelectionShowsAllUnderlines() throws {
        let v = try view("mispeled")
        let decos = [decoration(1, 9)]
        v.editor.dispatch(v.editor.state.tr.setSelection(TextSelection.create(v.editor.doc, 1, 9)))
        XCTAssertEqual(v.visibleSpellingRanges(decos).count, 1, "a non-collapsed selection isn't 'the word being typed'")
    }
}
#endif

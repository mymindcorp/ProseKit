#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import EditorStateKit
import SchemaKit
import DocumentTransform
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

    func testCachedUnderlinesPersistAndShiftAcrossEdits() throws {
        // Typing in one block must not blank underlines in another: they are
        // mapped through the transaction, never hidden while a check runs.
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        editor.setContent(try s.node("doc", [:], content: Fragment.from([
            try s.node("paragraph", [:], content: Fragment.from([s.text("first one")])),      // content 1..10
            try s.node("paragraph", [:], content: Fragment.from([s.text("mispeled here")])),  // content 12..25
        ])))
        let v = EditorTextView(editor: editor)
        v.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        v.spellCache = [decoration(12, 20)] // "mispeled" in block 2

        let tr = editor.state.tr
        try tr.insertText("ab ", 1) // edit block 1
        editor.dispatch(tr)

        let cached = v.currentSpellDecorations().filter { $0.attributes["spelling"] != nil && $0.from >= 14 }
        XCTAssertEqual(cached.count, 1, "block-2 underline survives the edit (no flash)")
        XCTAssertEqual(cached.first?.from, 15)
        XCTAssertEqual(cached.first?.to, 23)
    }

    func testCachedUnderlineDropsWhenItsWordIsDeleted() throws {
        let v = try view("mispeled word")
        v.spellCache = [decoration(1, 9)]
        let tr = v.editor.state.tr
        try tr.delete(1, 9)
        v.editor.dispatch(tr)
        XCTAssertTrue(v.spellCache.filter { $0.from < 9 }.isEmpty,
                      "a deleted word's underline is dropped, not collapsed")
    }

    func testOnlyTheEditedBlockIsRevalidated() throws {
        // Two paragraphs; the cache holds a real underline in block 1 and a
        // sentinel (whole-block range, which the word checker never produces)
        // in block 2.
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        editor.setContent(try s.node("doc", [:], content: Fragment.from([
            try s.node("paragraph", [:], content: Fragment.from([s.text("mispeled one")])),     // content 1..13
            try s.node("paragraph", [:], content: Fragment.from([s.text("second paregraph")])), // content 15..31
        ])))
        let v = EditorTextView(editor: editor)
        v.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        v.spellCache = [decoration(1, 9), decoration(15, 31)]

        let tr = editor.state.tr
        try tr.insertText("x", 16) // edit inside block 2
        editor.dispatch(tr)

        let cache = v.spellCache
        // Block 1 untouched: the edit was after it, so its underline is identical.
        XCTAssertTrue(cache.contains { $0.from == 1 && $0.to == 9 }, "block-1 underline must survive unchanged")
        // The block-2 sentinel (would map to 15...32) was replaced, not mapped.
        XCTAssertFalse(cache.contains { $0.from == 15 && $0.to == 32 }, "block-2 cache must be re-checked, not mapped")
        // Whatever the checker found in block 2 stays inside block 2.
        XCTAssertTrue(cache.filter { $0.from >= 14 }.allSatisfy { $0.from >= 15 && $0.to <= 33 })
        // "paregraph" is misspelled, so the immediate re-check flags it.
        XCTAssertTrue(cache.contains { $0.from >= 23 }, "misspelling in the edited block is flagged immediately")
    }
}
#endif

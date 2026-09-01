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

    func testOnlyTheEditedWordIsRevalidated() throws {
        // Two paragraphs. The cache holds a real underline in block 1, a real
        // one on "paregraph" in block 2, and a sentinel inside "second" (a
        // sub-word range the checker never produces).
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        editor.setContent(try s.node("doc", [:], content: Fragment.from([
            try s.node("paragraph", [:], content: Fragment.from([s.text("mispeled one")])),     // content 1..13
            try s.node("paragraph", [:], content: Fragment.from([s.text("second paregraph")])), // content 15..31
        ])))
        let v = EditorTextView(editor: editor)
        v.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        v.spellCache = [decoration(1, 9), decoration(17, 19), decoration(22, 31)]

        let tr = editor.state.tr
        try tr.insertText("x", 16) // "sxecond paregraph"
        editor.dispatch(tr)

        let cache = v.spellCache
        // Block 1 untouched: the edit was after it, so its underline is identical.
        XCTAssertTrue(cache.contains { $0.from == 1 && $0.to == 9 }, "block-1 underline must survive unchanged")
        // "paregraph" was not re-checked, only shifted: its cached underline
        // moved with the text rather than being regenerated.
        XCTAssertTrue(cache.contains { $0.from == 23 && $0.to == 32 }, "the untouched word's underline is mapped, not dropped")
        // The sentinel sat inside the edited word, so it was replaced, not mapped.
        XCTAssertFalse(cache.contains { $0.to == 19 }, "the edited word's cache must be re-checked, not mapped")
        // ...by what the checker says about the word now under the caret.
        XCTAssertTrue(cache.contains { $0.from == 15 && $0.to == 22 }, "the misspelling just typed is flagged immediately")
    }

    // MARK: - Re-checking around an edit

    private func paragraphs(_ texts: [String], code: Bool = false) throws -> Node {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        let blocks = try texts.map { text in
            try s.node(code ? "codeBlock" : "paragraph", [:], content: Fragment.from([s.text(text)]))
        }
        return try s.node("doc", [:], content: Fragment.from(blocks))
    }

    func testRecheckWidensToTheWordAroundTheEdit() throws {
        let doc = try paragraphs(["aaa mispeled ccc"]) // "mispeled" at 5..13
        let result = SpellCheck.recheck(doc, around: 7...8)
        XCTAssertEqual(result.checked, [5...13], "the word containing the edit, and only that word")
        XCTAssertEqual(result.decorations.map { ($0.from, $0.to) }.map { "\($0)-\($1)" }, ["5-13"])
    }

    func testRecheckCoversBothSidesOfASplitWord() throws {
        // A space typed into "hello" leaves two new words: both are checked.
        let doc = try paragraphs(["hel lo"])
        XCTAssertEqual(SpellCheck.recheck(doc, around: 4...5).checked, [1...7])
    }

    func testRecheckAtAWordStartLeavesThePreviousWordAlone() throws {
        let doc = try paragraphs(["foo baz"]) // "baz" at 5..8
        XCTAssertEqual(SpellCheck.recheck(doc, around: 5...5).checked, [5...8])
    }

    func testRecheckOfWhitespaceOnlyChecksNothing() throws {
        let doc = try paragraphs(["foo  bar"]) // two spaces: positions 4 and 5
        let result = SpellCheck.recheck(doc, around: 5...5)
        XCTAssertTrue(result.checked.isEmpty)
        XCTAssertTrue(result.decorations.isEmpty)
    }

    func testRecheckSkipsCode() throws {
        let doc = try paragraphs(["mispeled"], code: true)
        XCTAssertTrue(SpellCheck.recheck(doc, around: 3...4).checked.isEmpty)
    }

    func testRecheckAcrossAParagraphSplitChecksTheWordsOnBothSides() throws {
        // "hello" | "wrold": the edit that split them spans the boundary.
        let doc = try paragraphs(["hello", "wrold"]) // block 2 content at 8..13
        let result = SpellCheck.recheck(doc, around: 6...8)
        XCTAssertEqual(result.checked, [1...6, 8...13])
        XCTAssertEqual(result.decorations.map { ($0.from, $0.to) }.map { "\($0)-\($1)" }, ["8-13"])
    }

    func testRecheckMapsUTF16OffsetsToPositions() throws {
        // An emoji is one position but two UTF-16 units; a misspelling after
        // it must land on document positions, not string offsets.
        let doc = try paragraphs(["😀 mispeled"]) // "mispeled" at 3..11
        let result = SpellCheck.recheck(doc, around: 5...6)
        XCTAssertEqual(result.checked, [3...11])
        XCTAssertEqual(result.decorations.map { ($0.from, $0.to) }.map { "\($0)-\($1)" }, ["3-11"])
    }
}
#endif

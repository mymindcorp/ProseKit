#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import EditorStateKit
import DocumentTransform
import SchemaKit
@testable import EditorUIKit

/// Drawing footnotes: the reference as a raised number in the text, the note as
/// a numbered block. The number is the reference's place in the document, so
/// the layout has to work it out for the whole document rather than per block.
@MainActor
final class FootnoteRenderTests: XCTestCase {
    private func footnoteEditor() throws -> Editor {
        try Editor(extensions: starterKit() + footnoteExtensions())
    }

    /// `text[^label]` followed by the note, built by hand so the labels are ours.
    private func document(_ editor: Editor, labels: [String]) throws -> Node {
        let s = editor.schema
        var inline: [Node] = [s.text("text")]
        for label in labels {
            inline.append(try s.node("footnoteReference", ["label": .string(label)]))
        }
        var blocks: [Node] = [try s.node("paragraph", [:], content: Fragment.from(inline))]
        for label in labels {
            blocks.append(try s.node("footnoteDefinition", ["label": .string(label)],
                                     content: Fragment.from([
                                         try s.node("paragraph", [:],
                                                    content: Fragment.from([s.text("note \(label)")])),
                                     ])))
        }
        return try s.node("doc", [:], content: Fragment.from(blocks))
    }

    private func layout(_ doc: Node) -> DocumentLayout {
        DocumentLayout(doc: doc, width: 320, theme: DocumentTheme())
    }

    func testAReferenceDrawsItsNumberNotItsLabel() throws {
        let editor = try footnoteEditor()
        let doc = try document(editor, labels: ["zebra", "alpha"])
        // The paragraph only — the notes below it spell their labels in their
        // own text, which is the author's writing, not a drawn marker.
        let paragraph = try XCTUnwrap(layout(doc).blocks.first).attributed.string
        // Read in order, so "zebra" is 1 and "alpha" is 2 — the labels don't show.
        XCTAssertEqual(paragraph, "text12", "expected the numbers in the text")
        XCTAssertFalse(paragraph.contains("zebra"), "the label shouldn't be drawn")
    }

    func testAReferenceIsRaisedAndSmaller() throws {
        let editor = try footnoteEditor()
        let doc = try document(editor, labels: ["1"])
        let block = try XCTUnwrap(layout(doc).blocks.first)
        let attributed = block.attributed
        // The last character of the paragraph is the reference.
        let index = attributed.length - 1
        let attrs = unsafe attributed.attributes(at: index, effectiveRange: nil)
        let offset = try XCTUnwrap(attrs[.baselineOffset] as? CGFloat)
        XCTAssertGreaterThan(offset, 0, "a footnote marker sits above the baseline")
        let font = try XCTUnwrap(attrs[.font] as? UIFont)
        XCTAssertLessThan(font.pointSize, DocumentTheme().bodyFont.pointSize, "and is set smaller")
    }

    func testTheNoteIsDrawnWithItsNumberInTheGutter() throws {
        let editor = try footnoteEditor()
        let doc = try document(editor, labels: ["only"])
        let l = layout(doc)
        // Its text is laid out…
        XCTAssertTrue(l.blocks.contains { $0.attributed.string.contains("note only") },
                      "the note's text should be laid out")
        // …behind a marker drawn in the gutter, reading "1." not "only.".
        let markers: [String] = l.decorations.compactMap {
            if case let .text(s, _, _) = $0 { return s }
            return nil
        }
        XCTAssertTrue(markers.contains("1."), "expected a numbered marker, got \(markers)")
    }

    func testInsertingAFootnoteEarlierRenumbersTheOnesAfterIt() throws {
        // The number comes from the document, not the node, so a cached block
        // for an unchanged reference would otherwise keep a stale number.
        let editor = try footnoteEditor()
        editor.setContent(try document(editor, labels: ["b"]))
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        view.layoutIfNeeded()
        XCTAssertTrue(view.ensureLayout().blocks.map(\.attributed.string).joined().contains("text1"))

        // Add a reference *before* the existing one; it becomes 1, "b" becomes 2.
        let s = editor.schema
        let tr = editor.state.tr
        _ = try? tr.insert(5, try s.node("footnoteReference", ["label": .string("a")]))
        editor.dispatch(tr)
        view.layoutIfNeeded()
        let text = view.ensureLayout().blocks.map(\.attributed.string).joined()
        XCTAssertTrue(text.contains("text12"), "expected renumbering to 1,2 — got \(text)")
    }

    func testADocumentWithoutFootnotesIsUnaffected() throws {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        let doc = try s.node("doc", [:], content: Fragment.from([
            try s.node("paragraph", [:], content: Fragment.from([s.text("plain")])),
        ]))
        let l = layout(doc)
        XCTAssertEqual(l.blocks.map(\.attributed.string).joined(), "plain")
    }
}
#endif

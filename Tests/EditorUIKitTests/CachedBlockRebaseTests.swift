#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import EditorStateKit
import SchemaKit
import DocumentTransform
@testable import EditorUIKit

/// A cached typeset block is reused wherever its node next sits, so everything
/// it carries must be relative to the block — never a document position baked in
/// at the time it was first laid out.
///
/// Deleting a list item is what makes that bite. The items below it keep their
/// exact paragraph nodes and so hit the block cache, but every one of them has
/// moved to a lower document position. A block whose `segments` still described
/// the old position matched nothing in `attrIndex(forDocPos:)`, which falls back
/// to the end of the string — so the caret drew at the end of the item's text
/// instead of where it actually was, and hit-testing answered the same way.
@MainActor
final class CachedBlockRebaseTests: XCTestCase {
    private func listDoc(_ s: Schema, items: [String], lead: Bool = true, trail: Bool = true) -> Node {
        func p(_ t: String) -> Node {
            try! s.node("paragraph", [:], content: Fragment.from(t.isEmpty ? [] : [s.text(t)]))
        }
        var top: [Node] = [try! s.node("bulletList", [:], content: Fragment.from(items.map { t in
            try! s.node("listItem", [:], content: Fragment.from([p(t)]))
        }))]
        if lead { top.insert(p("intro"), at: 0) }
        if trail { top.append(p("outro")) }
        return try! s.node("doc", [:], content: Fragment.from(top))
    }

    private func makeView(_ doc: Node, _ editor: Editor) -> EditorTextView {
        editor.setContent(doc)
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        view.layoutIfNeeded()
        _ = view.ensureLayout()
        return view
    }

    /// The caret after deleting a list item must draw where a freshly laid-out
    /// document puts it — not at the end of the reused block's text.
    func testCaretDrawsInPlaceAfterDeletingAListItem() throws {
        let editor = try Editor(extensions: fullKit())
        let doc = listDoc(editor.schema, items: ["item0", "item1", "item2", "item3"])
        let view = makeView(doc, editor)

        // Drag-select the whole of the first item, then delete it.
        view.selectedTextRange = DocTextRange(10, 19)
        view.deleteBackward()
        _ = view.ensureLayout()

        let head = editor.state.selection.head
        let reused = view.ensureLayout()
        let fresh = DocumentLayout(doc: editor.doc, width: 320, theme: DocumentTheme())
        XCTAssertEqual(reused.caretRect(at: head)?.minX ?? -1,
                       fresh.caretRect(at: head)?.minX ?? -2, accuracy: 0.5,
                       "caret x after deleting a list item")

        // The reused blocks must describe their new positions, not their old ones.
        for (i, block) in reused.blocks.enumerated() {
            guard let first = block.segments.first else { continue }
            XCTAssertEqual(first.docStart, block.contentStart,
                           "block \(i) segment starts at \(first.docStart) but the block starts at \(block.contentStart)")
        }
    }

    /// Every caret and hit-test answer must survive block reuse, for each
    /// selection a drag could produce over each list shape.
    func testCaretAndHitTestSurviveEveryListDeletion() throws {
        let probe = try Editor(extensions: fullKit())
        let shapes: [(String, [String])] = [
            ("flat", ["item0", "item1", "item2", "item3"]),
            ("uneven", ["a", "longer item here", "b", "another long one"]),
        ]
        for (name, items) in shapes {
            let template = listDoc(probe.schema, items: items)
            var textPositions: [Int] = []
            for q in 0...template.content.size where template.resolve(q).parent.inlineContent {
                textPositions.append(q)
            }
            for from in textPositions {
                for to in textPositions where to > from {
                    let editor = try Editor(extensions: fullKit())
                    let view = makeView(listDoc(editor.schema, items: items), editor)
                    view.selectedTextRange = DocTextRange(from, to)
                    view.deleteBackward()
                    _ = view.ensureLayout()

                    let head = editor.state.selection.head
                    let reused = view.ensureLayout()
                    let fresh = DocumentLayout(doc: editor.doc, width: 320, theme: DocumentTheme())
                    let a = reused.caretRect(at: head), b = fresh.caretRect(at: head)
                    XCTAssertEqual(a?.minX ?? -1, b?.minX ?? -2, accuracy: 0.5,
                                   "\(name) caret x after deleting [\(from),\(to)]")
                    XCTAssertEqual(a?.minY ?? -1, b?.minY ?? -2, accuracy: 0.5,
                                   "\(name) caret y after deleting [\(from),\(to)]")
                }
            }
        }
    }

    /// A highlight's background is recorded while the block is typeset, so a
    /// block served from the cache has to carry it along — otherwise the
    /// highlight disappears from every item below a deleted one.
    func testHighlightSurvivesBlockReuse() throws {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        func p(_ t: String, highlighted: Bool) -> Node {
            let text = highlighted ? s.text(t, [s.mark("highlight")]) : s.text(t)
            return try! s.node("paragraph", [:], content: Fragment.from([text]))
        }
        let doc = try! s.node("doc", [:], content: Fragment.from([
            p("intro", highlighted: false),
            try! s.node("bulletList", [:], content: Fragment.from([
                try! s.node("listItem", [:], content: Fragment.from([p("item0", highlighted: false)])),
                try! s.node("listItem", [:], content: Fragment.from([p("item1", highlighted: true)])),
                try! s.node("listItem", [:], content: Fragment.from([p("item2", highlighted: true)])),
            ])),
        ]))
        let view = makeView(doc, editor)
        XCTAssertEqual(view.ensureLayout().highlights.count, 2, "both highlights before the edit")

        view.selectedTextRange = DocTextRange(10, 19) // delete item0
        view.deleteBackward()
        _ = view.ensureLayout()

        let reused = view.ensureLayout()
        let fresh = DocumentLayout(doc: editor.doc, width: 320, theme: DocumentTheme())
        XCTAssertEqual(reused.highlights.count, fresh.highlights.count,
                       "highlights kept when the blocks below a deleted item are reused")
        XCTAssertEqual(reused.highlights.map(\.from), fresh.highlights.map(\.from),
                       "highlight ranges rebased with their blocks")
    }
}
#endif

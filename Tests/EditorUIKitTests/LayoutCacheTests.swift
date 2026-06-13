#if canImport(UIKit)
import XCTest
import UIKit
import CoreText
import DocumentModel
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

/// Incremental layout: an edit to one block must not re-typeset the others.
@MainActor
final class LayoutCacheTests: XCTestCase {
    // One shared schema, as in a real editing session (Node equality keys on
    // node type identity, so both docs must come from the same schema).
    private let schema = try! Editor(extensions: fullKit()).schema
    private func makeDoc(_ first: String) -> Node {
        func para(_ s: String) -> Node { try! schema.node("paragraph", [:], content: Fragment.from([schema.text(s)])) }
        return try! schema.node("doc", [:], content: Fragment.from([para(first), para("bravo paragraph"), para("charlie paragraph")]))
    }
    private func line(_ l: DocumentLayout, containing text: String) -> CTLine? {
        l.blocks.first { $0.attributed.string.contains(text) }?.lines.first?.ctLine
    }

    func testUnchangedBlocksAreReusedAfterAnEdit() throws {
        let cache = TextBlockLayoutCache()
        let doc1 = makeDoc("alpha")
        let l1 = DocumentLayout(doc: doc1, width: 300, theme: TextTheme(), blockCache: cache)
        // Edit paragraph 1 the way a transaction does: unchanged siblings keep
        // their storage (the cache keys on content-buffer identity, which is
        // exactly what survives a real edit).
        var paras = (0 ..< doc1.childCount).map { doc1.child($0) }
        paras[0] = try schema.node("paragraph", [:], content: Fragment.from([schema.text("alpha edited longer text")]))
        let doc2 = try schema.node("doc", [:], content: Fragment.from(paras))
        let l2 = DocumentLayout(doc: doc2, width: 300, theme: TextTheme(), blockCache: cache)
        // The CoreText lines for unchanged paragraphs are the same objects.
        XCTAssertNotNil(line(l1, containing: "bravo"))
        XCTAssertTrue(line(l1, containing: "bravo") === line(l2, containing: "bravo"), "an unchanged block must be reused, not re-typeset")
        XCTAssertTrue(line(l1, containing: "charlie") === line(l2, containing: "charlie"))
        // The edited paragraph is re-typeset (different line object).
        XCTAssertFalse(line(l1, containing: "alpha") === line(l2, containing: "edited"), "the edited block must be re-typeset")
    }

    func testCacheSurvivesPassesAndStaysBounded() throws {
        let cache = TextBlockLayoutCache()
        // Lay out 10 distinct documents in sequence: entries accumulate (no
        // per-pass sweep — that's what keeps keystrokes cheap) but stay far
        // below the eviction cap.
        for i in 0..<10 {
            _ = DocumentLayout(doc: makeDoc("alpha \(i)"), width: 300, theme: TextTheme(), blockCache: cache)
        }
        XCTAssertLessThan(cache.debugEntryCount, 100)
        // Re-laying-out the same doc (same storage) hits the cache:
        let last = makeDoc("alpha 9")
        let before = line(DocumentLayout(doc: last, width: 300, theme: TextTheme(), blockCache: cache), containing: "bravo")
        let after = line(DocumentLayout(doc: last, width: 300, theme: TextTheme(), blockCache: cache), containing: "bravo")
        XCTAssertTrue(before === after, "live blocks stay cached across passes")
    }
}
#endif

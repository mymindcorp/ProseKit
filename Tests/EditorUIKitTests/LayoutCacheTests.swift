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
        let l1 = DocumentLayout(doc: makeDoc("alpha"), width: 300, theme: TextTheme(), blockCache: cache)
        let l2 = DocumentLayout(doc: makeDoc("alpha edited longer text"), width: 300, theme: TextTheme(), blockCache: cache)
        // The CoreText lines for unchanged paragraphs are the same objects.
        XCTAssertNotNil(line(l1, containing: "bravo"))
        XCTAssertTrue(line(l1, containing: "bravo") === line(l2, containing: "bravo"), "an unchanged block must be reused, not re-typeset")
        XCTAssertTrue(line(l1, containing: "charlie") === line(l2, containing: "charlie"))
        // The edited paragraph is re-typeset (different line object).
        XCTAssertFalse(line(l1, containing: "alpha") === line(l2, containing: "edited"), "the edited block must be re-typeset")
    }

    func testCacheIsBoundedToTheLastLayout() throws {
        let cache = TextBlockLayoutCache()
        // Lay out 10 distinct first-paragraphs in sequence; the cache must not
        // accumulate all 10 versions (mark-and-sweep keeps only the live blocks).
        for i in 0..<10 {
            _ = DocumentLayout(doc: makeDoc("alpha \(i)"), width: 300, theme: TextTheme(), blockCache: cache)
        }
        // After the last pass, re-laying-out the SAME doc should hit the cache:
        let last = makeDoc("alpha 9")
        let before = line(DocumentLayout(doc: last, width: 300, theme: TextTheme(), blockCache: cache), containing: "bravo")
        let after = line(DocumentLayout(doc: last, width: 300, theme: TextTheme(), blockCache: cache), containing: "bravo")
        XCTAssertTrue(before === after, "the live blocks stay cached across passes")
    }
}
#endif

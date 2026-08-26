#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import SchemaKit
@testable import EditorUIKit

/// An inline atom that typesets to nothing at all.
///
/// A wiki-link whose `text` attribute was never supplied has an empty label, so
/// it used to append zero characters to the block's attributed string while
/// still taking a document position. That collapses the position before it and
/// the position after it onto one attributed index, and every geometry query
/// answers about that index: `lineBoundary(from: pos, toEnd: false)` mapped
/// position 1 to the shared index and mapped back to position 2, handing back a
/// "line start" that sits *after* the caret it was asked about.
@MainActor
final class EmptyAtomMappingTests: XCTestCase {
    private func layout(_ children: [Node], _ s: Schema) -> DocumentLayout {
        let doc = try! s.node("doc", [:], content: Fragment.from([
            try! s.node("paragraph", [:], content: Fragment.from(children)),
        ]))
        return DocumentLayout(doc: doc, width: 320, theme: DocumentTheme(),
                              blockCache: TextBlockLayoutCache())
    }

    /// Every atom owns at least one attributed index, so the doc↔attr mapping
    /// stays one-to-one at its edges.
    func testAnAtomWithNoLabelStillOwnsAnIndex() throws {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        let l = layout([try s.node("wikiLink"), s.text(" tail")], s)
        let block = l.blocks[0]
        for seg in block.segments where seg.text == nil {
            XCTAssertGreaterThanOrEqual(seg.attrLen, 1,
                                        "an atom at doc \(seg.docStart) typeset to no characters")
        }
        XCTAssertNotEqual(block.attrIndex(forDocPos: block.contentStart),
                          block.attrIndex(forDocPos: block.contentStart + 1),
                          "the positions either side of the atom share an index")
    }

    /// The property the geometry fuzzer sweeps, pinned on the shape that broke
    /// it: the line edges must bracket the position they were asked about.
    func testLineEdgesBracketAPositionNextToAnEmptyAtom() throws {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        for children in [[try s.node("wikiLink")],
                         [try s.node("wikiLink"), s.text(" ")],
                         [s.text("a "), try s.node("wikiLink"), s.text(" b")],
                         [try s.node("mention", ["id": .string("x")]), try s.node("wikiLink")]] {
            let l = layout(children, s)
            let block = l.blocks[0]
            for pos in block.contentStart ... block.contentEnd {
                guard let start = l.lineBoundary(from: pos, toEnd: false),
                      let end = l.lineBoundary(from: pos, toEnd: true) else { continue }
                XCTAssertLessThanOrEqual(start, pos, "the line start is after \(pos)")
                XCTAssertLessThanOrEqual(pos, end, "the line end is before \(pos)")
            }
        }
    }
}
#endif

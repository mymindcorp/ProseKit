#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import SchemaKit
@testable import EditorUIKit

/// Mapping a document position to a UTF-16 index inside a laid-out block.
///
/// This sits on the scroll path: UIKit asks for character rects as you drag a
/// selection, which lands here through `selectionRects`. It used to build a
/// prefix string and bridge it to `NSString` for every call — thousands of
/// graphemes and an allocation each time, in a ~500-word paragraph.
///
/// The fast path takes the identity mapping when a run's grapheme count and
/// UTF-16 count agree. These tests pin it against text where they don't:
/// emoji, combining marks, and surrogate pairs, mixed with plain runs.
@MainActor
final class AttrIndexMappingTests: XCTestCase {
    private func block(_ text: String) -> TextBlock {
        let editor = try! Editor(extensions: fullKit())
        let s = editor.schema
        let doc = try! s.node("doc", [:], content: Fragment.from([
            try! s.node("paragraph", [:], content: Fragment.from([s.text(text)])),
        ]))
        let l = DocumentLayout(doc: doc, width: 390, theme: DocumentTheme(),
                               blockCache: TextBlockLayoutCache())
        return l.blocks[0]
    }

    /// What the mapping meant before the fast path, kept as the oracle.
    private func referenceAttrIndex(_ b: TextBlock, _ pos: Int) -> Int {
        for seg in b.segments where pos >= seg.docStart && pos <= seg.docStart + seg.docLen {
            if let text = seg.text {
                let prefix = String(text.prefix(pos - seg.docStart))
                return seg.attrStart + (prefix as NSString).length
            }
            return pos <= seg.docStart ? seg.attrStart : seg.attrStart + seg.attrLen
        }
        return b.segments.last.map { $0.attrStart + $0.attrLen } ?? 0
    }

    private func check(_ text: String, _ label: String) {
        let b = block(text)
        for pos in b.contentStart ... b.contentEnd {
            XCTAssertEqual(b.attrIndex(forDocPos: pos), referenceAttrIndex(b, pos),
                           "\(label): attrIndex disagreed at doc position \(pos)")
        }
    }

    func testPlainASCIITakesTheFastPathAndAgrees() {
        check("The quick brown fox jumps over the lazy dog.", "ascii")
    }

    func testTextWhoseCountsDisagree() {
        // Each of these has more UTF-16 units than graphemes, so the fast path
        // must decline: emoji outside the BMP, a ZWJ sequence that is one
        // grapheme over many units, a combining mark, and a flag.
        check("hello 😀 world", "emoji")
        check("family 👨‍👩‍👧‍👦 here", "zwj sequence")
        check("cafe\u{0301} au lait", "combining acute")
        check("flag 🇯🇵 end", "regional indicators")
        check("mixed 😀 e\u{0301} 🇯🇵 tail", "mixed")
    }

    func testRoundTripThroughBothDirections() {
        for text in ["plain ascii text", "with 😀 emoji", "cafe\u{0301}"] {
            let b = block(text)
            for pos in b.contentStart ... b.contentEnd {
                XCTAssertEqual(b.docPos(forAttrIndex: b.attrIndex(forDocPos: pos)), pos,
                               "\(text): round trip lost position \(pos)")
            }
        }
    }

    func testSelectionRectsAgreeAcrossTheFastPath() {
        // The mapping feeds rect geometry, so pin the geometry too.
        for text in ["a plain paragraph of ordinary words", "one with 😀 and cafe\u{0301} in it"] {
            let editor = try! Editor(extensions: fullKit())
            let s = editor.schema
            let doc = try! s.node("doc", [:], content: Fragment.from([
                try! s.node("paragraph", [:], content: Fragment.from([s.text(text)])),
            ]))
            let l = DocumentLayout(doc: doc, width: 390, theme: DocumentTheme(),
                                   blockCache: TextBlockLayoutCache())
            let rects = l.selectionRects(from: 1, to: doc.content.size - 1)
            XCTAssertFalse(rects.isEmpty, "\(text): no rects")
            XCTAssertTrue(rects.allSatisfy { $0.width > 0 }, "\(text): a rect collapsed")
        }
    }
}
#endif

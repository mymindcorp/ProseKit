#if canImport(UIKit)
import XCTest
import DocumentModel
import EditorSerialization
import SchemaKit
@testable import EditorUIKit

/// Pasting `public.rtf` when the pasteboard offers nothing richer.
///
/// TextEdit, Mail, Pages and most Windows apps put RTF on the pasteboard and no
/// HTML at all. That content used to reach the document only through
/// `NSAttributedString` → Cocoa's HTML writer; these cover reading the RTF
/// itself instead, and — just as importantly — that the established paths still
/// win whenever the pasteboard says more than plain RTF does.
@MainActor
final class NativeRTFPasteTests: XCTestCase {
    private func view() throws -> EditorTextView {
        let editor = try Editor(extensions: fullKit())
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        view.layoutIfNeeded()
        return view
    }

    /// UIPasteboard.general is blocked by the paste-authorization privacy gate
    /// in unhosted test processes; a uniquely named app pasteboard is owned by
    /// this process and exercises the same code.
    ///
    /// The flavours go on as one item with several representations, which is
    /// what a real copy produces. (`setData(_:forPasteboardType:)` replaces the
    /// pasteboard's contents, so calling it per flavour would leave only the
    /// last — and every "this flavour wins" assertion below would then pass
    /// because the RTF was missing, not because it was outranked.)
    private func pasteboard(_ entries: [(String, Data)]) -> UIPasteboard {
        let pb = UIPasteboard.withUniqueName()
        var item: [String: Any] = [:]
        for (type, data) in entries { item[type] = data }
        pb.setItems([item])
        return pb
    }

    private func rtf(_ body: String) -> Data {
        Data((#"{\rtf1\ansi\ansicpg1252{\fonttbl{\f0\fswiss Helvetica;}}"# + body + "}").utf8)
    }

    func testReadsRTFWhenItIsTheOnlyRichFlavour() throws {
        let view = try view()
        let pb = pasteboard([("public.rtf", rtf(#"\pard\outlinelevel0 Title\par\pard body \b bold\b0 \par"#))])

        let doc = try XCTUnwrap(view.nativeRTFPasteDoc(pb))
        XCTAssertEqual(doc.childCount, 2)
        XCTAssertEqual(doc.child(0).type.name, "heading")
        XCTAssertEqual(doc.child(0).textContent, "Title")
        XCTAssertEqual(doc.child(1).textContent, "body bold")
        XCTAssertTrue(doc.child(1).child(1).marks.contains { $0.type.name == "bold" })
    }

    func testKeepsStructureTheHTMLBridgeWouldFlatten() throws {
        let view = try view()
        let pb = pasteboard([("public.rtf", rtf(
            #"\trowd\cellx2880\cellx5760\pard\intbl a\cell\pard\intbl b\cell\row"# +
            #"\pard\ls1\ilvl0{\listtext\'b7\tab}item\par"#))])

        let doc = try XCTUnwrap(view.nativeRTFPasteDoc(pb))
        XCTAssertEqual(doc.child(0).type.name, "table")
        XCTAssertEqual(doc.child(0).child(0).childCount, 2)
        XCTAssertEqual(doc.child(1).type.name, "bulletList")
    }

    // MARK: - The flavours that still take precedence

    func testHTMLOnThePasteboardWins() throws {
        let view = try view()
        let pb = pasteboard([
            ("public.rtf", rtf(#"\pard from rtf\par"#)),
            ("public.html", Data("<p>from html</p>".utf8)),
        ])
        XCTAssertNil(view.nativeRTFPasteDoc(pb))
    }

    func testAppleNotesProtoWins() throws {
        let view = try view()
        let pb = pasteboard([
            ("public.rtf", rtf(#"\pard from rtf\par"#)),
            ("com.apple.notes.richtext", Data([0x00, 0x01, 0x02])),
        ])
        XCTAssertNil(view.nativeRTFPasteDoc(pb),
                     "the proto carries checklist state the RTF has flattened")
    }

    func testArchivedAttributedStringWins() throws {
        let view = try view()
        let attr = NSAttributedString(string: "archived")
        let data = try NSKeyedArchiver.archivedData(withRootObject: attr, requiringSecureCoding: true)
        let pb = pasteboard([
            ("public.rtf", rtf(#"\pard from rtf\par"#)),
            ("com.apple.uikit.attributedstring", data),
        ])
        XCTAssertNil(view.nativeRTFPasteDoc(pb))
    }

    func testRTFDWins() throws {
        let view = try view()
        for type in ["public.rtfd", "com.apple.flat-rtfd"] {
            let pb = pasteboard([
                ("public.rtf", rtf(#"\pard from rtf\par"#)),
                (type, Data([0x00])),
            ])
            XCTAssertNil(view.nativeRTFPasteDoc(pb), "\(type) carries attachments the RTF doesn't")
        }
    }

    // MARK: - Falling back rather than pasting nothing

    func testUnparseableRTFFallsThrough() throws {
        let view = try view()
        for data in [Data("not rtf at all".utf8), Data(), Data([0xFF, 0xFE, 0x00])] {
            let pb = pasteboard([("public.rtf", data)])
            XCTAssertNil(view.nativeRTFPasteDoc(pb))
        }
    }

    func testEmptyRTFFallsThrough() throws {
        let view = try view()
        let pb = pasteboard([("public.rtf", rtf(#"\pard\par"#))])
        XCTAssertNil(view.nativeRTFPasteDoc(pb),
                     "an RTF that says nothing must not beat the bridge's attempt")
    }

    func testPlainTextAlongsideRTFStillReadsTheRTF() throws {
        // A plain-text fallback is on nearly every pasteboard and says nothing
        // about formatting; it must not push the paste onto the plain path.
        let view = try view()
        let pb = pasteboard([
            ("public.rtf", rtf(#"\pard\outlinelevel0 Title\par"#)),
            ("public.utf8-plain-text", Data("Title".utf8)),
        ])
        let doc = try XCTUnwrap(view.nativeRTFPasteDoc(pb))
        XCTAssertEqual(doc.child(0).type.name, "heading")
    }

    // MARK: - The whole paste, not just the decision

    func testPasteInsertsTheParsedDocument() throws {
        let view = try view()
        let pb = pasteboard([("public.rtf", rtf(#"\pard\outlinelevel0 Heading\par\pard body\par"#))])
        let doc = try XCTUnwrap(view.nativeRTFPasteDoc(pb))
        view.insertContent(doc.content)
        XCTAssertTrue(view.editor.doc.textContent.contains("Heading"))
        XCTAssertTrue(view.editor.doc.textContent.contains("body"))
        XCTAssertTrue((0..<view.editor.doc.childCount).contains {
            view.editor.doc.child($0).type.name == "heading"
        })
    }
}
#endif

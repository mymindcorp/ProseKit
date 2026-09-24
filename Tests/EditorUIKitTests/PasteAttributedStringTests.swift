#if canImport(UIKit)
import XCTest
import DocumentModel
import SchemaKit
@testable import EditorUIKit

/// The com.apple.uikit.attributedstring pasteboard flavor: an archived
/// NSAttributedString that skips the RTF round-trip entirely.
@MainActor
final class PasteAttributedStringTests: XCTestCase {
    func testPastesArchivedAttributedString() throws {
        let editor = try Editor(extensions: fullKit())
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        view.layoutIfNeeded()

        let attr = NSAttributedString(string: "hello archive")
        let data = try NSKeyedArchiver.archivedData(withRootObject: attr, requiringSecureCoding: true)
        // UIPasteboard.general is blocked by the paste-authorization privacy
        // gate in unhosted test processes; a uniquely named app pasteboard is
        // owned by this process and exercises the same decode path.
        let pb = UIPasteboard.withUniqueName()
        pb.setData(data, forPasteboardType: "com.apple.uikit.attributedstring")

        let doc = view.richTextPasteDoc(pb)
        XCTAssertEqual(doc?.textContent.contains("hello archive"), true,
                       "got: \(doc?.textContent ?? "nil")")
    }

    // MARK: - The RTF flavours
    //
    // Pages, TextEdit and Mail put RTF on the pasteboard and no HTML at all.
    // Plain RTF is read directly first (`nativeRTFPasteDoc`, covered by
    // `NativeRTFPasteTests`); this bridge is where RTF lands when that reader
    // declines, and the only path for RTFD.

    private func view() throws -> EditorTextView {
        let editor = try Editor(extensions: fullKit())
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        view.layoutIfNeeded()
        return view
    }

    /// A bold word in a sentence, as RTF or RTFD.
    private func richData(_ type: NSAttributedString.DocumentType) throws -> Data {
        let attr = NSMutableAttributedString(string: "plain bold end")
        attr.addAttribute(.font, value: UIFont.boldSystemFont(ofSize: 14),
                          range: NSRange(location: 6, length: 4))
        return try attr.data(from: NSRange(location: 0, length: attr.length),
                             documentAttributes: [.documentType: type])
    }

    func testConvertsPublicRTF() throws {
        // The flavour Pages offers.
        let view = try view()
        let pb = UIPasteboard.withUniqueName()
        pb.setData(try richData(.rtf), forPasteboardType: "public.rtf")
        let doc = try XCTUnwrap(view.richTextPasteDoc(pb))
        XCTAssertEqual(doc.textContent, "plain bold end")
        XCTAssertTrue(hasBold(doc, around: "bold"), "the bold word should stay bold")
    }

    func testConvertsPublicRTFD() throws {
        let view = try view()
        let pb = UIPasteboard.withUniqueName()
        pb.setData(try richData(.rtfd), forPasteboardType: "public.rtfd")
        let doc = try XCTUnwrap(view.richTextPasteDoc(pb))
        XCTAssertEqual(doc.textContent, "plain bold end")
    }

    func testConvertsFlatRTFD() throws {
        let view = try view()
        let pb = UIPasteboard.withUniqueName()
        pb.setData(try richData(.rtfd), forPasteboardType: "com.apple.flat-rtfd")
        let doc = try XCTUnwrap(view.richTextPasteDoc(pb))
        XCTAssertEqual(doc.textContent, "plain bold end")
    }

    func testPrefersTheArchivedStringOverRTF() throws {
        // Both on the pasteboard: the archive skips the RTF round-trip's
        // losses, so it must win.
        let view = try view()
        let pb = UIPasteboard.withUniqueName()
        pb.setData(try richData(.rtf), forPasteboardType: "public.rtf")
        let archived = try NSKeyedArchiver.archivedData(
            withRootObject: NSAttributedString(string: "from the archive"),
            requiringSecureCoding: true)
        pb.setData(archived, forPasteboardType: "com.apple.uikit.attributedstring")
        let doc = try XCTUnwrap(view.richTextPasteDoc(pb))
        XCTAssertEqual(doc.textContent, "from the archive")
    }

    func testFallsThroughWhenAFlavourWontDecode() throws {
        // Rubbish under a flavour we prefer must not stop a good one being used.
        let view = try view()
        let pb = UIPasteboard.withUniqueName()
        pb.setData(Data("not an archive".utf8),
                   forPasteboardType: "com.apple.uikit.attributedstring")
        pb.setData(try richData(.rtf), forPasteboardType: "public.rtf")
        let doc = try XCTUnwrap(view.richTextPasteDoc(pb))
        XCTAssertEqual(doc.textContent, "plain bold end")
    }

    func testUndecodableRichDataYieldsNothing() throws {
        let view = try view()
        let pb = UIPasteboard.withUniqueName()
        pb.setData(Data("this is not RTF".utf8), forPasteboardType: "public.rtf")
        XCTAssertNil(view.richTextPasteDoc(pb), "nothing decoded, so nothing to paste")
    }

    func testNoRichFlavourYieldsNothing() throws {
        // Plain text alone is the caller's problem, not this bridge's.
        let view = try view()
        let pb = UIPasteboard.withUniqueName()
        pb.string = "just text"
        XCTAssertNil(view.richTextPasteDoc(pb))
    }

    func testRTFStructureSurvivesTheBridge() throws {
        // A paragraph break has to reach the document as two blocks, or a
        // pasted page arrives as one run-on line.
        let view = try view()
        let attr = NSAttributedString(string: "first line\nsecond line")
        let data = try attr.data(from: NSRange(location: 0, length: attr.length),
                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let pb = UIPasteboard.withUniqueName()
        pb.setData(data, forPasteboardType: "public.rtf")
        let doc = try XCTUnwrap(view.richTextPasteDoc(pb))
        XCTAssertEqual(doc.childCount, 2, "two paragraphs, got \(doc.childCount)")
        XCTAssertEqual(doc.child(0).textContent, "first line")
        XCTAssertEqual(doc.child(1).textContent, "second line")
    }

    func testABulletedListSurvivesTheBridge() throws {
        // A pasted page is mostly prose and lists; a list arriving as two loose
        // paragraphs is the kind of loss nobody notices until it's shipped.
        let view = try view()
        let attr = NSMutableAttributedString(string: "one\ntwo\n")
        let bullet = NSMutableParagraphStyle()
        bullet.textLists = [NSTextList(markerFormat: .disc, options: 0)]
        attr.addAttribute(.paragraphStyle, value: bullet,
                          range: NSRange(location: 0, length: attr.length))
        let data = try attr.data(from: NSRange(location: 0, length: attr.length),
                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let pb = UIPasteboard.withUniqueName()
        pb.setData(data, forPasteboardType: "public.rtf")
        let doc = try XCTUnwrap(view.richTextPasteDoc(pb))
        XCTAssertEqual(doc.child(0).type.name, "bulletList")
        XCTAssertEqual(doc.child(0).childCount, 2, "two items")
    }

    func testALinkSurvivesTheBridge() throws {
        // RTF carries the href, and losing it turns a linked document into flat
        // text that looks unchanged.
        let view = try view()
        let attr = NSMutableAttributedString(string: "see docs")
        attr.addAttribute(.link, value: URL(string: "https://example.com")!,
                          range: NSRange(location: 4, length: 4))
        let data = try attr.data(from: NSRange(location: 0, length: attr.length),
                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let pb = UIPasteboard.withUniqueName()
        pb.setData(data, forPasteboardType: "public.rtf")
        let doc = try XCTUnwrap(view.richTextPasteDoc(pb))
        var href: String?
        doc.descendants { node, _, _, _ in
            if node.isText, node.text == "docs" {
                href = node.marks.first { $0.type.name == "link" }?.attrs["href"]?.stringValue
            }
            return true
        }
        XCTAssertEqual(href, "https://example.com")
    }

    /// Whether the text containing `word` carries a bold mark.
    private func hasBold(_ doc: Node, around word: String) -> Bool {
        var bold = false
        doc.descendants { node, _, _, _ in
            if node.isText, node.text?.contains(word) == true,
               node.marks.contains(where: { $0.type.name == "bold" }) { bold = true }
            return !bold
        }
        return bold
    }

    // MARK: - The Apple Notes proto
    //
    // A minimal Note protobuf (2: text, 5: attribute runs { 1: length,
    // 2: paragraph style { 1: style type } }) wrapped the way Notes wraps it:
    // an NSData blob in a keyed archive's `$objects`.

    private func varint(_ v: Int) -> [UInt8] {
        var v = UInt64(v), out: [UInt8] = []
        repeat {
            var b = UInt8(v & 0x7f)
            v >>= 7
            if v != 0 { b |= 0x80 }
            out.append(b)
        } while v != 0
        return out
    }
    private func chunk(_ field: Int, _ payload: [UInt8]) -> [UInt8] {
        varint(field << 3 | 2) + varint(payload.count) + payload
    }
    /// "Title" as a title line (style 0), then a body line.
    private func notesArchive() throws -> Data {
        let titleRun = varint(1 << 3) + varint(6) + chunk(2, varint(1 << 3) + varint(0))
        let bodyRun = varint(1 << 3) + varint(5)
        let note = chunk(2, Array("Title\nbody\n".utf8)) + chunk(5, titleRun) + chunk(5, bodyRun)
        return try PropertyListSerialization.data(fromPropertyList: ["$objects": ["$null", Data(note)]],
                                                  format: .binary, options: 0)
    }

    func testANotesProtoMatchingTheRichTextIsPastedFromTheProto() throws {
        let view = try view()
        let rtf = try NSAttributedString(string: "Title\nbody").data(
            from: NSRange(location: 0, length: 10), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let pb = UIPasteboard.withUniqueName()
        pb.setItems([["public.rtf": rtf, "com.apple.notes.richtext": try notesArchive()]])
        let doc = try XCTUnwrap(view.richTextPasteDoc(pb))
        XCTAssertEqual(doc.child(0).type.name, "heading", "the title style only the proto knows about")
        XCTAssertEqual(doc.child(0).textContent, "Title")
        XCTAssertEqual(doc.child(1).textContent, "body")
    }

    func testANotesProtoAloneIsStillPasted() throws {
        let view = try view()
        let pb = UIPasteboard.withUniqueName()
        pb.setItems([["com.apple.notes.richtext": try notesArchive()]])
        let doc = try XCTUnwrap(view.richTextPasteDoc(pb), "no RTF and no text: the proto is all there is")
        XCTAssertEqual(doc.child(0).type.name, "heading")
        XCTAssertEqual(doc.textContent, "Titlebody")
    }
}
#endif

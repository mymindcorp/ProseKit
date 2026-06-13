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
}
#endif

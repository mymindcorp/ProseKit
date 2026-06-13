#if canImport(UIKit)
import XCTest
import DocumentModel
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

@MainActor
final class SuggestionModeViewTests: XCTestCase {
    private func makeView(_ editor: Editor) -> EditorTextView {
        let view = EditorTextView(editor: editor)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        view.backgroundColor = .white
        view.layoutIfNeeded()
        return view
    }

    private func render(_ view: EditorTextView) -> UIImage {
        UIGraphicsImageRenderer(bounds: view.bounds).image { ctx in
            view.layer.render(in: ctx.cgContext)
        }
    }

    /// True if any pixel satisfies the predicate on (r, g, b) bytes.
    private func hasPixel(_ image: UIImage, _ predicate: (UInt8, UInt8, UInt8) -> Bool) -> Bool {
        guard let cg = image.cgImage else { return false }
        let width = cg.width, height = cg.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        for i in stride(from: 0, to: data.count, by: 4) where predicate(data[i], data[i + 1], data[i + 2]) {
            return true
        }
        return false
    }

    func testInsertionAndDeletionSuggestionsRender() throws {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        editor.setContent(try s.node("doc", [:], content: Fragment.from([
            try s.node("paragraph", [:], content: Fragment.from([s.text("hello world goodbye")])),
        ])))
        editor.dispatch(setSuggestionMode(editor.state.tr, enabled: true))
        // Suggest deleting " world" and inserting "!" at the end.
        let tr = editor.state.tr
        try tr.delete(6, 12)
        editor.dispatch(tr)
        let tr2 = editor.state.tr
        try tr2.insertText("!", editor.doc.content.size - 1)
        editor.dispatch(tr2)
        XCTAssertEqual(suggestionModeKey.getState(editor.state)?.changes.count, 2)

        let image = render(makeView(editor))
        // Suggestions are tinted by author (default "user"): the deletion text
        // draws in the author color, the insertion highlight is that color at
        // 20% over the white background.
        let (ar, ag, ab) = rgb(EditorTextView.authorColor("user"))
        XCTAssertTrue(hasPixel(image) { r, g, b in near(r, ar) && near(g, ag) && near(b, ab) },
                      "expected author-colored deletion-widget pixels")
        let blend: (UInt8, UInt8) -> UInt8 = { author, _ in UInt8(0.8 * 255 + 0.2 * Double(author)) }
        let (ir, ig, ib) = (blend(ar, 255), blend(ag, 255), blend(ab, 255))
        XCTAssertTrue(hasPixel(image) { r, g, b in near(r, ir, 24) && near(g, ig, 24) && near(b, ib, 24) },
                      "expected author-tinted insertion-highlight pixels")
    }

    private func rgb(_ color: UIColor) -> (UInt8, UInt8, UInt8) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (UInt8(r * 255), UInt8(g * 255), UInt8(b * 255))
    }
    private func near(_ a: UInt8, _ b: UInt8, _ tol: Int = 14) -> Bool { abs(Int(a) - Int(b)) <= tol }

    func testNoSuggestionVisualsWhenDisabled() throws {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        editor.setContent(try s.node("doc", [:], content: Fragment.from([
            try s.node("paragraph", [:], content: Fragment.from([s.text("hello world")])),
        ])))
        let tr = editor.state.tr
        try tr.delete(6, 12)
        editor.dispatch(tr)
        let image = render(makeView(editor))
        let (ar, ag, ab) = rgb(EditorTextView.authorColor("user"))
        XCTAssertFalse(hasPixel(image) { r, g, b in near(r, ar) && near(g, ag) && near(b, ab) },
                       "no suggestion pixels when suggestion mode is off")
    }
}
#endif

#if canImport(UIKit)
import XCTest
import DocumentModel
import EditorStateKit
import SchemaKit
@testable import EditorUIKit

@MainActor
final class HighlightRenderTests: XCTestCase {
    private func render(_ view: EditorTextView) -> UIImage {
        UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            view.layer.render(in: UIGraphicsGetCurrentContext()!)
        }
    }
    private func hasPixel(_ image: UIImage, _ predicate: (UInt8, UInt8, UInt8) -> Bool) -> Bool {
        guard let cg = image.cgImage else { return false }
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        for i in stride(from: 0, to: data.count, by: 4) where predicate(data[i], data[i + 1], data[i + 2]) { return true }
        return false
    }

    private func view(highlightColor: String?) throws -> EditorTextView {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        var attrs: Attrs = [:]
        if let highlightColor { attrs["color"] = .string(highlightColor) }
        let mark = s.marks["highlight"]!.create(attrs)
        let para = try s.node("paragraph", [:], content: Fragment.from([
            s.text("plain "), s.text("HIGHLIGHTED", [mark]), s.text(" plain"),
        ]))
        editor.setContent(try s.node("doc", [:], content: Fragment.from([para])))
        let v = EditorTextView(editor: editor)
        v.frame = CGRect(x: 0, y: 0, width: 320, height: 120)
        v.backgroundColor = .white
        v.layoutIfNeeded()
        return v
    }

    func testDefaultHighlightRendersYellowBackground() throws {
        let image = render(try view(highlightColor: nil))
        // systemYellow @ 0.40 over white ≈ (255, 234, 153): bright, low-ish blue.
        XCTAssertTrue(hasPixel(image) { r, g, b in r > 235 && g > 205 && b < 195 && b < g },
                      "expected a yellow highlight background")
    }

    func testGreenHighlightRendersGreenBackground() throws {
        let image = render(try view(highlightColor: "green"))
        XCTAssertTrue(hasPixel(image) { r, g, b in g > 190 && g > r && g > b },
                      "expected a green highlight background")
    }

    func testNoHighlightNoColoredBackground() throws {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        editor.setContent(try s.node("doc", [:], content: Fragment.from([
            try s.node("paragraph", [:], content: Fragment.from([s.text("plain text only")])),
        ])))
        let v = EditorTextView(editor: editor)
        v.frame = CGRect(x: 0, y: 0, width: 320, height: 120)
        v.backgroundColor = .white
        v.layoutIfNeeded()
        let image = render(v)
        XCTAssertFalse(hasPixel(image) { r, g, b in r > 235 && g > 205 && b < 195 && b < g },
                       "no yellow background without a highlight")
    }

    private func codeView(language: String?) throws -> EditorTextView {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        var attrs: Attrs = [:]
        if let language { attrs["language"] = .string(language) }
        let code = try s.node("codeBlock", attrs, content: Fragment.from([s.text("let x = 1")]))
        editor.setContent(try s.node("doc", [:], content: Fragment.from([code])))
        let v = EditorTextView(editor: editor)
        v.frame = CGRect(x: 0, y: 0, width: 320, height: 120)
        v.backgroundColor = .white
        return v
    }

    func testSyntaxHighlighterColorsCodeBlockAndReceivesLanguage() throws {
        let v = try codeView(language: "swift")
        // Only colors when the language arrives as "swift" → red proves both the
        // hook ran and the language attribute was passed through.
        v.syntaxHighlighter = { _, lang in
            lang == "swift" ? [SyntaxToken(range: 0..<3, color: .systemRed)] : []
        }
        v.layoutIfNeeded()
        let image = render(v)
        XCTAssertTrue(hasPixel(image) { r, g, b in r > 150 && g < 110 && b < 110 },
                      "code-block token rendered in the highlighter's color")
    }

    func testNoSyntaxHighlighterLeavesCodePlain() throws {
        let v = try codeView(language: "swift")
        v.layoutIfNeeded()
        let image = render(v)
        XCTAssertFalse(hasPixel(image) { r, g, b in r > 150 && g < 110 && b < 110 },
                       "no red without a highlighter")
    }

    func testCodeLanguageBadgeAppearsWhenLabelProvided() throws {
        let v = try codeView(language: "swift")
        v.codeLanguageLabel = { _, language in language == nil ? nil : "Swift" }
        v.layoutIfNeeded()
        let decos = v.ensureLayout().decorations
        let hasBadge = decos.contains {
            if case let .text(str, _, _) = $0 { return str == "Swift" }
            return false
        }
        XCTAssertTrue(hasBadge, "a language badge is drawn for the code block")
    }

    func testNoBadgeWithoutLabelHook() throws {
        let v = try codeView(language: "swift")
        v.layoutIfNeeded()
        let decos = v.ensureLayout().decorations
        let hasBadge = decos.contains {
            if case let .text(str, _, _) = $0 { return str == "Swift" }
            return false
        }
        XCTAssertFalse(hasBadge, "no badge without a codeLanguageLabel hook")
    }

    func testHighlightTracksTheWordAfterAnEditBefore() throws {
        // The highlight range maps with edits (incremental layout shifts it).
        let v = try view(highlightColor: nil)
        let tr = v.editor.state.tr
        try tr.insertText("XX", 1)
        v.editor.dispatch(tr)
        let image = render(v)
        XCTAssertTrue(hasPixel(image) { r, g, b in r > 235 && g > 205 && b < 195 && b < g },
                      "highlight still renders after an edit before it")
    }
}
#endif

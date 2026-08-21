#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import SchemaKit
import EditorSerialization
@testable import EditorUIKit

/// `theme.image.cornerRadius`: pictures drawn with rounded corners.
///
/// Off by default — an image draws with the corners its bytes came with until a
/// host asks for otherwise.
@MainActor
final class ImageCornerRadiusTests: XCTestCase {
    /// A solid red image, so "was this corner painted?" is a colour test.
    ///
    /// Scale 1 deliberately, as in `ImageSizeModelTests`: at the screen's scale
    /// the decoded image would come back one point per *pixel*.
    private func png(_ size: CGSize = CGSize(width: 200, height: 100)) -> Data {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
        }.pngData()!
    }

    private func makeView(radius: CGFloat, bytes: Data?) throws -> EditorTextView {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        editor.setContent(try s.node("doc", [:], content: Fragment.from([
            try s.node("image", ["src": .string("asset://photo")]),
        ])))
        let view = EditorTextView(editor: editor)
        var theme = DocumentTheme()
        theme.image.cornerRadius = radius
        view.theme = theme
        view.backgroundColor = .white
        if let bytes { view.imageData = { $0.type.name == "image" ? bytes : nil } }
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 400)
        view.layoutIfNeeded()
        return view
    }

    /// The view's pixels, at one pixel per point.
    private func render(_ view: EditorTextView) -> [UInt8] {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            view.layer.render(in: UIGraphicsGetCurrentContext()!)
        }
        let cg = image.cgImage!
        var data = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let ctx = unsafe CGContext(data: &data, width: cg.width, height: cg.height,
                                   bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return data
    }

    /// Is the picture painted at this point of the view?
    private func isPainted(_ view: EditorTextView, _ pixels: [UInt8], _ point: CGPoint) -> Bool {
        let width = Int(view.bounds.width)
        let i = (Int(point.y) * width + Int(point.x)) * 4
        guard i + 2 < pixels.count else { return false }
        return pixels[i] > 200 && pixels[i + 1] < 80 && pixels[i + 2] < 80
    }

    private func imageRect(_ view: EditorTextView) throws -> CGRect {
        try XCTUnwrap(view.ensureLayout().imageRects.first?.rect)
    }

    // MARK: - Drawing

    func testAPictureKeepsItsSquareCornersByDefault() throws {
        let view = try makeView(radius: 0, bytes: png())
        let rect = try imageRect(view)
        let pixels = render(view)
        XCTAssertTrue(isPainted(view, pixels, CGPoint(x: rect.minX + 2, y: rect.minY + 2)),
                      "with no radius the very corner is the picture")
    }

    func testARadiusClipsThePictureCorners() throws {
        let view = try makeView(radius: 24, bytes: png())
        let rect = try imageRect(view)
        let pixels = render(view)
        for corner in [CGPoint(x: rect.minX + 2, y: rect.minY + 2),
                       CGPoint(x: rect.maxX - 3, y: rect.minY + 2),
                       CGPoint(x: rect.minX + 2, y: rect.maxY - 3),
                       CGPoint(x: rect.maxX - 3, y: rect.maxY - 3)] {
            XCTAssertFalse(isPainted(view, pixels, corner), "corner \(corner) is clipped away")
        }
        XCTAssertTrue(isPainted(view, pixels, CGPoint(x: rect.midX, y: rect.midY)),
                      "and the picture itself still draws")
        XCTAssertTrue(isPainted(view, pixels, CGPoint(x: rect.midX, y: rect.minY + 2)),
                      "including the straight run between the corners")
    }

    func testTheDrawnBoxIsUnchangedByARadius() throws {
        // Rounding is a clip, not a layout change: nothing around the picture
        // moves, and drag-to-resize still hits the same rect.
        let square = try imageRect(makeView(radius: 0, bytes: png()))
        let rounded = try imageRect(makeView(radius: 24, bytes: png()))
        XCTAssertEqual(square, rounded)
    }

    // MARK: - The clamp

    func testARadiusIsCappedAtHalfTheShorterSide() {
        var theme = DocumentTheme()
        theme.image.cornerRadius = 999
        let rect = CGRect(x: 0, y: 0, width: 200, height: 100)
        XCTAssertEqual(DocumentLayout.imageCornerRadius(theme, in: rect), 50,
                       "a huge radius gives a capsule, not an undefined path")
    }

    func testNoRadiusMeansNoClip() {
        let theme = DocumentTheme()
        XCTAssertEqual(theme.image.cornerRadius, 0, "square corners by default")
        XCTAssertNil(DocumentLayout.imageCornerRadius(theme, in: CGRect(x: 0, y: 0, width: 200, height: 100)))
    }

    // MARK: - The placeholder

    func testThePlaceholderBoxTakesTheSameRadius() throws {
        // The box drawn while the bytes load is the picture's stand-in, so it
        // has to be the same shape — otherwise the corners change when it loads.
        let view = try makeView(radius: 24, bytes: nil)
        let rounded = view.ensureLayout().decorations.contains {
            if case let .roundedStroke(_, _, _, radius) = $0 { return radius == 24 }
            return false
        }
        XCTAssertTrue(rounded)
    }

    func testThePlaceholderBoxStaysSquareByDefault() throws {
        let view = try makeView(radius: 0, bytes: nil)
        let square = view.ensureLayout().decorations.contains {
            if case .stroke = $0 { return true }
            return false
        }
        XCTAssertTrue(square)
    }
}
#endif

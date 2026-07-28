#if canImport(UIKit)
import UIKit
import CoreText
import EditorUIKit

/// Build a math renderer for the EditorUIKit hook.
///
/// ```swift
/// editorView.mathRenderer = makeMathRenderer()
/// ```
///
/// Formulas are typeset natively — no web view, no JavaScript — following
/// TeX's box model, so a formula draws as vectors at whatever size the theme's
/// body font is and stays sharp under zoom.
///
/// Laid-out formulas are cached by source and size, which is what keeps
/// per-keystroke relayout cheap in a document full of math. The cache holds no
/// color: a formula's geometry doesn't depend on it, and the draw closure reads
/// the color at draw time so light/dark switches don't need a re-layout.
///
/// - Parameter cacheLimit: how many laid-out formulas to keep. The cache is
///   cleared wholesale when it grows past this.
public func makeMathRenderer(cacheLimit: Int = 512) -> MathRenderer {
    let cache = MathLayoutCache(limit: cacheLimit)
    return { latex, display, font, color in
        guard let result = cache.layout(latex, display: display, font: font) else { return nil }
        let box = result.box
        return MathRendering(
            size: CGSize(width: box.width, height: box.height),
            ascent: box.ascent,
            isError: result.isError,
            draw: { ctx, topLeft in
                // The box's origin is on its baseline; the hook's is the top-left.
                box.draw(in: ctx, at: CGPoint(x: topLeft.x, y: topLeft.y + box.ascent),
                         color: color.cgColor)
            })
    }
}

/// Caches laid-out formulas by source, style, and font.
private final class MathLayoutCache: @unchecked Sendable {
    private struct Key: Hashable {
        let latex: String
        let display: Bool
        let fontName: String
        let size: CGFloat
    }
    private let limit: Int
    private let lock = NSLock()
    private var entries: [Key: MathLayoutResult] = [:]

    init(limit: Int) { self.limit = limit }

    func layout(_ latex: String, display: Bool, font: UIFont) -> MathLayoutResult? {
        guard !latex.isEmpty else { return nil }
        let key = Key(latex: latex, display: display, fontName: font.fontName, size: font.pointSize)
        lock.lock()
        defer { lock.unlock() }
        if let cached = entries[key] { return cached }
        let bodyFont = CTFontCreateWithName(font.fontName as CFString, font.pointSize, nil)
        let result = MathTypesetter(baseSize: font.pointSize, bodyFont: bodyFont)
            .layout(latex, display: display)
        // A crude but adequate bound: math-heavy documents reuse the same
        // formulas across relayouts, so a full flush costs one re-typeset each.
        if entries.count >= limit { entries.removeAll(keepingCapacity: true) }
        entries[key] = result
        return result
    }
}
#endif

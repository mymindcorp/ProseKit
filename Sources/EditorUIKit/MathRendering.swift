#if canImport(UIKit)
public import UIKit

/// A typeset formula, ready to draw.
///
/// The renderer hands back geometry plus a draw closure rather than an image, so
/// a formula stays vector-sharp at any zoom and costs no bitmap memory. `ascent`
/// is what lets an inline formula share a baseline with the text around it —
/// `size.height - ascent` is how far it hangs below.
public struct MathRendering {
    /// The formula's ink extents.
    public var size: CGSize
    /// The distance from the top of `size` down to the formula's baseline.
    public var ascent: CGFloat
    /// True when the source didn't parse and the drawing is its verbatim text.
    /// The editor tints those so a typo is visible rather than silent.
    public var isError: Bool
    /// Draws the formula with its top-left corner at the given point, in the
    /// view's (y-down) coordinate space.
    public var draw: (_ ctx: CGContext, _ topLeft: CGPoint) -> Void

    public init(size: CGSize, ascent: CGFloat, isError: Bool = false,
                draw: @escaping (_ ctx: CGContext, _ topLeft: CGPoint) -> Void) {
        self.size = size
        self.ascent = ascent
        self.isError = isError
        self.draw = draw
    }
}

/// Typesets a LaTeX formula for the editor's `inlineMath` / `blockMath` nodes.
///
/// `display` is true for a block formula (TeX's display style: bigger operators,
/// limits stacked above and below) and false for one inline in a line of text.
/// `font` is the surrounding text's font — the formula is sized to match it, and
/// `\text{…}` is set in it. Return nil to fall back to showing the raw source.
///
/// `EditorMath.makeMathRenderer()` supplies an implementation; assign it to
/// `EditorTextView.mathRenderer`.
public typealias MathRenderer = (_ latex: String, _ display: Bool, _ font: UIFont, _ color: UIColor) -> MathRendering?
#endif

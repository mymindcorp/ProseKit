public import Foundation
public import CoreText
public import CoreGraphics

// The typesetter's output: a tree of positioned drawing primitives flattened
// into one box per formula.
//
// Box coordinates put the origin on the baseline at the box's left edge, with
// **+y pointing up** — the convention TeX's box arithmetic is written in. The
// draw call flips into that space once, so nothing downstream has to reason
// about two coordinate systems.

/// A primitive the renderer draws.
public enum MathDrawItem {
    /// Glyphs from one font, at pen positions relative to the box origin.
    case glyphs(font: CTFont, glyphs: [CGGlyph], positions: [CGPoint])
    /// A filled rectangle — a fraction bar, an overline, a matrix rule.
    case rule(CGRect)
    /// A stroked path — the radical sign.
    case strokedPath(CGPath, lineWidth: CGFloat)
    /// A filled path — a stretched delimiter's outline.
    case filledPath(CGPath)
}

/// A laid-out piece of a formula.
public struct MathBox {
    /// Total advance width.
    public var width: CGFloat = 0
    /// Ink extent above the baseline.
    public var ascent: CGFloat = 0
    /// Ink extent below the baseline.
    public var descent: CGFloat = 0
    var items: [MathDrawItem] = []
    /// Overhang of the last glyph's ink past its advance — what a following
    /// superscript has to be nudged clear of.
    var italicCorrection: CGFloat = 0

    /// The box's full height.
    public var height: CGFloat { ascent + descent }

    /// The primitives this box draws, in box coordinates. Exposed for
    /// inspection — drawing goes through `draw(in:at:color:)`.
    public var drawItems: [MathDrawItem] { items }

    /// A box with no ink and no width. (Computed rather than `static let` —
    /// `CTFont` isn't `Sendable`, so `MathBox` can't be a shared constant.)
    static var empty: MathBox { MathBox() }

    /// A box that occupies width but draws nothing.
    static func space(_ width: CGFloat) -> MathBox {
        MathBox(width: width, ascent: 0, descent: 0)
    }

    /// Move every primitive by (dx, dy) — dy positive moves *up*. A box with no
    /// primitives (pure spacing) has no ink to shift, so its extents stay put.
    func offset(dx: CGFloat, dy: CGFloat) -> MathBox {
        guard (dx != 0 || dy != 0), !items.isEmpty else { return self }
        var moved = self
        moved.items = items.map { $0.offset(dx: dx, dy: dy) }
        moved.ascent = ascent + dy
        moved.descent = descent - dy
        return moved
    }

    /// Merge another box's primitives into this one at the given offset, growing
    /// the ink extents but not the advance width.
    mutating func overlay(_ other: MathBox, dx: CGFloat, dy: CGFloat) {
        let moved = other.offset(dx: dx, dy: dy)
        items.append(contentsOf: moved.items)
        ascent = max(ascent, moved.ascent)
        descent = max(descent, moved.descent)
    }

    /// Append a box to the right, optionally after a gap.
    mutating func append(_ other: MathBox, gap: CGFloat = 0) {
        let x = width + gap
        items.append(contentsOf: other.offset(dx: x, dy: 0).items)
        ascent = max(ascent, other.ascent)
        descent = max(descent, other.descent)
        width = x + other.width
        italicCorrection = other.italicCorrection
    }

    /// A box from a measured string.
    init(_ run: GlyphRun) {
        width = run.width
        ascent = run.ascent
        descent = run.descent
        italicCorrection = run.italicCorrection
        items = run.groups.map { .glyphs(font: $0.font, glyphs: $0.glyphs, positions: $0.positions) }
    }

    init(width: CGFloat = 0, ascent: CGFloat = 0, descent: CGFloat = 0,
         items: [MathDrawItem] = [], italicCorrection: CGFloat = 0) {
        self.width = width
        self.ascent = ascent
        self.descent = descent
        self.items = items
        self.italicCorrection = italicCorrection
    }

    /// Draw the box with its baseline-left corner at `origin`, in a context whose
    /// y axis points *down* (the UIKit default).
    public func draw(in ctx: CGContext, at origin: CGPoint, color: CGColor) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.translateBy(x: origin.x, y: origin.y)
        // Flip into box space: +y up, which also makes CoreText draw upright.
        ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(color)
        ctx.setStrokeColor(color)
        ctx.textMatrix = .identity
        for item in items {
            switch item {
            case let .glyphs(font, glyphs, positions):
                unsafe CTFontDrawGlyphs(font, glyphs, positions, glyphs.count, ctx)
            case let .rule(rect):
                ctx.fill(rect)
            case let .strokedPath(path, lineWidth):
                ctx.setLineWidth(lineWidth)
                ctx.setLineJoin(.miter)
                ctx.setLineCap(.butt)
                ctx.addPath(path)
                ctx.strokePath()
            case let .filledPath(path):
                ctx.addPath(path)
                ctx.fillPath()
            }
        }
    }
}

extension MathDrawItem {
    func offset(dx: CGFloat, dy: CGFloat) -> MathDrawItem {
        switch self {
        case let .glyphs(font, glyphs, positions):
            return .glyphs(font: font, glyphs: glyphs,
                           positions: positions.map { CGPoint(x: $0.x + dx, y: $0.y + dy) })
        case let .rule(rect):
            return .rule(rect.offsetBy(dx: dx, dy: dy))
        case let .strokedPath(path, lineWidth):
            return .strokedPath(transform(path, dx: dx, dy: dy), lineWidth: lineWidth)
        case let .filledPath(path):
            return .filledPath(transform(path, dx: dx, dy: dy))
        }
    }

    private func transform(_ path: CGPath, dx: CGFloat, dy: CGFloat) -> CGPath {
        var t = CGAffineTransform(translationX: dx, y: dy)
        return unsafe path.copy(using: &t) ?? path
    }
}

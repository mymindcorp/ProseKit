import Foundation
import CoreText
import CoreGraphics

// The typesetter: an atom list in, one `MathBox` out.
//
// The box arithmetic follows TeX's Appendix G (which is also what KaTeX
// implements), with the same font parameters. Where TeX reads a value from a
// Computer Modern font's parameter block, we use its Computer Modern value as a
// fraction of the em — the faces available here have no math parameter block,
// and the constants are what give TeX-set math its familiar proportions.

/// TeX's math font parameters, as fractions of one em.
enum TeXMetrics {
    /// The height of the math axis — where fraction bars and `−` sit, and what
    /// big operators and delimiters center on.
    static let axisHeight: CGFloat = 0.25
    static let defaultRuleThickness: CGFloat = 0.04

    // Fraction numerator/denominator shifts.
    static let num1: CGFloat = 0.677   // display, with a bar
    static let num2: CGFloat = 0.394   // text, with a bar
    static let num3: CGFloat = 0.444   // no bar (\atop, \binom)
    static let denom1: CGFloat = 0.686 // display
    static let denom2: CGFloat = 0.345 // text and smaller

    // Script shifts.
    static let sup1: CGFloat = 0.413   // display
    static let sup2: CGFloat = 0.363   // text
    static let sup3: CGFloat = 0.289   // cramped
    static let sub1: CGFloat = 0.15    // no superscript present
    static let sub2: CGFloat = 0.247   // superscript present
    static let supDrop: CGFloat = 0.386
    static let subDrop: CGFloat = 0.05

    // Limits above/below a big operator.
    static let bigOpSpacing1: CGFloat = 0.111  // minimum gap above
    static let bigOpSpacing2: CGFloat = 0.166  // minimum gap below
    static let bigOpSpacing3: CGFloat = 0.2    // minimum upper-limit baseline drop
    static let bigOpSpacing4: CGFloat = 0.6    // minimum lower-limit baseline rise
    static let bigOpSpacing5: CGFloat = 0.1    // padding above and below the pile

    /// A `\left…\right` delimiter covers at least this fraction of the body's
    /// extent about the axis, or all but `delimiterShortfall` of it.
    static let delimiterFactor: CGFloat = 0.901
    static let delimiterShortfall: CGFloat = 0.35
    /// The width a null delimiter (`.`) still reserves.
    static let nullDelimiterSpace: CGFloat = 0.12
    /// How much a big operator's glyph grows in display style.
    static let displayOperatorScale: CGFloat = 1.4
    /// The vertical rules an `array` column spec draws (TeX's `\arrayrulewidth`,
    /// 0.4pt, as a fraction of a 17pt em).
    static let arrayRuleWidth: CGFloat = 0.024
}

/// A thin/medium/thick space, in TeX's mu (1 mu = 1/18 em).
private enum MuSpace: Int {
    case none = 0, thin = 3, medium = 4, thick = 5
    var em: CGFloat { CGFloat(rawValue) / 18 }
}

/// The inter-atom space TeX puts between a left and right atom class. Medium and
/// thick spaces vanish in script styles; thin spaces never do.
private func interAtomSpace(_ left: MathClass, _ right: MathClass, tight: Bool) -> CGFloat {
    // The TeXbook's Chapter 18 table. `scriptSensitive` marks the entries the
    // book parenthesizes — suppressed in script and scriptscript styles.
    let (space, scriptSensitive): (MuSpace, Bool)
    switch (left, right) {
    case (.ord, .op), (.op, .ord), (.op, .op), (.close, .op), (.inner, .op):
        (space, scriptSensitive) = (.thin, false)
    case (.ord, .bin), (.op, .bin), (.close, .bin), (.inner, .bin),
         (.bin, .ord), (.bin, .op), (.bin, .open), (.bin, .inner):
        (space, scriptSensitive) = (.medium, true)
    case (.ord, .rel), (.op, .rel), (.close, .rel), (.inner, .rel),
         (.rel, .ord), (.rel, .op), (.rel, .open), (.rel, .inner):
        (space, scriptSensitive) = (.thick, true)
    case (.ord, .inner), (.close, .inner), (.inner, .ord), (.inner, .open),
         (.inner, .punct), (.inner, .inner):
        (space, scriptSensitive) = (.thin, true)
    case (.punct, _):
        (space, scriptSensitive) = (.thin, true)
    default:
        return 0
    }
    if scriptSensitive, tight { return 0 }
    return space.em
}

/// A formula ready to draw: its box plus whether the source parsed.
public struct MathLayoutResult {
    public let box: MathBox
    /// The parse error, when the source was rejected and the box holds the
    /// verbatim source instead of a formula.
    public let error: String?
    public var isError: Bool { error != nil }
}

/// Typesets LaTeX math at a fixed base size.
public final class MathTypesetter {
    /// The point size of a display-style formula.
    private let baseSize: CGFloat
    /// The surrounding text's font, used for `\text{…}`.
    private let bodyFont: CTFont
    private var fontsByStyle: [MathStyle: MathFontSet] = [:]

    public init(baseSize: CGFloat, bodyFont: CTFont) {
        self.baseSize = baseSize
        self.bodyFont = bodyFont
    }

    /// Typeset a formula. A source the parser rejects comes back as a box of the
    /// verbatim source with `error` set, matching KaTeX's `throwOnError: false`.
    public func layout(_ latex: String, display: Bool) -> MathLayoutResult {
        let style: MathStyle = display ? .display : .text
        do {
            let atoms = try LatexParser.parse(latex)
            return MathLayoutResult(box: layout(atoms, Context(style: style, cramped: false)), error: nil)
        } catch let error as LatexError {
            return MathLayoutResult(box: verbatim(latex), error: error.message)
        } catch {
            return MathLayoutResult(box: verbatim(latex), error: "\(error)")
        }
    }

    /// The source drawn as plain monospaced text, for a formula that didn't parse.
    private func verbatim(_ latex: String) -> MathBox {
        let fonts = fonts(for: .text)
        guard let run = measure(latex, in: fonts.monospace) else { return .empty }
        return MathBox(run)
    }

    // MARK: - Context

    /// Where in the formula the typesetter currently is. "Cramped" is TeX's flag
    /// for positions with no room above — a denominator, the body of a radical —
    /// where superscripts are set lower.
    private struct Context {
        var style: MathStyle
        var cramped: Bool

        func with(style: MathStyle) -> Context { Context(style: style, cramped: cramped) }
        func with(style: MathStyle, cramped: Bool) -> Context { Context(style: style, cramped: cramped) }
        var crampedSelf: Context { Context(style: style, cramped: true) }
        var scripts: MathStyle { style.scriptStyle }
        var isTight: Bool { style.isTight }
    }

    private func fonts(for style: MathStyle) -> MathFontSet {
        if let cached = fontsByStyle[style] { return cached }
        let set = mathFontSet(size: baseSize * style.sizeMultiplier, body: bodyFont)
        fontsByStyle[style] = set
        return set
    }

    /// One em at the given style's size.
    private func em(_ style: MathStyle) -> CGFloat { baseSize * style.sizeMultiplier }

    // MARK: - Lists

    private func layout(_ atoms: [MathAtom], _ ctx: Context) -> MathBox {
        let atoms = normalizeBinaries(atoms)
        var result = MathBox.empty
        var previousClass: MathClass?
        for atom in atoms {
            let (box, cls) = layoutAtom(atom, ctx)
            let gap = previousClass.map { interAtomSpace($0, cls, tight: ctx.isTight) * em(ctx.style) } ?? 0
            result.append(box, gap: gap)
            previousClass = cls
        }
        return result
    }

    /// TeX's rule that a binary operator with nothing to bind on its left is
    /// really a unary sign: `-x`, `(-1)`, `\times` after a relation.
    private func normalizeBinaries(_ atoms: [MathAtom]) -> [MathAtom] {
        var out = atoms
        for i in out.indices where out[i].cls == .bin {
            let previous = i > 0 ? out[i - 1].cls : nil
            switch previous {
            case nil, .bin?, .op?, .rel?, .open?, .punct?:
                out[i].cls = .ord
            default:
                break
            }
        }
        // A binary operator with nothing to bind on its *right* is unary too.
        for i in out.indices where out[i].cls == .bin {
            let next = i + 1 < out.count ? out[i + 1].cls : nil
            if next == nil || next == .rel || next == .close || next == .punct {
                out[i].cls = .ord
            }
        }
        return out
    }

    // MARK: - Atoms

    /// Lay out one atom's nucleus and attach its scripts. Returns the box and the
    /// class it spaces as (which scripts don't change).
    private func layoutAtom(_ atom: MathAtom, _ ctx: Context) -> (MathBox, MathClass) {
        let nucleus = layoutNucleus(atom.kind, ctx)
        guard atom.sub != nil || atom.sup != nil else { return (nucleus, atom.cls) }

        // A big operator (or a `\lim`-style function) in display style stacks its
        // scripts above and below instead of to the side.
        if atom.cls == .op, useLimits(atom, ctx) {
            return (layoutLimits(nucleus, atom, ctx), atom.cls)
        }
        return (layoutScripts(nucleus, atom, ctx, isSymbol: isSymbolNucleus(atom.kind)), atom.cls)
    }

    private func useLimits(_ atom: MathAtom, _ ctx: Context) -> Bool {
        // A horizontal brace labels its span in every style — the label is the
        // whole point of the construct, not an optional decoration.
        if case .horizontalBrace = atom.kind { return true }
        guard ctx.style == .display else { return false }
        if let explicit = atom.limits { return explicit }
        // A bare big operator defaults to limits in display style.
        if case .bigOperator = atom.kind { return true }
        return false
    }

    /// Whether the nucleus is a single character — TeX shifts scripts from the
    /// baseline for those, and from the nucleus's own extents otherwise.
    private func isSymbolNucleus(_ kind: MathAtom.Kind) -> Bool {
        if case let .glyphs(text, _) = kind { return text.count == 1 }
        return false
    }

    private func layoutNucleus(_ kind: MathAtom.Kind, _ ctx: Context) -> MathBox {
        switch kind {
        case let .glyphs(text, style):
            guard let run = measureStyled(text, style, fonts(for: ctx.style)) else { return .empty }
            return MathBox(run)

        case let .bigOperator(glyph, grows):
            return layoutBigOperator(glyph, grows: grows, ctx)

        case let .group(inner):
            return layout(inner, ctx)

        case let .fraction(num, den, bar, left, right):
            return layoutFraction(num, den, bar: bar, left: left, right: right, ctx)

        case let .radical(index, body):
            return layoutRadical(index: index, body: body, ctx)

        case let .delimited(left, body, right):
            return layoutDelimited(left: left, body: body, right: right, ctx)

        case let .sizedDelimiter(delimiter, factor):
            return delimiterBox(delimiter, height: factor * em(ctx.style), ctx)

        case let .accent(mark, stretchy, scale, body):
            return layoutAccent(mark: mark, stretchy: stretchy, scale: scale, body: body, ctx)

        case let .horizontalBrace(over, body):
            return layoutHorizontalBrace(over: over, body, ctx)

        case let .ruled(over, body):
            return layoutRuled(over: over, body, ctx)

        case let .space(width):
            return .space(CGFloat(width) * em(ctx.style))

        case let .matrix(rows, left, right, alignment, hlines):
            return layoutMatrix(rows, left: left, right: right, alignment: alignment,
                                hlines: hlines, ctx)

        case let .styled(style, inner):
            return layout(inner, ctx.with(style: style))

        case let .error(text):
            return measure(text, in: fonts(for: ctx.style).monospace).map(MathBox.init) ?? .empty
        }
    }

    // MARK: - Operators

    private func layoutBigOperator(_ glyph: String, grows: Bool, _ ctx: Context) -> MathBox {
        let fonts = fonts(for: ctx.style)
        let scale = (grows && ctx.style == .display) ? TeXMetrics.displayOperatorScale : 1
        let font = scale == 1 ? fonts.roman
            : CTFontCreateCopyWithAttributes(fonts.roman, fonts.size * scale, nil, nil)
        guard let run = measure(glyph, in: font) else { return .empty }
        var box = MathBox(run)
        // TeX centers a large operator on the math axis rather than the baseline.
        let center = (box.ascent - box.descent) / 2
        box = box.offset(dx: 0, dy: TeXMetrics.axisHeight * em(ctx.style) - center)
        return box
    }

    /// Scripts stacked above and below a big operator.
    private func layoutLimits(_ nucleus: MathBox, _ atom: MathAtom, _ ctx: Context) -> MathBox {
        let unit = em(ctx.style)
        let scriptCtx = ctx.with(style: ctx.scripts)
        let above = atom.sup.map { layout($0, scriptCtx) }
        let below = atom.sub.map { layout($0, scriptCtx.crampedSelf) }
        // The nucleus's italic correction leans the upper limit right and the
        // lower limit left by half of it, as TeX does.
        let slant = nucleus.italicCorrection / 2

        var box = nucleus
        let width = max(nucleus.width, max(above?.width ?? 0, below?.width ?? 0))
        box.width = width
        let nucleusShift = (width - nucleus.width) / 2
        box = MathBox(width: width, ascent: nucleus.ascent, descent: nucleus.descent,
                      items: nucleus.offset(dx: nucleusShift, dy: 0).items)

        if let above {
            // Clear both the minimum gap and the minimum baseline separation.
            let gap = max(TeXMetrics.bigOpSpacing1 * unit,
                          TeXMetrics.bigOpSpacing3 * unit - above.descent)
            let dy = nucleus.ascent + gap + above.descent
            box.overlay(above, dx: (width - above.width) / 2 + slant, dy: dy)
            box.ascent = max(box.ascent, dy + above.ascent + TeXMetrics.bigOpSpacing5 * unit)
        }
        if let below {
            let gap = max(TeXMetrics.bigOpSpacing2 * unit,
                          TeXMetrics.bigOpSpacing4 * unit - below.ascent)
            let dy = -(nucleus.descent + gap + below.ascent)
            box.overlay(below, dx: (width - below.width) / 2 - slant, dy: dy)
            box.descent = max(box.descent, -dy + below.descent + TeXMetrics.bigOpSpacing5 * unit)
        }
        return box
    }

    /// Scripts set to the right of the nucleus (TeXbook rules 18a–18f).
    private func layoutScripts(_ nucleus: MathBox, _ atom: MathAtom, _ ctx: Context, isSymbol: Bool) -> MathBox {
        let unit = em(ctx.style)
        let fonts = fonts(for: ctx.style)
        let xHeight = fonts.xHeight
        let scriptCtx = ctx.with(style: ctx.scripts)
        let sup = atom.sup.map { layout($0, scriptCtx.with(style: ctx.scripts, cramped: ctx.cramped)) }
        let sub = atom.sub.map { layout($0, scriptCtx.crampedSelf) }

        // A single character hangs its scripts off the baseline; a composite
        // nucleus hangs them off its own extents, less a drop.
        var shiftUp: CGFloat = isSymbol ? 0 : nucleus.ascent - TeXMetrics.supDrop * unit
        var shiftDown: CGFloat = isSymbol ? 0 : nucleus.descent + TeXMetrics.subDrop * unit

        var box = nucleus
        let rule = TeXMetrics.defaultRuleThickness * unit

        switch (sup, sub) {
        case let (nil, sub?):
            shiftDown = max(shiftDown, TeXMetrics.sub1 * unit,
                            sub.ascent - 0.8 * xHeight)
            box.overlay(sub, dx: nucleus.width, dy: -shiftDown)
            box.width = nucleus.width + sub.width + scriptSpace(unit)

        case let (sup?, nil):
            let minimum = ctx.cramped ? TeXMetrics.sup3 : (ctx.style == .display ? TeXMetrics.sup1 : TeXMetrics.sup2)
            shiftUp = max(shiftUp, minimum * unit, sup.descent + 0.25 * xHeight)
            box.overlay(sup, dx: nucleus.width + nucleus.italicCorrection, dy: shiftUp)
            box.width = nucleus.width + nucleus.italicCorrection + sup.width + scriptSpace(unit)

        case let (sup?, sub?):
            let minimum = ctx.cramped ? TeXMetrics.sup3 : (ctx.style == .display ? TeXMetrics.sup1 : TeXMetrics.sup2)
            shiftUp = max(shiftUp, minimum * unit, sup.descent + 0.25 * xHeight)
            shiftDown = max(shiftDown, TeXMetrics.sub2 * unit)
            // Keep four rule thicknesses of clear air between the two, and the
            // superscript's bottom at least 1/5 em above the axis.
            let clearance = 4 * rule
            var gap = (shiftUp - sup.descent) - (sub.ascent - shiftDown)
            if gap < clearance {
                shiftDown += clearance - gap
                let bottomOfSup = 0.8 * xHeight - (shiftUp - sup.descent)
                if bottomOfSup > 0 {
                    shiftUp += bottomOfSup
                    shiftDown -= bottomOfSup
                }
                gap = clearance
            }
            let width = max(sup.width + nucleus.italicCorrection, sub.width)
            box.overlay(sup, dx: nucleus.width + nucleus.italicCorrection, dy: shiftUp)
            box.overlay(sub, dx: nucleus.width, dy: -shiftDown)
            box.width = nucleus.width + width + scriptSpace(unit)

        case (nil, nil):
            break
        }
        box.italicCorrection = 0 // the scripts have already consumed it
        return box
    }

    /// The sliver of space TeX leaves after a script so the next atom doesn't
    /// touch it.
    private func scriptSpace(_ unit: CGFloat) -> CGFloat { 0.05 * unit }

    // MARK: - Fractions

    private func layoutFraction(_ numerator: [MathAtom], _ denominator: [MathAtom],
                                bar: Bool, left: String?, right: String?, _ ctx: Context) -> MathBox {
        let unit = em(ctx.style)
        let innerStyle = ctx.style.fractionStyle
        let num = layout(numerator, ctx.with(style: innerStyle, cramped: ctx.cramped))
        // A denominator is always cramped: nothing may rise into the bar.
        let den = layout(denominator, ctx.with(style: innerStyle, cramped: true))
        let rule = bar ? TeXMetrics.defaultRuleThickness * unit : 0
        let axis = TeXMetrics.axisHeight * unit
        let display = ctx.style == .display

        var numShift = display ? TeXMetrics.num1 * unit
            : (bar ? TeXMetrics.num2 : TeXMetrics.num3) * unit
        var denShift = (display ? TeXMetrics.denom1 : TeXMetrics.denom2) * unit

        if bar {
            // Clear air between each part and the bar.
            let clearance = (display ? 3 : 1) * rule
            let aboveBar = (numShift - num.descent) - (axis + rule / 2)
            if aboveBar < clearance { numShift += clearance - aboveBar }
            let belowBar = (axis - rule / 2) - (den.ascent - denShift)
            if belowBar < clearance { denShift += clearance - belowBar }
        } else {
            let clearance = (display ? 7 : 3) * TeXMetrics.defaultRuleThickness * unit
            let gap = (numShift - num.descent) - (den.ascent - denShift)
            if gap < clearance {
                numShift += (clearance - gap) / 2
                denShift += (clearance - gap) / 2
            }
        }

        let bodyWidth = max(num.width, den.width)
        var box = MathBox(width: bodyWidth)
        box.overlay(num, dx: (bodyWidth - num.width) / 2, dy: numShift)
        box.overlay(den, dx: (bodyWidth - den.width) / 2, dy: -denShift)
        if bar {
            box.items.append(.rule(CGRect(x: 0, y: axis - rule / 2, width: bodyWidth, height: rule)))
            box.ascent = max(box.ascent, axis + rule / 2)
            box.descent = max(box.descent, rule / 2 - axis)
        }

        // `\binom`'s parentheses, or the space a bare fraction reserves in their
        // place so `1/2` doesn't butt against its neighbours.
        let height = max(box.ascent - axis, box.descent + axis) * 2
        let leftBox = left.map { delimiterBox($0, height: height, ctx) }
            ?? .space(TeXMetrics.nullDelimiterSpace * unit)
        let rightBox = right.map { delimiterBox($0, height: height, ctx) }
            ?? .space(TeXMetrics.nullDelimiterSpace * unit)
        var wrapped = leftBox
        wrapped.append(box)
        wrapped.append(rightBox)
        return wrapped
    }

    // MARK: - Radicals

    private func layoutRadical(index: [MathAtom]?, body bodyAtoms: [MathAtom], _ ctx: Context) -> MathBox {
        let unit = em(ctx.style)
        // Under the bar there is no room above, so the body is cramped.
        let body = layout(bodyAtoms, ctx.crampedSelf)
        let rule = TeXMetrics.defaultRuleThickness * unit
        // TeX gives display style a full x-height of clearance, less elsewhere.
        let clearance = ctx.style == .display ? rule + fonts(for: ctx.style).xHeight / 4 : rule + rule / 4

        let innerHeight = body.ascent + body.descent
        let surdHeight = innerHeight + clearance + rule
        let surdWidth = 0.5 * unit + 0.08 * surdHeight
        // The body's baseline sits so that its bottom clears the surd's foot.
        let bottom = -body.descent
        let top = bottom + surdHeight

        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: bottom + 0.52 * surdHeight))
        path.addLine(to: CGPoint(x: 0.22 * surdWidth, y: bottom + 0.44 * surdHeight))
        path.addLine(to: CGPoint(x: 0.46 * surdWidth, y: bottom + 0.04 * surdHeight))
        path.addLine(to: CGPoint(x: surdWidth, y: top - rule / 2))
        path.addLine(to: CGPoint(x: surdWidth + body.width, y: top - rule / 2))

        var box = MathBox(width: surdWidth + body.width,
                          ascent: top, descent: body.descent,
                          items: [.strokedPath(path, lineWidth: rule)])
        box.overlay(body, dx: surdWidth, dy: 0)

        guard let index else { return box }
        // `\sqrt[3]{…}`: the index sits in the surd's crook, raised about 60% of
        // its height, and pushes the whole radical right by its own width.
        let indexBox = layout(index, ctx.with(style: .scriptScript, cramped: true))
        let indexRise = bottom + 0.6 * surdHeight
        // The index tucks into the crook, overlapping the surd's foot but never
        // more than a quarter of it — so a wide index always widens the radical.
        let kern = max(0, indexBox.width - 0.25 * surdWidth)
        var result = MathBox(width: kern)
        result.overlay(indexBox, dx: max(0, 0.25 * surdWidth - indexBox.width), dy: indexRise)
        result.append(box)
        return result
    }

    // MARK: - Delimiters

    private func layoutDelimited(left: String, body bodyAtoms: [MathAtom], right: String, _ ctx: Context) -> MathBox {
        let unit = em(ctx.style)
        let body = layout(bodyAtoms, ctx)
        let axis = TeXMetrics.axisHeight * unit
        // The delimiters must span the body's extent measured about the axis.
        let reach = max(body.ascent - axis, body.descent + axis)
        let height = max(reach / TeXMetrics.delimiterFactor,
                         reach - TeXMetrics.delimiterShortfall * unit) * 2

        var box = delimiterBox(left, height: height, ctx)
        box.append(body)
        box.append(delimiterBox(right, height: height, ctx))
        return box
    }

    /// A delimiter grown to the given total height and centered on the axis.
    ///
    /// A font here has no size-variant or extensible-recipe tables, so the glyph
    /// is scaled instead. It scales uniformly at first — how TeX's larger
    /// variants actually differ — and only stretches vertically past the point
    /// where extra width would look wrong.
    private func delimiterBox(_ delimiter: String, height: CGFloat, _ ctx: Context) -> MathBox {
        let unit = em(ctx.style)
        guard !delimiter.isEmpty else { return .space(TeXMetrics.nullDelimiterSpace * unit) }
        let fonts = fonts(for: ctx.style)
        guard let run = measure(delimiter, in: fonts.roman) else {
            return .space(TeXMetrics.nullDelimiterSpace * unit)
        }
        let axis = TeXMetrics.axisHeight * unit
        let natural = run.ascent + run.descent

        // Already tall enough: just center it on the axis.
        guard natural > 0, height > natural else {
            let center = (run.ascent - run.descent) / 2
            return MathBox(run).offset(dx: 0, dy: axis - center)
        }
        let scale = height / natural
        let xScale = min(scale, 1.8)
        var transform = CGAffineTransform(scaleX: xScale, y: scale)
        guard let single = run.singleGlyph,
              let path = CTFontCreatePathForGlyph(single.font, single.glyph, &transform) else {
            let center = (run.ascent - run.descent) / 2
            return MathBox(run).offset(dx: 0, dy: axis - center)
        }
        let bounds = path.boundingBox
        // Re-center the scaled outline on the axis.
        let dy = axis - bounds.midY
        var move = CGAffineTransform(translationX: 0, y: dy)
        let centered = path.copy(using: &move) ?? path
        return MathBox(width: run.width * xScale,
                       ascent: bounds.maxY + dy,
                       descent: -(bounds.minY + dy),
                       items: [.filledPath(centered)])
    }

    // MARK: - Accents and rules

    private func layoutAccent(mark: String, stretchy: Bool, scale: CGFloat,
                              body bodyAtoms: [MathAtom], _ ctx: Context) -> MathBox {
        let unit = em(ctx.style)
        // An accented sub-formula is cramped: the accent takes the space above.
        let body = layout(bodyAtoms, ctx.crampedSelf)
        let fonts = fonts(for: ctx.style)
        let markFont = scale == 1 ? fonts.roman
            : CTFontCreateCopyWithAttributes(fonts.roman, fonts.size * scale, nil, nil)
        guard let run = measure(mark, in: markFont) else { return body }

        var accent = MathBox(run)
        // A widening accent stretches horizontally to cover the body.
        if stretchy, body.width > run.width, run.width > 0 {
            let xScale = body.width / run.width
            var transform = CGAffineTransform(scaleX: xScale, y: 1)
            if let single = run.singleGlyph,
               let path = CTFontCreatePathForGlyph(single.font, single.glyph, &transform) {
                let bounds = path.boundingBox
                accent = MathBox(width: run.width * xScale, ascent: bounds.maxY,
                                 descent: -bounds.minY, items: [.filledPath(path)])
            }
        }
        // Sit the mark's ink on top of the body. A tall letter (an `f`, a `d`)
        // gets the accent nestled slightly onto its ascender rather than
        // floating clear above it — TeX overlaps them for the same reason.
        let target = max(fonts.xHeight, body.ascent - 0.1 * unit)
        var box = body
        // The accent centers over the body, skewed right by half the body's
        // slant so it sits over an italic letter rather than beside it.
        let dx = (body.width - accent.width) / 2 + body.italicCorrection / 2
        box.overlay(accent, dx: dx, dy: target + accent.descent)
        return box
    }

    /// A brace stretched across the body, under it or over it. The label its
    /// script carries is placed by the usual limit machinery.
    private func layoutHorizontalBrace(over: Bool, _ bodyAtoms: [MathAtom], _ ctx: Context) -> MathBox {
        let unit = em(ctx.style)
        let body = layout(bodyAtoms, over ? ctx.crampedSelf : ctx)
        // U+23DE/U+23DF are the horizontal braces; they're drawn narrow and
        // stretched to the span, the same way a widening accent is.
        guard let run = measure(over ? "⏞" : "⏟", in: fonts(for: ctx.style).roman) else { return body }
        var brace = MathBox(run)
        if run.width > 0, body.width > 0, let single = run.singleGlyph {
            var transform = CGAffineTransform(scaleX: body.width / run.width, y: 1)
            if let path = CTFontCreatePathForGlyph(single.font, single.glyph, &transform) {
                let bounds = path.boundingBox
                brace = MathBox(width: body.width, ascent: bounds.maxY, descent: -bounds.minY,
                                items: [.filledPath(path)])
            }
        }
        let gap = 0.1 * unit
        var box = body
        let dx = (body.width - brace.width) / 2
        if over {
            box.overlay(brace, dx: dx, dy: body.ascent + gap + brace.descent)
        } else {
            box.overlay(brace, dx: dx, dy: -(body.descent + gap + brace.ascent))
        }
        return box
    }

    private func layoutRuled(over: Bool, _ bodyAtoms: [MathAtom], _ ctx: Context) -> MathBox {
        let unit = em(ctx.style)
        let body = layout(bodyAtoms, over ? ctx.crampedSelf : ctx)
        let rule = TeXMetrics.defaultRuleThickness * unit
        var box = body
        if over {
            let y = body.ascent + 3 * rule
            box.items.append(.rule(CGRect(x: 0, y: y, width: body.width, height: rule)))
            box.ascent = y + rule
        } else {
            let y = -body.descent - 3 * rule - rule
            box.items.append(.rule(CGRect(x: 0, y: y, width: body.width, height: rule)))
            box.descent = -y
        }
        return box
    }

    // MARK: - Matrices

    private func layoutMatrix(_ rows: [[[MathAtom]]], left: String?, right: String?,
                              alignment: MatrixAlignment, hlines: Set<Int>,
                              _ ctx: Context) -> MathBox {
        let unit = em(ctx.style)
        // Cells of a display-style matrix are set in text style, as TeX does.
        let cellCtx = ctx.with(style: ctx.style == .display ? .text : ctx.style)
        let cells = rows.map { row in row.map { layout($0, cellCtx) } }
        guard !cells.isEmpty else { return .space(TeXMetrics.nullDelimiterSpace * unit) }

        let columnCount = cells.map(\.count).max() ?? 0
        var columnWidths = [CGFloat](repeating: 0, count: columnCount)
        for row in cells {
            for (c, cell) in row.enumerated() { columnWidths[c] = max(columnWidths[c], cell.width) }
        }
        // An `array` brings its own column spec; the rest have a fixed shape.
        var columns: ArrayColumns?
        var isCases = false
        switch alignment {
        case let .array(spec): columns = spec
        case .cases: isCases = true
        default: break
        }
        let columnGap: CGFloat = (isCases ? 1.0 : 0.9) * unit
        let rowGap: CGFloat = 0.35 * unit
        // A rule on an outer edge needs room of its own, or the content would
        // sit flush against it.
        let rulesAt = columns?.rules ?? []
        let leadingPad = rulesAt.contains(0) ? columnGap / 2 : 0
        let trailingPad = rulesAt.contains(columnCount) ? columnGap / 2 : 0
        let totalWidth = leadingPad + columnWidths.reduce(0, +)
            + CGFloat(max(0, columnCount - 1)) * columnGap + trailingPad

        // Stack the rows, then shift the pile so its vertical center is on the axis.
        var stacked = MathBox(width: totalWidth)
        var y: CGFloat = 0
        // The y of each inter-row boundary: index i is above row i, and the last
        // entry is below the final row.
        var boundaries: [CGFloat] = [0]
        for row in cells {
            let ascent = row.map(\.ascent).max() ?? 0
            let descent = row.map(\.descent).max() ?? 0
            y -= ascent
            var x: CGFloat = leadingPad
            for (c, cell) in row.enumerated() {
                let columnWidth = columnWidths[c]
                let dx: CGFloat
                switch alignment {
                case .center: dx = x + (columnWidth - cell.width) / 2
                case .cases: dx = x
                // `aligned` puts the last column of each pair flush right against
                // the relation that follows it.
                case .alternating: dx = c % 2 == 0 ? x + (columnWidth - cell.width) : x
                case let .array(spec):
                    switch spec.alignment(at: c) {
                    case .left: dx = x
                    case .center: dx = x + (columnWidth - cell.width) / 2
                    case .right: dx = x + (columnWidth - cell.width)
                    }
                }
                stacked.overlay(cell, dx: dx, dy: y)
                x += columnWidth + columnGap
            }
            y -= descent + rowGap
            // Midway through the gap this row leaves behind.
            boundaries.append(y + rowGap / 2)
        }
        // The loop leaves a trailing gap below the last row; the pile's real
        // height is the accumulated advance less that gap. Getting this wrong
        // mis-centers the pile on the axis — and the delimiters, which center on
        // the axis directly, don't follow it.
        let pileHeight = -y - rowGap
        // The pile ends where the last row's ink does, not half a gap below it.
        if boundaries.count > 1 { boundaries[boundaries.count - 1] = -pileHeight }

        // Vertical rules from the column spec, spanning the pile. Added straight
        // to `items` rather than overlaid: they reach exactly as far as the rows
        // already do, so they contribute no ink beyond them.
        if !rulesAt.isEmpty {
            let ruleWidth = TeXMetrics.arrayRuleWidth * unit
            for index in rulesAt.sorted() where index >= 0 && index <= columnCount {
                let center: CGFloat
                if index == 0 {
                    center = leadingPad / 2
                } else if index == columnCount {
                    center = totalWidth - trailingPad / 2
                } else {
                    // Midway through the gap between the two columns it divides.
                    center = leadingPad + columnWidths[0..<index].reduce(0, +)
                        + CGFloat(index) * columnGap - columnGap / 2
                }
                // Exactly the pile's extent: the box's own metrics, and what the
                // enclosing delimiters size themselves to.
                stacked.items.append(.rule(CGRect(x: center - ruleWidth / 2, y: -pileHeight,
                                                  width: ruleWidth, height: pileHeight)))
            }
        }

        if !hlines.isEmpty {
            let ruleWidth = TeXMetrics.arrayRuleWidth * unit
            for index in hlines.sorted() where index >= 0 && index < boundaries.count {
                stacked.items.append(.rule(CGRect(x: 0, y: boundaries[index] - ruleWidth / 2,
                                                  width: totalWidth, height: ruleWidth)))
            }
            // A rule is centered on its boundary, so the outermost two put half
            // their width past the pile — real ink the box has to declare.
            if hlines.contains(0) { stacked.ascent = max(stacked.ascent, ruleWidth / 2) }
            if hlines.contains(boundaries.count - 1) {
                stacked.descent = max(stacked.descent, pileHeight + ruleWidth / 2)
            }
        }

        let axis = TeXMetrics.axisHeight * unit
        let shift = pileHeight / 2 + axis
        var body = MathBox(width: totalWidth, ascent: stacked.ascent + shift,
                           descent: stacked.descent - shift,
                           items: stacked.offset(dx: 0, dy: shift).items)
        body.ascent = max(body.ascent, 0)
        body.descent = max(body.descent, 0)

        guard left != nil || right != nil else { return body }
        let reach = max(body.ascent - axis, body.descent + axis)
        let height = reach * 2 + 0.2 * unit
        var box = delimiterBox(left ?? "", height: height, ctx)
        box.append(body)
        box.append(delimiterBox(right ?? "", height: height, ctx))
        return box
    }
}

import Foundation
import CoreText
import CoreGraphics

// Font resolution for the typesetter.
//
// We don't rely on a font's OpenType MATH table — the layout does its own box
// arithmetic and only needs glyph advances and bounding boxes, which every font
// provides. That keeps the renderer working with whatever serif face is
// available rather than requiring a bundled Computer Modern.

/// The faces a formula is drawn with. Resolved once per (family, size) and
/// cached, since building a `CTFont` is not free.
struct MathFontSet {
    let roman: CTFont
    let italic: CTFont
    let bold: CTFont
    let boldItalic: CTFont
    let sansSerif: CTFont
    let monospace: CTFont
    /// The body font of the surrounding text, used by `\text`.
    let body: CTFont
    let size: CGFloat

    /// The face to draw a style in. Italic, bold, and the decorative alphabets
    /// are normally expressed by *code point* rather than by face
    /// (`mathAlphabetCharacter`), so they resolve to the upright math face; the
    /// slanted and bold faces here are the fallback for a font without those
    /// Unicode blocks.
    func font(for style: MathFontStyle) -> CTFont {
        switch style {
        case .italic: return italic
        case .roman: return roman
        case .bold: return bold
        case .boldItalic: return boldItalic
        case .sansSerif: return sansSerif
        case .monospace: return monospace
        case .text: return body
        case .blackboard, .script, .fraktur: return roman
        }
    }

    /// One em at the current size.
    var em: CGFloat { size }
    var xHeight: CGFloat { CTFontGetXHeight(roman) }
}

/// Serif families tried in order for the math faces. The first one installed
/// wins; the last entry is always available.
private let mathFamilyCandidates = [
    "STIX Two Math", "STIXTwoText", "STIX Two Text", "STIXGeneral",
    "Times New Roman", "Times", "Georgia", "Charter",
]

private let fontCacheLock = NSLock()
private nonisolated(unsafe) var fontSetCache: [String: MathFontSet] = [:]

/// The math faces at a given size, alongside the caller's body font.
func mathFontSet(size: CGFloat, body: CTFont) -> MathFontSet {
    let bodyName = CTFontCopyPostScriptName(body) as String
    let key = "\(size)|\(bodyName)"
    fontCacheLock.lock()
    defer { fontCacheLock.unlock() }
    if let cached = fontSetCache[key] { return cached }

    let family = mathFamilyCandidates.first { candidate in
        let probe = CTFontCreateWithName(candidate as CFString, size, nil)
        // CTFontCreateWithName never fails — it substitutes. Compare the family
        // it actually produced to see whether the request was honored.
        return (CTFontCopyFamilyName(probe) as String).compare(
            candidate, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    } ?? "Times"

    let roman = CTFontCreateWithName(family as CFString, size, nil)
    let set = MathFontSet(
        roman: roman,
        italic: variant(of: roman, size: size, traits: .traitItalic),
        bold: variant(of: roman, size: size, traits: .traitBold),
        boldItalic: variant(of: roman, size: size, traits: [.traitBold, .traitItalic]),
        sansSerif: CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil),
        monospace: CTFontCreateWithName("Menlo" as CFString, size, nil),
        body: CTFontCreateCopyWithAttributes(body, size, nil, nil),
        size: size)
    fontSetCache[key] = set
    return set
}

/// A face of the same family with the given symbolic traits, falling back to the
/// original when the family has no such face.
private func variant(of font: CTFont, size: CGFloat, traits: CTFontSymbolicTraits) -> CTFont {
    CTFontCreateCopyWithSymbolicTraits(font, size, nil, traits, traits) ?? font
}

// MARK: - Unicode math alphabets

/// Remap a character into the Unicode math alphabet for `style`, when there is
/// one. Returns nil for styles a face expresses directly (sans-serif,
/// monospace, `\text`).
///
/// Going through Unicode rather than a font's italic/bold faces is what lets a
/// dedicated math font work: STIX Two Math is a single upright face whose
/// slanted and blackboard letters live at their own code points, so asking it
/// for "the italic face" gets you nothing while asking for U+1D465 gets you a
/// proper math italic *x*.
///
/// Each alphabet needs its exceptions listed: `\mathbb R` is U+211D (ℝ), not a
/// slot in the double-struck block — those "holed" letters were encoded earlier,
/// among the Letterlike Symbols, and the block skips them.
func mathAlphabetCharacter(_ c: Character, _ style: MathFontStyle) -> Character? {
    switch style {
    case .italic, .boldItalic, .bold, .blackboard, .script, .fraktur, .sansSerif, .monospace:
        break
    default:
        return nil
    }
    if let greek = greekAlphabetCharacter(c, style) { return greek }

    if let digit = c.wholeNumberValue, c.isASCII, digit >= 0, digit <= 9 {
        // Only some alphabets have their own digits; italic notably does not.
        switch style {
        case .bold: return scalar(0x1D7CE, UInt32(digit))
        case .blackboard: return scalar(0x1D7D8, UInt32(digit))
        case .sansSerif: return scalar(0x1D7E2, UInt32(digit))
        case .monospace: return scalar(0x1D7F6, UInt32(digit))
        default: return nil
        }
    }
    guard let ascii = c.asciiValue else { return nil }
    let isUpper = ascii >= 65 && ascii <= 90
    let isLower = ascii >= 97 && ascii <= 122
    guard isUpper || isLower else { return nil }
    let offset = UInt32(isUpper ? ascii - 65 : ascii - 97)

    switch style {
    case .italic:
        // Italic *h* is U+210E (ℎ, "Planck constant"), not in the block.
        if c == "h" { return "ℎ" }
        return scalar(isUpper ? 0x1D434 : 0x1D44E, offset)
    case .boldItalic:
        return scalar(isUpper ? 0x1D468 : 0x1D482, offset)
    case .bold:
        return scalar(isUpper ? 0x1D400 : 0x1D41A, offset)
    case .blackboard:
        if let exception = blackboardExceptions[c] { return exception }
        return scalar(isUpper ? 0x1D538 : 0x1D552, offset)
    case .script:
        if let exception = scriptExceptions[c] { return exception }
        return scalar(isUpper ? 0x1D49C : 0x1D4B6, offset)
    case .fraktur:
        if let exception = frakturExceptions[c] { return exception }
        return scalar(isUpper ? 0x1D504 : 0x1D51E, offset)
    case .sansSerif:
        // Drawn from the math face's own sans alphabet rather than the system
        // sans, so an `A^{\mathsf{T}}` matches the formula around it.
        return scalar(isUpper ? 0x1D5A0 : 0x1D5BA, offset)
    case .monospace:
        return scalar(isUpper ? 0x1D670 : 0x1D68A, offset)
    default:
        return nil
    }
}

/// Greek letters have their own runs in the math alphabets: contiguous for
/// α–ω, but with the six variant forms (ϵ ϑ ϰ ϕ ϱ ϖ) appended after ω rather
/// than sitting at their Greek-block offsets.
private func greekAlphabetCharacter(_ c: Character, _ style: MathFontStyle) -> Character? {
    let base: UInt32
    switch style {
    case .italic: base = 0x1D6E2       // MATHEMATICAL ITALIC CAPITAL ALPHA
    case .bold: base = 0x1D6A8
    case .boldItalic: base = 0x1D71C
    default: return nil                 // no Greek in the bb/script/fraktur blocks
    }
    guard let value = c.unicodeScalars.first?.value, c.unicodeScalars.count == 1 else { return nil }
    // Capitals Α–Ω then lowercase α–ω, laid out in Greek-block order.
    if value >= 0x391, value <= 0x3A9 { return scalar(base, value - 0x391) }
    if value >= 0x3B1, value <= 0x3C9 { return scalar(base + 0x1A, value - 0x3B1) }
    // The variant symbols, in the block's own order after small omega.
    let variants: [UInt32: UInt32] = [0x3F5: 0, 0x3D1: 1, 0x3F0: 2, 0x3D5: 3, 0x3F1: 4, 0x3D6: 5]
    if let index = variants[value] { return scalar(base + 0x34, index) }
    return nil
}

private func scalar(_ base: UInt32, _ offset: UInt32) -> Character? {
    Unicode.Scalar(base + offset).map(Character.init)
}

private let blackboardExceptions: [Character: Character] = [
    "C": "ℂ", "H": "ℍ", "N": "ℕ", "P": "ℙ", "Q": "ℚ", "R": "ℝ", "Z": "ℤ",
]
private let scriptExceptions: [Character: Character] = [
    "B": "ℬ", "E": "ℰ", "F": "ℱ", "H": "ℋ", "I": "ℐ", "L": "ℒ", "M": "ℳ", "R": "ℛ",
    "e": "ℯ", "g": "ℊ", "o": "ℴ",
]
private let frakturExceptions: [Character: Character] = [
    "C": "ℭ", "H": "ℌ", "I": "ℑ", "R": "ℜ", "Z": "ℨ",
]

/// The face to fall back to when a math-alphabet code point has no glyph. The
/// decorative alphabets have no face equivalent at all, so they settle for the
/// nearest thing that reads as "marked": bold for blackboard, italic for script
/// and fraktur.
func alphabetFallbackStyle(_ style: MathFontStyle) -> MathFontStyle {
    switch style {
    case .blackboard: return .bold
    case .script, .fraktur: return .italic
    default: return style
    }
}

// MARK: - Glyph measurement

/// A measured string: its positioned glyphs and TeX-style ink extents.
struct GlyphRun {
    /// Positioned glyphs, grouped by the font each is drawn with. More than one
    /// group when CoreText substituted a font for part of the string.
    let groups: [(font: CTFont, glyphs: [CGGlyph], positions: [CGPoint])]
    let width: CGFloat
    /// Tight ink extents — TeX's height and depth, not the font's line metrics,
    /// so a bare `x` doesn't reserve room for an ascender it hasn't got.
    let ascent: CGFloat
    let descent: CGFloat
    /// How far the last glyph's ink overhangs its advance, which is what a
    /// superscript after a slanted letter has to clear.
    let italicCorrection: CGFloat
    /// Whether every glyph came from the font that was asked for. False means
    /// CoreText had to substitute — the caller's cue that a Unicode math
    /// alphabet isn't in this face.
    let usedRequestedFont: Bool

    /// The single glyph this run is made of, for the callers that scale one
    /// outline (a stretched delimiter, an accent). Nil if the string measured to
    /// more than one glyph.
    var singleGlyph: (font: CTFont, glyph: CGGlyph)? {
        guard groups.count == 1, groups[0].glyphs.count == 1 else { return nil }
        return (groups[0].font, groups[0].glyphs[0])
    }
}

/// Lay out a string in one font.
///
/// This goes through `CTLine` rather than `CTFontGetGlyphsForCharacters`
/// because the math alphabets live outside the BMP: that API takes UTF-16 units
/// and can't map a surrogate pair, so it reports every astral character as
/// missing. `CTLine` maps them correctly and handles font substitution.
func measure(_ text: String, in font: CTFont) -> GlyphRun? {
    guard !text.isEmpty else { return nil }
    let attributed = NSAttributedString(string: text, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
    ])
    let line = CTLineCreateWithAttributedString(attributed)
    let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    guard let runs = CTLineGetGlyphRuns(line) as? [CTRun], !runs.isEmpty else { return nil }

    let requestedName = CTFontCopyPostScriptName(font) as String
    var groups: [(font: CTFont, glyphs: [CGGlyph], positions: [CGPoint])] = []
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    var lastInkMaxX: CGFloat = 0
    var usedRequestedFont = true

    for run in runs {
        let count = CTRunGetGlyphCount(run)
        guard count > 0 else { continue }
        var glyphs = [CGGlyph](repeating: 0, count: count)
        CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
        var positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
        guard let attributes = CTRunGetAttributes(run) as? [String: Any],
              let fontAttribute = attributes[kCTFontAttributeName as String] else { continue }
        let runFont = fontAttribute as! CTFont // run attributes always carry a font
        if (CTFontCopyPostScriptName(runFont) as String) != requestedName { usedRequestedFont = false }

        var bounds = [CGRect](repeating: .zero, count: count)
        _ = CTFontGetBoundingRectsForGlyphs(runFont, .horizontal, &glyphs, &bounds, count)
        for (box, position) in zip(bounds, positions) where !box.isNull && !box.isEmpty {
            ascent = max(ascent, box.maxY + position.y)
            descent = max(descent, -(box.minY + position.y))
            lastInkMaxX = max(lastInkMaxX, position.x + box.maxX)
        }
        groups.append((font: runFont, glyphs: glyphs, positions: positions))
    }
    guard !groups.isEmpty else { return nil }
    // A string of only zero-ink glyphs (a space) still needs a nominal height.
    if ascent == 0, descent == 0 { ascent = CTFontGetXHeight(font) }
    return GlyphRun(groups: groups, width: width, ascent: ascent, descent: descent,
                    italicCorrection: max(0, lastInkMaxX - width),
                    usedRequestedFont: usedRequestedFont)
}

/// Measure a styled string, applying the Unicode math alphabets and falling back
/// to a real face when this font doesn't have them.
func measureStyled(_ text: String, _ style: MathFontStyle, _ fonts: MathFontSet) -> GlyphRun? {
    let mapped = String(text.map { mathAlphabetCharacter($0, style) ?? $0 })
    guard mapped != text else { return measure(text, in: fonts.font(for: style)) }
    // Math-alphabet code points are all in the upright math face — that's the
    // whole point of them. A substitution means this face doesn't have the
    // block, and plain letters in a slanted or bold *face* approximate it better.
    if let run = measure(mapped, in: fonts.roman), run.usedRequestedFont { return run }
    return measure(text, in: fonts.font(for: alphabetFallbackStyle(style)))
}

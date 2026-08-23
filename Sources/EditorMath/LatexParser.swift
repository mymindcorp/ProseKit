import Foundation

// A LaTeX-math parser producing a TeX "mlist": a flat list of atoms, each with a
// nucleus, an optional subscript and superscript, and a class that drives
// spacing. Structure (fractions, radicals, matrices) is nested inside a nucleus
// rather than being its own atom kind, which is what makes the layout pass a
// simple left-to-right walk.

/// One atom of a math list.
public struct MathAtom {
    var kind: Kind
    var cls: MathClass
    var sub: [MathAtom]?
    var sup: [MathAtom]?
    /// `\limits` / `\nolimits` override for an operator atom; nil = the default
    /// for that operator in the current style.
    var limits: Bool?

    init(_ kind: Kind, _ cls: MathClass, sub: [MathAtom]? = nil, sup: [MathAtom]? = nil, limits: Bool? = nil) {
        self.kind = kind
        self.cls = cls
        self.sub = sub
        self.sup = sup
        self.limits = limits
    }

    indirect enum Kind {
        /// A run of characters drawn in one face.
        case glyphs(String, MathFontStyle)
        /// A large operator drawn from `bigOperators`; `grows` marks the ones
        /// that get a bigger glyph in display style.
        case bigOperator(String, grows: Bool)
        /// A braced group — kept nested so its contents space as a unit.
        case group([MathAtom])
        /// `\frac` and friends. `bar` false is `\atop`/`\binom`'s bare stack;
        /// `left`/`right` are `\binom`'s enclosing parentheses.
        case fraction(num: [MathAtom], den: [MathAtom], bar: Bool, left: String?, right: String?)
        /// `\sqrt[index]{body}`.
        case radical(index: [MathAtom]?, body: [MathAtom])
        /// `\left…\right` — delimiters sized to the body. An empty string is
        /// the null delimiter `.` (reserves nothing, draws nothing).
        case delimited(left: String, body: [MathAtom], right: String)
        /// A `\big`-family delimiter at a fixed multiple of the base height.
        case sizedDelimiter(String, CGFloat)
        /// An accent mark over the body.
        case accent(mark: String, stretchy: Bool, scale: CGFloat, body: [MathAtom])
        /// `\underbrace` / `\overbrace` — a brace stretched under or over the
        /// body, whose script becomes a label below or above it.
        case horizontalBrace(over: Bool, [MathAtom])
        /// `\overline` / `\underline`.
        case ruled(over: Bool, [MathAtom])
        /// Explicit horizontal space, in em.
        case space(Double)
        /// A matrix / cases / aligned environment. `hlines` holds the row
        /// indices `\hline` puts a horizontal rule above, with `rows.count`
        /// meaning a rule below the last row.
        case matrix(rows: [[[MathAtom]]], left: String?, right: String?,
                    alignment: MatrixAlignment, hlines: Set<Int>)
        /// An explicit `\displaystyle` / `\scriptstyle` switch over a group.
        case styled(MathStyle, [MathAtom])
        /// A formula that failed to parse — drawn verbatim in the error color.
        case error(String)
    }
}

/// How an environment's columns line up.
public enum MatrixAlignment: Sendable {
    /// `matrix`, `pmatrix`, … — every column centered.
    case center
    /// `cases` — every column left-aligned, with a wider gap.
    case cases
    /// `aligned` / `align` — columns alternate right, left, right, left…
    case alternating
    /// `array` — per-column alignment and vertical rules, from its column spec.
    case array(ArrayColumns)
}

/// The column layout an `array` environment declares in its spec — the `{lc|r}`
/// argument of `\begin{array}`.
public struct ArrayColumns: Sendable, Equatable {
    public enum Alignment: Sendable { case left, center, right }

    /// One entry per declared column. A body with more columns than the spec
    /// declares centers the extras, as TeX does for an over-wide row.
    public let alignments: [Alignment]
    /// Where vertical rules sit, as column indices: `i` is a rule *before*
    /// column `i`, and `alignments.count` a rule after the last column.
    public let rules: Set<Int>

    /// The alignment of column `index`, defaulting to centered.
    func alignment(at index: Int) -> Alignment {
        index < alignments.count ? alignments[index] : .center
    }

    /// Parse a column spec. Alignment letters and `|` are honored; the sizing
    /// forms (`p{2cm}`, `@{…}`) are accepted and their braced arguments skipped,
    /// so the `c` in `p{2cm}` isn't mistaken for a centered column.
    public init(spec: String) {
        var alignments: [Alignment] = []
        var rules: Set<Int> = []
        let chars = Array(spec)
        var i = 0
        /// The index just past the group starting at `open`.
        func skipBraced(_ open: Int) -> Int {
            var depth = 0, j = open
            while j < chars.count {
                if chars[j] == "{" { depth += 1 }
                if chars[j] == "}" { depth -= 1; if depth == 0 { return j + 1 } }
                j += 1
            }
            return chars.count
        }
        while i < chars.count {
            switch chars[i] {
            case "l": alignments.append(.left); i += 1
            case "c": alignments.append(.center); i += 1
            case "r": alignments.append(.right); i += 1
            case "|": rules.insert(alignments.count); i += 1
            // A fixed-width column takes a braced argument and reads as
            // left-aligned. (`where` would bind to the last pattern only, so the
            // brace check goes in the body.)
            case "p", "m", "b":
                alignments.append(.left)
                i = (i + 1 < chars.count && chars[i + 1] == "{") ? skipBraced(i + 1) : i + 1
            case "{":
                i = skipBraced(i)
            default:
                i += 1
            }
        }
        self.alignments = alignments
        self.rules = rules
    }
}

/// TeX's four typesetting styles. Display is the standalone (block) form;
/// script and script-script are the shrunken forms used inside sub/superscripts.
public enum MathStyle: Int, Sendable, Comparable {
    case display = 0, text = 1, script = 2, scriptScript = 3

    public static func < (a: MathStyle, b: MathStyle) -> Bool { a.rawValue < b.rawValue }

    /// The point-size multiplier for this style (KaTeX's 1 / 0.7 / 0.5).
    var sizeMultiplier: CGFloat {
        switch self {
        case .display, .text: return 1
        case .script: return 0.7
        case .scriptScript: return 0.5
        }
    }
    /// The style a superscript or subscript of this style is set in.
    var scriptStyle: MathStyle {
        switch self {
        case .display, .text: return .script
        case .script, .scriptScript: return .scriptScript
        }
    }
    /// The style a fraction's numerator is set in.
    var fractionStyle: MathStyle {
        switch self {
        case .display: return .text
        case .text: return .script
        case .script, .scriptScript: return .scriptScript
        }
    }
    var isTight: Bool { self >= .script }
}

/// Anything the parser can't make sense of.
struct LatexError: Error {
    let message: String
}

/// Parses LaTeX math into an atom list.
///
/// The parser is deliberately forgiving in one direction only: it accepts
/// shorthands TeX allows (a bare `\frac12`, an unbraced script) but rejects
/// genuinely malformed input so the caller can fall back to showing the source.
struct LatexParser {
    private let chars: [Character]
    private var i = 0
    /// Guards against a `\newcommand`-free but still pathological nesting depth.
    private var depth = 0
    private static let maxDepth = 32
    /// The stop tokens of the innermost `parseList`. A style switch
    /// (`\displaystyle`) applies to the rest of the *current* list, so it has to
    /// stop where that list would — including at a matrix's `&` and `\\`.
    private var activeStops: Set<String> = []

    init(_ source: String) {
        chars = Array(source)
    }

    /// Parse a complete formula.
    static func parse(_ source: String) throws -> [MathAtom] {
        var parser = LatexParser(source)
        let list = try parser.parseList(until: [])
        guard parser.i >= parser.chars.count else {
            throw LatexError(message: "unexpected '\(parser.chars[parser.i])'")
        }
        return list
    }

    // MARK: - Token scanning

    private var atEnd: Bool { i >= chars.count }

    private mutating func skipSpaces() {
        while i < chars.count, chars[i] == " " || chars[i] == "\t" || chars[i] == "\n" { i += 1 }
    }

    /// The next control sequence at `i` (without consuming it), or nil.
    private func peekCommand() -> String? {
        guard i < chars.count, chars[i] == "\\" else { return nil }
        var j = i + 1
        guard j < chars.count else { return nil }
        if !chars[j].isLetter { return String(chars[j]) } // control symbol: \, \{ \\ …
        var name = ""
        while j < chars.count, chars[j].isLetter { name.append(chars[j]); j += 1 }
        return name
    }

    /// Consume the control sequence `peekCommand` reported.
    private mutating func takeCommand() -> String? {
        guard let name = peekCommand() else { return nil }
        i += 1 + name.count
        return name
    }

    // MARK: - List parsing

    /// Parse atoms until one of `stops` (a control-sequence name, `}`, `&`, or
    /// `\\`) is next. The stop token is left unconsumed.
    private mutating func parseList(until stops: Set<String>) throws -> [MathAtom] {
        depth += 1
        let enclosingStops = activeStops
        activeStops = stops
        defer { depth -= 1; activeStops = enclosingStops }
        guard depth < Self.maxDepth else { throw LatexError(message: "nesting too deep") }

        var list: [MathAtom] = []
        while true {
            skipSpaces()
            if atEnd { break }
            if chars[i] == "}" {
                if stops.contains("}") { break }
                throw LatexError(message: "unmatched '}'")
            }
            if chars[i] == "&", stops.contains("&") { break }
            if let command = peekCommand(), stops.contains(command) { break }

            // A script binds to the atom before it; with none, TeX errors — we
            // attach it to an empty ord so `^2` still renders something.
            if chars[i] == "^" || chars[i] == "_" {
                let isSup = chars[i] == "^"
                i += 1
                let script = try parseScriptArgument()
                if list.isEmpty { list.append(MathAtom(.glyphs("", .roman), .ord)) }
                var last = list.removeLast()
                // A second script of the same kind is an error in TeX ("double
                // superscript"); the last one typed wins here.
                if isSup { last.sup = script } else { last.sub = script }
                list.append(last)
                continue
            }
            list.append(contentsOf: try parseAtom())
        }
        return list
    }

    /// The argument of `^` or `_`: a braced group, a command, or one character.
    private mutating func parseScriptArgument() throws -> [MathAtom] {
        skipSpaces()
        guard !atEnd else { throw LatexError(message: "missing script") }
        if chars[i] == "{" { return try parseBracedGroup() }
        // Unbraced, the argument is a single token — `x^12` is `x^1` then `2`.
        return try parseAtom(mergeDigits: false)
    }

    /// A `{…}` group's contents.
    private mutating func parseBracedGroup() throws -> [MathAtom] {
        guard !atEnd, chars[i] == "{" else { throw LatexError(message: "expected '{'") }
        i += 1
        let list = try parseList(until: ["}"])
        guard !atEnd, chars[i] == "}" else { throw LatexError(message: "missing '}'") }
        i += 1
        return list
    }

    /// A required argument: `{…}` or, TeX-style, the single next token.
    private mutating func parseArgument() throws -> [MathAtom] {
        skipSpaces()
        guard !atEnd else { throw LatexError(message: "missing argument") }
        if chars[i] == "{" { return try parseBracedGroup() }
        // As with scripts, an unbraced argument is one token: `\frac12` is a half.
        return try parseAtom(mergeDigits: false)
    }

    /// An optional `[…]` argument, if present.
    private mutating func parseOptionalArgument() throws -> [MathAtom]? {
        skipSpaces()
        guard !atEnd, chars[i] == "[" else { return nil }
        i += 1
        var list: [MathAtom] = []
        while true {
            skipSpaces()
            guard !atEnd else { throw LatexError(message: "missing ']'") }
            if chars[i] == "]" { i += 1; break }
            list.append(contentsOf: try parseAtom())
        }
        return list
    }

    /// The raw text of a `{…}` group, for `\text` and environment names.
    private mutating func parseRawGroup() throws -> String {
        skipSpaces()
        guard !atEnd, chars[i] == "{" else { throw LatexError(message: "expected '{'") }
        i += 1
        var out = ""
        var nesting = 1
        while i < chars.count {
            let c = chars[i]
            if c == "{" { nesting += 1 }
            if c == "}" { nesting -= 1; if nesting == 0 { i += 1; return out } }
            // A backslash escape inside \text passes its character through.
            if c == "\\", i + 1 < chars.count, !chars[i + 1].isLetter {
                out.append(chars[i + 1]); i += 2; continue
            }
            out.append(c)
            i += 1
        }
        throw LatexError(message: "missing '}'")
    }

    /// A delimiter following `\left`, `\right`, or a `\big` command. Returns the
    /// character to draw ("" for the null delimiter `.`).
    private mutating func parseDelimiter() throws -> String {
        skipSpaces()
        guard !atEnd else { throw LatexError(message: "missing delimiter") }
        if chars[i] == "\\" {
            guard let name = peekCommand(),
                  let delim = delimiterCharacters["\\" + name] else {
                throw LatexError(message: "invalid delimiter")
            }
            i += 1 + name.count
            return delim
        }
        let c = String(chars[i])
        guard let delim = delimiterCharacters[c] else { throw LatexError(message: "invalid delimiter '\(c)'") }
        i += 1
        return delim
    }

    // MARK: - Atoms

    /// Parse one nucleus (plus any `\limits` modifier). Returns a list because a
    /// `\text{…}` run or a multi-letter command can expand to several atoms.
    ///
    /// `mergeDigits` gathers a run of digits into one atom so "12" spaces as a
    /// single number. It's off where TeX takes exactly one token — an unbraced
    /// argument or script.
    private mutating func parseAtom(mergeDigits: Bool = true) throws -> [MathAtom] {
        guard !atEnd else { throw LatexError(message: "unexpected end") }
        if chars[i] == "{" {
            let group = try parseBracedGroup()
            return [MathAtom(.group(group), .ord)]
        }
        if chars[i] == "\\" { return try parseCommand() }
        let c = chars[i]
        i += 1
        // A run of digits stays one atom so "12" doesn't get inter-atom space.
        if c.isNumber {
            guard mergeDigits else { return [MathAtom(.glyphs(String(c), .roman), .ord)] }
            var digits = String(c)
            while i < chars.count, chars[i].isNumber || (chars[i] == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                digits.append(chars[i]); i += 1
            }
            return [MathAtom(.glyphs(digits, .roman), .ord)]
        }
        // A prime is a superscript, not a character on the baseline.
        if c == "'" {
            var marks = "′"
            while i < chars.count, chars[i] == "'" { marks += "′"; i += 1 }
            return [MathAtom(.glyphs("", .roman), .ord, sup: [MathAtom(.glyphs(marks, .roman), .ord)])]
        }
        let style: MathFontStyle = c.isLetter ? .italic : .roman
        return [MathAtom(.glyphs(characterSubstitutions[c] ?? String(c), style), characterClass(c))]
    }

    private mutating func parseCommand() throws -> [MathAtom] {
        guard let name = takeCommand() else { throw LatexError(message: "stray backslash") }

        // Structure.
        switch name {
        case "frac", "dfrac", "tfrac", "cfrac":
            let num = try parseArgument(), den = try parseArgument()
            let atom = MathAtom(.fraction(num: num, den: den, bar: true, left: nil, right: nil), .inner)
            if name == "dfrac" || name == "cfrac" { return [MathAtom(.styled(.display, [atom]), .inner)] }
            if name == "tfrac" { return [MathAtom(.styled(.text, [atom]), .inner)] }
            return [atom]
        case "binom", "dbinom", "tbinom":
            let num = try parseArgument(), den = try parseArgument()
            let atom = MathAtom(.fraction(num: num, den: den, bar: false, left: "(", right: ")"), .inner)
            if name == "dbinom" { return [MathAtom(.styled(.display, [atom]), .inner)] }
            if name == "tbinom" { return [MathAtom(.styled(.text, [atom]), .inner)] }
            return [atom]
        case "sqrt":
            let index = try parseOptionalArgument()
            let body = try parseArgument()
            return [MathAtom(.radical(index: index, body: body), .ord)]
        case "left":
            let left = try parseDelimiter()
            let body = try parseList(until: ["right"])
            guard takeCommand() == "right" else { throw LatexError(message: "missing \\right") }
            let right = try parseDelimiter()
            return [MathAtom(.delimited(left: left, body: body, right: right), .inner)]
        case "right":
            throw LatexError(message: "\\right without \\left")
        case "begin":
            return [try parseEnvironment()]
        case "end":
            throw LatexError(message: "\\end without \\begin")
        case "underbrace", "overbrace":
            // Class `.op` so the script stacks as a label rather than sitting
            // beside the brace.
            return [MathAtom(.horizontalBrace(over: name == "overbrace", try parseArgument()), .op)]
        case "bmod":
            // A binary operator set upright: `a \bmod b`.
            return [MathAtom(.glyphs("mod", .roman), .bin)]
        case "pmod", "pod", "mod":
            // TeX's parenthesized modulus: 18mu of space, then `(mod n)`.
            let argument = try parseArgument()
            var out: [MathAtom] = [MathAtom(.space(1), .ord)]
            if name != "mod" { out.append(MathAtom(.glyphs("(", .roman), .open)) }
            if name != "pod" {
                out.append(MathAtom(.glyphs("mod", .roman), .ord))
                out.append(MathAtom(.space(6.0 / 18), .ord))
            }
            out.append(contentsOf: argument)
            if name != "mod" { out.append(MathAtom(.glyphs(")", .roman), .close)) }
            return out
        case "overline":
            return [MathAtom(.ruled(over: true, try parseArgument()), .ord)]
        case "underline":
            return [MathAtom(.ruled(over: false, try parseArgument()), .ord)]
        case "operatorname":
            // `\operatorname*` takes its scripts as limits; plain does not.
            var limits = false
            if !atEnd, chars[i] == "*" { limits = true; i += 1 }
            let text = try parseRawGroup()
            return [MathAtom(.glyphs(text, .roman), .op, limits: limits)]
        case "limits", "nolimits":
            throw LatexError(message: "\\\(name) must follow an operator")
        case "displaystyle", "textstyle", "scriptstyle", "scriptscriptstyle":
            // A style switch applies to the rest of the enclosing group.
            let style: MathStyle = name == "displaystyle" ? .display
                : name == "textstyle" ? .text
                : name == "scriptstyle" ? .script : .scriptScript
            let rest = try parseList(until: activeStops)
            return [MathAtom(.styled(style, rest), .ord)]
        default:
            break
        }

        // Font switches.
        if let style = fontCommands[name] {
            let body = try parseArgument()
            return [MathAtom(.group(restyle(body, style)), .ord)]
        }
        if let style = textCommands[name] {
            let text = try parseRawGroup()
            return [MathAtom(.glyphs(text, style), .ord)]
        }
        // Accents.
        if let accent = mathAccents[name] {
            let body = try parseArgument()
            return [MathAtom(.accent(mark: accent.mark, stretchy: accent.stretchy,
                                     scale: accent.scale, body: body), .ord)]
        }
        // Explicit spaces.
        if let em = mathSpaces[name] {
            return [MathAtom(.space(em), .ord)]
        }
        // `\big(` and friends.
        if let factor = delimiterSizes[name] {
            let delim = try parseDelimiter()
            return [MathAtom(.sizedDelimiter(delim, factor), delimiterSizeClass(name))]
        }
        // Big operators, then named functions — both may carry a limits modifier.
        if let glyph = bigOperators[name] {
            var atom = MathAtom(.bigOperator(glyph, grows: true), .op)
            atom.limits = takeLimitsModifier() ?? (integralOperators.contains(name) ? false : nil)
            return [atom]
        }
        if let defaultLimits = namedFunctions[name] {
            var atom = MathAtom(.glyphs(name, .roman), .op)
            atom.limits = takeLimitsModifier() ?? defaultLimits
            return [atom]
        }
        // Plain symbols.
        if let symbol = mathSymbols[name] {
            return [MathAtom(.glyphs(symbol.text, symbol.upright ? .roman : .italic), symbol.cls)]
        }
        throw LatexError(message: "unknown command \\\(name)")
    }

    /// Consume a trailing `\limits` / `\nolimits`, if any.
    private mutating func takeLimitsModifier() -> Bool? {
        let save = i
        skipSpaces()
        switch peekCommand() {
        case "limits": _ = takeCommand(); return true
        case "nolimits": _ = takeCommand(); return false
        default: i = save; return nil
        }
    }

    /// Apply a font switch through a parsed sub-list. Nested switches (a
    /// `\mathrm` inside a `\mathbf`) keep their own face.
    private func restyle(_ list: [MathAtom], _ style: MathFontStyle) -> [MathAtom] {
        list.map { atom in
            var atom = atom
            switch atom.kind {
            case let .glyphs(text, _):
                atom.kind = .glyphs(text, style)
            case let .group(inner):
                atom.kind = .group(restyle(inner, style))
            default:
                break
            }
            if let sub = atom.sub { atom.sub = restyle(sub, style) }
            if let sup = atom.sup { atom.sup = restyle(sup, style) }
            return atom
        }
    }

    // MARK: - Environments

    private static let environmentDelimiters: [String: (String, String)] = [
        "matrix": ("", ""), "pmatrix": ("(", ")"), "bmatrix": ("[", "]"),
        "Bmatrix": ("{", "}"), "vmatrix": ("|", "|"), "Vmatrix": ("‖", "‖"),
        "cases": ("{", ""), "array": ("", ""), "aligned": ("", ""),
        "align": ("", ""), "aligned*": ("", ""), "smallmatrix": ("", ""),
    ]

    private mutating func parseEnvironment() throws -> MathAtom {
        let name = try parseRawGroup()
        guard let (left, right) = Self.environmentDelimiters[name] else {
            throw LatexError(message: "unknown environment '\(name)'")
        }
        var alignment: MatrixAlignment = name == "cases" ? .cases
            : (name.hasPrefix("align") ? .alternating : .center)
        // `array` declares its columns — alignments and vertical rules.
        if name == "array" {
            alignment = .array(ArrayColumns(spec: (try? parseRawGroup()) ?? ""))
        }

        var rows: [[[MathAtom]]] = []
        var row: [[MathAtom]] = []
        var hlines: Set<Int> = []
        while true {
            // `\hline` sits between rows, so it's read at the start of the row
            // it precedes — several in a row are legal and collapse to one.
            if row.isEmpty {
                skipSpaces()
                while peekCommand() == "hline" { _ = takeCommand(); hlines.insert(rows.count); skipSpaces() }
            }
            let cell = try parseList(until: ["&", "\\", "end", "}"])
            row.append(cell)
            skipSpaces()
            if !atEnd, chars[i] == "&" { i += 1; continue }
            if peekCommand() == "\\" {
                _ = takeCommand()
                rows.append(row); row = []
                // A trailing `\\` before `\end` doesn't start an empty row.
                skipSpaces()
                if peekCommand() == "end" { break }
                continue
            }
            if peekCommand() == "end" { rows.append(row); row = []; break }
            throw LatexError(message: "unterminated environment '\(name)'")
        }
        guard takeCommand() == "end" else { throw LatexError(message: "missing \\end") }
        let closing = try parseRawGroup()
        guard closing == name else { throw LatexError(message: "\\end{\(closing)} closes \\begin{\(name)}") }

        // A trailing `\hline` after the last `\\` opened an empty row; drop it
        // and keep the rule, which belongs below the final row.
        if let last = rows.last, last.count == 1, last[0].isEmpty, hlines.contains(rows.count - 1) {
            hlines.remove(rows.count - 1)
            rows.removeLast()
            hlines.insert(rows.count)
        }
        return MathAtom(.matrix(rows: rows, left: left.isEmpty ? nil : left,
                                right: right.isEmpty ? nil : right,
                                alignment: alignment, hlines: hlines),
                        .inner)
    }
}

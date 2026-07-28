import Foundation

// The LaTeX command tables the parser resolves against. Coverage is the subset a
// note-taking editor needs — everything KaTeX supports for Greek, relations,
// operators, arrows, set theory, delimiters, accents, and the named functions —
// rather than all of TeX.

/// A TeX atom class. Which class an atom has decides the space around it (see
/// `interAtomSpacing`) far more than what it looks like.
public enum MathClass: Sendable, Hashable {
    /// An ordinary symbol: a variable, a digit, `\infty`.
    case ord
    /// A large operator: `\sum`, `\int`, `\lim`, `\sin`.
    case op
    /// A binary operator: `+`, `\times`.
    case bin
    /// A relation: `=`, `\leq`, `\to`.
    case rel
    /// An opening delimiter: `(`, `\{`.
    case open
    /// A closing delimiter: `)`, `\}`.
    case close
    /// Punctuation: `,`, `;`.
    case punct
    /// A sub-formula treated as a unit: `\left…\right`, a fraction.
    case inner
}

/// How a run of characters is drawn: which face, and whether the letters are
/// remapped into a Unicode math alphabet.
public enum MathFontStyle: Sendable, Hashable {
    /// Variables — the TeX default for single Latin/Greek letters.
    case italic
    /// Upright: digits, punctuation, `\mathrm`, function names.
    case roman
    case bold
    case boldItalic
    /// `\mathbb` — double-struck.
    case blackboard
    /// `\mathcal` / `\mathscr`.
    case script
    /// `\mathfrak`.
    case fraktur
    /// `\mathsf`.
    case sansSerif
    /// `\mathtt`.
    case monospace
    /// `\text` — the surrounding body font, not a math face.
    case text
}

/// A symbol command: what it draws and how it spaces.
struct SymbolEntry {
    let text: String
    let cls: MathClass
    /// When set, the symbol is drawn upright even in an italic context (true of
    /// every non-letter symbol, and of Greek capitals by TeX convention).
    let upright: Bool
    init(_ text: String, _ cls: MathClass, upright: Bool = true) {
        self.text = text
        self.cls = cls
        self.upright = upright
    }
}

/// Command name (without the backslash) → the symbol it stands for.
let mathSymbols: [String: SymbolEntry] = {
    var t: [String: SymbolEntry] = [:]

    // Lowercase Greek — variables, so they follow the italic math face.
    let lowerGreek: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ϵ",
        "varepsilon": "ε", "zeta": "ζ", "eta": "η", "theta": "θ", "vartheta": "ϑ",
        "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ",
        "omicron": "ο", "pi": "π", "varpi": "ϖ", "rho": "ρ", "varrho": "ϱ",
        "sigma": "σ", "varsigma": "ς", "tau": "τ", "upsilon": "υ", "phi": "ϕ",
        "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
    ]
    for (k, v) in lowerGreek { t[k] = SymbolEntry(v, .ord, upright: false) }
    // Uppercase Greek — upright in TeX's default (non-ISO) style.
    let upperGreek: [String: String] = [
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ",
        "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
    ]
    for (k, v) in upperGreek { t[k] = SymbolEntry(v, .ord) }

    // Ordinary symbols.
    let ord: [String: String] = [
        "infty": "∞", "partial": "∂", "nabla": "∇", "emptyset": "∅", "varnothing": "∅",
        "forall": "∀", "exists": "∃", "nexists": "∄", "neg": "¬", "lnot": "¬",
        "top": "⊤", "bot": "⊥", "angle": "∠", "measuredangle": "∡", "triangle": "△",
        "square": "□", "blacksquare": "■", "diamond": "⋄", "Diamond": "◇",
        "aleph": "ℵ", "beth": "ℶ", "hbar": "ℏ", "hslash": "ℏ", "ell": "ℓ",
        "Re": "ℜ", "Im": "ℑ", "wp": "℘", "imath": "ı", "jmath": "ȷ",
        "prime": "′", "dprime": "″", "degree": "°", "surd": "√",
        "flat": "♭", "natural": "♮", "sharp": "♯", "clubsuit": "♣", "diamondsuit": "♢",
        "heartsuit": "♡", "spadesuit": "♠", "checkmark": "✓", "dag": "†",
        "ddag": "‡", "ddagger": "‡", "S": "§", "P": "¶", "pounds": "£",
        "ldots": "…", "dots": "…", "cdots": "⋯", "vdots": "⋮", "ddots": "⋱",
        "mho": "℧", "circledR": "®", "maltese": "✠", "backslash": "\\",
    ]
    for (k, v) in ord { t[k] = SymbolEntry(v, .ord) }

    // Binary operators.
    let bin: [String: String] = [
        "pm": "±", "mp": "∓", "times": "×", "div": "÷", "cdot": "⋅", "ast": "∗",
        "star": "⋆", "circ": "∘", "bullet": "∙", "oplus": "⊕", "ominus": "⊖",
        "otimes": "⊗", "oslash": "⊘", "odot": "⊙", "cup": "∪", "cap": "∩",
        "uplus": "⊎", "sqcup": "⊔", "sqcap": "⊓", "vee": "∨", "lor": "∨",
        "wedge": "∧", "land": "∧", "setminus": "∖", "wr": "≀", "amalg": "⨿",
        "triangleleft": "◃", "triangleright": "▹", "bigtriangleup": "△",
        "bigtriangledown": "▽", "dagger": "†", "bigcirc": "◯", "boxplus": "⊞",
        "boxminus": "⊟", "boxtimes": "⊠", "boxdot": "⊡",
    ]
    for (k, v) in bin { t[k] = SymbolEntry(v, .bin) }

    // Relations.
    let rel: [String: String] = [
        "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "neq": "≠", "ne": "≠",
        "ll": "≪", "gg": "≫", "leqslant": "⩽", "geqslant": "⩾",
        "equiv": "≡", "sim": "∼", "simeq": "≃", "approx": "≈", "approxeq": "≊",
        "cong": "≅", "propto": "∝", "asymp": "≍", "doteq": "≐", "coloneqq": "≔",
        "in": "∈", "notin": "∉", "ni": "∋", "owns": "∋",
        "subset": "⊂", "supset": "⊃", "subseteq": "⊆", "supseteq": "⊇",
        "subsetneq": "⊊", "supsetneq": "⊋", "nsubseteq": "⊈", "nsupseteq": "⊉",
        "sqsubseteq": "⊑", "sqsupseteq": "⊒", "perp": "⊥", "parallel": "∥",
        "mid": "∣", "nmid": "∤", "vdash": "⊢", "dashv": "⊣", "models": "⊨",
        "prec": "≺", "succ": "≻", "preceq": "⪯", "succeq": "⪰",
        "ltimes": "⋉", "rtimes": "⋊", "bowtie": "⋈", "smile": "⌣", "frown": "⌢",
        "therefore": "∴", "because": "∵", "colon": ":",
        // Arrows are relations in TeX.
        "to": "→", "rightarrow": "→", "gets": "←", "leftarrow": "←",
        "leftrightarrow": "↔", "Rightarrow": "⇒", "Leftarrow": "⇐",
        "Leftrightarrow": "⇔", "iff": "⟺", "implies": "⟹", "impliedby": "⟸",
        "mapsto": "↦", "longmapsto": "⟼", "longrightarrow": "⟶", "longleftarrow": "⟵",
        "longleftrightarrow": "⟷", "Longrightarrow": "⟹", "Longleftarrow": "⟸",
        "Longleftrightarrow": "⟺", "uparrow": "↑", "downarrow": "↓",
        "updownarrow": "↕", "Uparrow": "⇑", "Downarrow": "⇓", "Updownarrow": "⇕",
        "nearrow": "↗", "searrow": "↘", "swarrow": "↙", "nwarrow": "↖",
        "hookrightarrow": "↪", "hookleftarrow": "↩", "rightharpoonup": "⇀",
        "rightharpoondown": "⇁", "leftharpoonup": "↼", "leftharpoondown": "↽",
        "rightleftharpoons": "⇌", "leadsto": "⇝", "nleftarrow": "↚", "nrightarrow": "↛",
    ]
    for (k, v) in rel { t[k] = SymbolEntry(v, .rel) }

    // Delimiters usable bare (and as `\left`/`\right` arguments).
    let open: [String: String] = [
        "lbrace": "{", "lbrack": "[", "langle": "⟨", "lceil": "⌈", "lfloor": "⌊",
        "lvert": "|", "lVert": "‖",
    ]
    for (k, v) in open { t[k] = SymbolEntry(v, .open) }
    let close: [String: String] = [
        "rbrace": "}", "rbrack": "]", "rangle": "⟩", "rceil": "⌉", "rfloor": "⌋",
        "rvert": "|", "rVert": "‖",
    ]
    for (k, v) in close { t[k] = SymbolEntry(v, .close) }
    // Escaped literals.
    t["{"] = SymbolEntry("{", .open)
    t["}"] = SymbolEntry("}", .close)
    t["|"] = SymbolEntry("‖", .ord)
    t["vert"] = SymbolEntry("|", .ord)
    t["Vert"] = SymbolEntry("‖", .ord)
    for ch in ["$", "%", "&", "#", "_"] { t[ch] = SymbolEntry(ch, .ord) }

    return t
}()

/// Big operators — `\sum`-like symbols that grow in display style and take their
/// scripts as limits above/below.
let bigOperators: [String: String] = [
    "sum": "∑", "prod": "∏", "coprod": "∐", "int": "∫", "iint": "∬",
    "iiint": "∭", "oint": "∮", "oiint": "∯", "bigcup": "⋃", "bigcap": "⋂",
    "bigvee": "⋁", "bigwedge": "⋀", "bigoplus": "⨁", "bigotimes": "⨂",
    "bigodot": "⨀", "biguplus": "⨄", "bigsqcup": "⨆",
]

/// The integral family draws its scripts to the side even in display style.
let integralOperators: Set<String> = ["int", "iint", "iiint", "oint", "oiint"]

/// Named functions — set upright, and spaced as operators. The value says
/// whether the function takes its scripts as limits above/below in display style
/// (true of `\lim` and friends, false of `\sin`).
let namedFunctions: [String: Bool] = [
    "sin": false, "cos": false, "tan": false, "sec": false, "csc": false, "cot": false,
    "arcsin": false, "arccos": false, "arctan": false, "sinh": false, "cosh": false,
    "tanh": false, "coth": false, "log": false, "ln": false, "lg": false, "exp": false,
    "arg": false, "deg": false, "dim": false, "hom": false, "ker": false, "Pr": false,
    "lim": true, "limsup": true, "liminf": true, "max": true, "min": true,
    "sup": true, "inf": true, "det": true, "gcd": true, "injlim": true, "projlim": true,
]

/// Accent command → the mark drawn over the body. Widening accents (`\widehat`)
/// stretch to the body's width; the rest keep their natural width. `scale`
/// shrinks marks whose spacing form is drawn too large for an accent (`\vec`
/// borrows a full-size arrow).
///
/// The marks are the *spacing* modifier letters (U+02xx), not combining marks:
/// a combining character drawn on its own has no advance and no reliable
/// position, while these measure and draw like any other glyph.
let mathAccents: [String: (mark: String, stretchy: Bool, scale: CGFloat)] = [
    "hat": ("ˆ", false, 1), "widehat": ("ˆ", true, 1),
    "tilde": ("˜", false, 1), "widetilde": ("˜", true, 1),
    "bar": ("¯", false, 1),
    "vec": ("→", false, 0.6),
    "dot": ("˙", false, 1), "ddot": ("¨", false, 1),
    "acute": ("´", false, 1), "grave": ("ˋ", false, 1), "check": ("ˇ", false, 1),
    "breve": ("˘", false, 1), "mathring": ("˚", false, 1),
]

/// Explicit spacing commands, in em. `\!` is a negative thin space.
let mathSpaces: [String: Double] = [
    ",": 3.0 / 18, ":": 4.0 / 18, ";": 5.0 / 18, "!": -3.0 / 18,
    " ": 1.0 / 3, "quad": 1, "qquad": 2, "thinspace": 3.0 / 18,
    "medspace": 4.0 / 18, "thickspace": 5.0 / 18, "negthinspace": -3.0 / 18,
    "enspace": 0.5, "nobreakspace": 1.0 / 3, "space": 1.0 / 3,
]

/// `\mathbb`-style font switches.
let fontCommands: [String: MathFontStyle] = [
    "mathrm": .roman, "mathbf": .bold, "mathit": .italic, "mathbb": .blackboard,
    "mathcal": .script, "mathscr": .script, "mathfrak": .fraktur,
    "mathsf": .sansSerif, "mathtt": .monospace, "mathnormal": .italic,
    "boldsymbol": .boldItalic, "bm": .boldItalic,
]

/// `\text`-style switches — the body font rather than a math face.
let textCommands: [String: MathFontStyle] = [
    "text": .text, "textrm": .text, "textnormal": .text,
    "textbf": .bold, "textit": .italic, "texttt": .monospace, "textsf": .sansSerif,
    "mbox": .text, "hbox": .text,
]

/// `\big`-family sizes, as a multiple of the base delimiter height.
let delimiterSizes: [String: CGFloat] = [
    "big": 1.2, "Big": 1.8, "bigg": 2.4, "Bigg": 3.0,
    "bigl": 1.2, "Bigl": 1.8, "biggl": 2.4, "Biggl": 3.0,
    "bigr": 1.2, "Bigr": 1.8, "biggr": 2.4, "Biggr": 3.0,
    "bigm": 1.2, "Bigm": 1.8, "biggm": 2.4, "Biggm": 3.0,
]

/// The class a `\big`-family command gives its delimiter (`\bigl` opens, `\bigr`
/// closes, plain `\big` is ordinary).
func delimiterSizeClass(_ command: String) -> MathClass {
    if command.hasSuffix("l") { return .open }
    if command.hasSuffix("r") { return .close }
    return .ord
}

/// Delimiters `\left`/`\right`/`\big` accept, mapped to the character to draw.
/// `.` is the "null" delimiter — it takes space but draws nothing.
let delimiterCharacters: [String: String] = [
    "(": "(", ")": ")", "[": "[", "]": "]", "|": "|", "/": "/", ".": "",
    "\\{": "{", "\\}": "}", "\\lbrace": "{", "\\rbrace": "}",
    "\\langle": "⟨", "\\rangle": "⟩", "\\lceil": "⌈", "\\rceil": "⌉",
    "\\lfloor": "⌊", "\\rfloor": "⌋", "\\vert": "|", "\\Vert": "‖",
    "\\lvert": "|", "\\rvert": "|", "\\lVert": "‖", "\\rVert": "‖",
    "\\|": "‖", "\\backslash": "\\", "\\uparrow": "↑", "\\downarrow": "↓",
    "\\Uparrow": "⇑", "\\Downarrow": "⇓", "\\updownarrow": "↕",
]

/// The class of a single non-command character.
func characterClass(_ c: Character) -> MathClass {
    switch c {
    case "+", "-", "−", "*", "±", "∓", "×", "÷", "·": return .bin
    // `:` is a relation in TeX (`f : A \to B`); `\colon` is the punctuation form.
    case "=", "<", ">", "≠", "≤", "≥", "≡", "∼", "≈", "→", "←", "↔", "∈", "∉", ":": return .rel
    case "(", "[": return .open
    case ")", "]": return .close
    case ",", ";": return .punct
    case "!", "?": return .ord
    default: return .ord
    }
}

/// Characters LaTeX renders as something other than what was typed.
let characterSubstitutions: [Character: String] = [
    "-": "−",  // U+2212 MINUS SIGN, not a hyphen
    "'": "′",  // prime
]

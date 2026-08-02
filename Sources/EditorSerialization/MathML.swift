import Foundation
import DocumentModel

// Turning pasted MathML into a math node.
//
// The editor stores formulas as LaTeX, so MathML has to become LaTeX on the way
// in. Usually that needs no conversion at all: MathJax, KaTeX and Pandoc all
// carry the original TeX inside the MathML as an `<annotation>`, and Wikipedia
// puts it in the `alttext` attribute. Taking it from there is exact, where any
// conversion would be an approximation.
//
// Markup with no annotation — hand-written, or from a word processor — is
// converted from presentation MathML instead. That's a translation between two
// notations with different ideas of structure, so it aims for a faithful
// reading rather than a perfect one, and deliberately emits only commands the
// math renderer understands: LaTeX it can't parse would render as an error,
// which is worse than a slightly plainer formula.

enum MathML {
    /// The LaTeX for a `<math>` element spanning `start...end` in `tokens`, and
    /// whether it asked to be displayed as a block. Nil when nothing usable
    /// could be read out of it.
    static func latex(_ tokens: HTMLParser.Tokens, from start: Int, to end: Int)
        -> (latex: String, display: Bool)? {
        guard case let .open(_, attributes, _) = tokens[start] else { return nil }
        // `display="block"` is MathML's own way of saying this is display maths;
        // older markup uses `mode="display"`.
        let display = attributes["display"] == "block" || attributes["mode"] == "display"

        // 1. A TeX annotation is the original source, so it beats converting.
        if let annotated = annotation(tokens, from: start, to: end) {
            return (annotated, display)
        }
        // 2. Wikipedia carries it in `alttext`, wrapped in a display directive.
        if let alt = attributes["alttext"].map(unwrapDisplayStyle), !alt.isEmpty {
            return (alt, display)
        }
        // 3. Otherwise translate the presentation markup.
        let converted = joined(convertChildren(tokens, from: start + 1, to: end))
        let trimmed = converted.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : (trimmed, display)
    }

    // MARK: - Reading the original TeX

    /// The contents of a `<annotation encoding="application/x-tex">`, if present.
    private static func annotation(_ tokens: HTMLParser.Tokens, from start: Int, to end: Int) -> String? {
        var i = start + 1
        while i < end {
            if case let .open(tag, attributes, selfClosing) = tokens[i], tag == "annotation", !selfClosing {
                let encoding = (attributes["encoding"] ?? "").lowercased()
                let close = HTMLParser.matchingClose(tokens, i, tag)
                if encoding.contains("x-tex") || encoding.contains("x-latex") || encoding.contains("tex") {
                    let text = HTMLParser.innerText(tokens, i + 1, min(close, end))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { return unwrapDisplayStyle(text) }
                }
                i = min(close, end) + 1
                continue
            }
            i += 1
        }
        return nil
    }

    /// Strip the `{\displaystyle …}` wrapper Wikipedia's `alttext` uses, since
    /// the node already records whether it's display maths.
    private static func unwrapDisplayStyle(_ source: String) -> String {
        var text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["{\\displaystyle ", "{\\textstyle ", "{\\displaystyle", "{\\textstyle"] {
            guard text.hasPrefix(prefix), text.hasSuffix("}") else { continue }
            text = String(text.dropFirst(prefix.count).dropLast())
            break
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Converting presentation MathML

    /// Convert every child element between `from` and `to`, in order.
    private static func convertChildren(_ tokens: HTMLParser.Tokens, from: Int, to: Int) -> [String] {
        var out: [String] = []
        var i = from
        while i < to {
            switch tokens[i] {
            case let .text(raw):
                let text = HTMLParser.decodeEntities(raw).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { out.append(escapeText(text)) }
                i += 1
            case let .open(tag, attributes, selfClosing):
                if selfClosing {
                    out.append(convertLeaf(tag, attributes, ""))
                    i += 1
                    continue
                }
                let close = min(HTMLParser.matchingClose(tokens, i, tag), to)
                out.append(convert(tag, attributes, tokens, from: i, to: close))
                i = close + 1
            case .close:
                i += 1
            }
        }
        return out
    }

    /// Convert one element, given the span of its children.
    private static func convert(_ tag: String, _ attributes: [String: String],
                                _ tokens: HTMLParser.Tokens, from: Int, to: Int) -> String {
        // Elements whose text is their whole meaning.
        if ["mi", "mn", "mo", "mtext", "ms"].contains(tag) {
            return convertLeaf(tag, attributes, HTMLParser.innerText(tokens, from + 1, to))
        }
        let children = convertChildren(tokens, from: from + 1, to: to)

        switch tag {
        // Transparent wrappers: their children are the content.
        case "math", "mrow", "mstyle", "mpadded", "semantics", "menclose", "merror", "mscarries":
            return joined(children)
        // Not visual output.
        case "annotation", "annotation-xml", "mphantom", "none":
            return ""
        case "mfrac":
            let (numerator, denominator) = pair(children)
            // `linethickness="0"` is MathML's bare stack — a binomial, usually.
            if let thickness = attributes["linethickness"], thickness == "0" || thickness == "0pt" {
                return "\\binom{\(numerator)}{\(denominator)}"
            }
            return "\\frac{\(numerator)}{\(denominator)}"
        case "msqrt":
            return "\\sqrt{\(joined(children))}"
        case "mroot":
            let (base, index) = pair(children)
            return "\\sqrt[\(index)]{\(base)}"
        case "msup":
            let (base, script) = pair(children)
            return "\(braced(base))^{\(script)}"
        case "msub":
            let (base, script) = pair(children)
            return "\(braced(base))_{\(script)}"
        case "msubsup":
            let base = children.first ?? ""
            return "\(braced(base))_{\(children.count > 1 ? children[1] : "")}^{\(children.count > 2 ? children[2] : "")}"
        // Under/over become sub/superscripts. LaTeX's own `\underset` isn't
        // something the renderer parses, and for the usual case — limits on a
        // big operator — scripts are exactly right anyway.
        case "munder":
            let (base, script) = pair(children)
            return "\(braced(base))_{\(script)}"
        case "mover":
            let (base, script) = pair(children)
            if let accent = accentCommand(script) { return "\\\(accent){\(base)}" }
            return "\(braced(base))^{\(script)}"
        case "munderover":
            let base = children.first ?? ""
            return "\(braced(base))_{\(children.count > 1 ? children[1] : "")}^{\(children.count > 2 ? children[2] : "")}"
        case "mfenced":
            // Deprecated, but still widely emitted.
            let open = attributes["open"] ?? "("
            let close = attributes["close"] ?? ")"
            let separator = attributes["separators"] ?? ","
            let body = children.joined(separator: separator.isEmpty ? "" : escapeText(separator))
            return "\\left\(delimiter(open))\(body)\\right\(delimiter(close))"
        case "mtable":
            return "\\begin{matrix}\(children.joined(separator: " \\\\ "))\\end{matrix}"
        case "mtr", "mlabeledtr":
            return children.joined(separator: " & ")
        case "mtd":
            return joined(children)
        case "mspace":
            return "\\;"
        default:
            // An element we don't know: keep whatever was inside it rather than
            // dropping content on the floor.
            return joined(children)
        }
    }

    /// A leaf element whose text content is its value.
    private static func convertLeaf(_ tag: String, _ attributes: [String: String], _ rawText: String) -> String {
        let text = HTMLParser.decodeEntities(rawText).trimmingCharacters(in: .whitespaces)
        switch tag {
        case "mspace":
            return "\\;"
        case "mtext":
            return text.isEmpty ? "" : "\\text{\(text)}"
        case "mo":
            return operatorLatex(text)
        case "mi":
            if text.isEmpty { return "" }
            if let command = symbolCommand(text) { return command }
            // A multi-letter identifier is a function or a name, not a product
            // of variables — `sin`, not `s·i·n`.
            if text.count > 1 {
                let name = text.lowercased()
                return functionNames.contains(name) ? "\\\(name)" : "\\mathrm{\(escapeText(text))}"
            }
            // `mathvariant="normal"` is MathML's way of saying "upright".
            if attributes["mathvariant"] == "normal" { return "\\mathrm{\(escapeText(text))}" }
            return escapeText(text)
        default:
            return symbolCommand(text) ?? escapeText(text)
        }
    }

    /// Join sibling pieces, keeping a trailing command clear of a following
    /// letter: `\sin` and `x` are `\sin x`, because `\sinx` is a command
    /// nobody has heard of. MathML has no such ambiguity — its structure is in
    /// the elements — so this only shows up on the way out.
    private static func joined(_ pieces: [String]) -> String {
        var out = ""
        for piece in pieces where !piece.isEmpty {
            if piece.first?.isLetter == true, endsWithCommand(out) { out += " " }
            out += piece
        }
        return out
    }

    /// Whether `text` ends in a control word (a backslash and letters).
    private static func endsWithCommand(_ text: String) -> Bool {
        var sawLetter = false
        for character in text.reversed() {
            if character.isLetter { sawLetter = true; continue }
            return character == "\\" && sawLetter
        }
        return false
    }

    /// The first two children, padded — MathML's two-argument elements.
    private static func pair(_ children: [String]) -> (String, String) {
        (children.first ?? "", children.count > 1 ? children[1] : "")
    }

    /// Wrap a base in braces when it isn't already a single token, so
    /// `x+1` raised to a power doesn't become `x+1^{2}`.
    private static func braced(_ base: String) -> String {
        if base.count <= 1 { return base }
        // A single command (`\alpha`) or an already-braced group needs nothing.
        if base.hasPrefix("\\"), !base.contains(" "), !base.contains("{") { return base }
        if base.hasPrefix("{"), base.hasSuffix("}") { return base }
        return "{\(base)}"
    }

    /// The accent command for a character used as an over-script.
    private static func accentCommand(_ script: String) -> String? {
        // MathML writes accents either as a spacing character or as the
        // combining mark. The combining ones are given as escapes: they are
        // invisible in source, and two spellings of the same code point would
        // otherwise sit in this switch looking like different cases.
        switch script.trimmingCharacters(in: .whitespaces) {
        case "^", "\u{02C6}", "\u{0302}": return "hat"      // circumflex
        case "~", "\u{02DC}", "\u{0303}": return "tilde"
        case "\u{00AF}", "\u{203E}", "\u{0304}": return "bar" // macron, overline
        case "→", "\u{20D7}": return "vec"                  // arrow above
        case ".", "\u{02D9}", "\u{0307}": return "dot"
        case "..", "\u{00A8}", "\u{0308}": return "ddot"    // diaeresis
        default: return nil
        }
    }

    /// A delimiter for `\left`/`\right`, which take a bare character or a command.
    private static func delimiter(_ raw: String) -> String {
        switch raw {
        case "": return "."
        case "{": return "\\{"
        case "}": return "\\}"
        case "|": return "|"
        case "‖": return "\\|"
        case "⟨": return "\\langle"
        case "⟩": return "\\rangle"
        case "⌈": return "\\lceil"
        case "⌉": return "\\rceil"
        case "⌊": return "\\lfloor"
        case "⌋": return "\\rfloor"
        default: return raw
        }
    }

    /// An operator's LaTeX. Invisible operators produce nothing at all.
    private static func operatorLatex(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        // MathML marks implied multiplication and function application with
        // invisible characters; they carry no notation of their own.
        if text.unicodeScalars.allSatisfy({ (0x2061...0x2064).contains($0.value) }) { return "" }
        if let command = symbolCommand(text) { return command }
        return escapeText(text)
    }

    /// The LaTeX command for a symbol character, if it has one.
    private static func symbolCommand(_ text: String) -> String? {
        guard let command = mathMLSymbols[text] else { return nil }
        return command
    }

    /// Escape the characters LaTeX gives its own meaning.
    private static func escapeText(_ text: String) -> String {
        var out = ""
        for character in text {
            switch character {
            case "\\": out += "\\backslash "
            case "{", "}", "%", "&", "#", "_", "$": out += "\\\(character)"
            case "−": out += "-"      // U+2212, the real minus sign
            case "\u{2062}", "\u{2061}", "\u{2063}", "\u{2064}": break // invisible operators
            default: out.append(character)
            }
        }
        return out
    }

    /// Multi-letter identifiers that are function names rather than products.
    private static let functionNames: Set<String> = [
        "sin", "cos", "tan", "sec", "csc", "cot", "arcsin", "arccos", "arctan",
        "sinh", "cosh", "tanh", "coth", "log", "ln", "lg", "exp", "det", "dim",
        "ker", "deg", "gcd", "arg", "max", "min", "sup", "inf", "lim",
    ]
}

/// The character a rule's match must end with, read off the end of its pattern.
///
/// Every rule's match has to end at the cursor, so its last character is the
/// one just typed. Most rules end in a delimiter — `**`, `--`, a space — and
/// typing a letter can't complete any of them; knowing that, the plugin skips
/// the regex. A rule ends in one of these only when the pattern certainly
/// does: anything the reader below doesn't follow leaves the rule without one,
/// and it runs on every keystroke as before.
package enum LastCharacter: Equatable, Sendable {
    case scalar(Unicode.Scalar)
    /// ICU's `\s`, which is `[\t\n\f\r\p{Z}]`.
    case whitespace

    package func admits(_ scalar: Unicode.Scalar) -> Bool {
        switch self {
        case .scalar(let required): return scalar == required
        // Unicode's White_Space holds all of `\s` and a little more; erring
        // wide only means running a regex that won't match.
        case .whitespace: return scalar.properties.isWhitespace
        }
    }

    /// Nil unless `pattern` ends in `$` and the atom before it is a literal
    /// character or `\s`, reached through any groups that end with it.
    package init?(endOf pattern: String) {
        var reader = PatternReader(Array(pattern.unicodeScalars))
        guard let end = reader.sequence(), reader.atEnd, reader.endsWithAnchor,
              case .known(let last) = end else { return nil }
        self = last
    }
}

/// What a stretch of pattern leaves as its last consumed character.
private enum Tail {
    /// Nothing consumed yet: only anchors and lookarounds so far.
    case none
    case known(LastCharacter)
    case unknown
}

/// Just enough of ICU's regex syntax to find the last atom without being
/// fooled by escapes, classes and groups. Anything else is a nil.
private struct PatternReader {
    let s: [Unicode.Scalar]
    var i = 0
    /// Whether the last thing read at the top level was an end anchor.
    var endsWithAnchor = false

    init(_ s: [Unicode.Scalar]) { self.s = s }

    var atEnd: Bool { i == s.count }
    private var peek: Unicode.Scalar? { i < s.count ? s[i] : nil }

    /// Read up to an unmatched `)` or the end. Nil when the syntax isn't one
    /// this follows.
    mutating func sequence() -> Tail? {
        var tail = Tail.none
        var alternates = false
        while let c = peek, c != ")" {
            i += 1
            endsWithAnchor = false
            switch c {
            case "|":
                alternates = true
            case "^":
                break
            case "$":
                endsWithAnchor = true
            case ".":
                tail = .unknown
            case "*", "?", "{":
                // Optional or counted: the atom may not be the last one.
                if c == "{" {
                    while let d = peek, d != "}" { i += 1 }
                    guard peek == "}" else { return nil }
                    i += 1
                }
                tail = .unknown
            case "+":
                // One or more keeps the atom last.
                break
            case "[":
                guard skipClass() else { return nil }
                tail = .unknown
            case "\\":
                guard let e = peek else { return nil }
                i += 1
                switch e {
                case "s": tail = .known(.whitespace)
                case "b", "B": break
                case "d", "D", "w", "W", "S": tail = .unknown
                default:
                    // Escaped punctuation is itself; other letters and digits
                    // (\p{…}, \x…, \Q…\E, backreferences) aren't followed here.
                    guard e.isASCII, !e.properties.isAlphabetic, !("0"..."9").contains(e) else { return nil }
                    tail = .known(.scalar(e))
                }
            case "(":
                var lookaround = false
                if peek == "?" {
                    i += 1
                    switch peek {
                    case ":", ">": i += 1
                    case "=", "!": i += 1; lookaround = true
                    case "<":
                        i += 1
                        if peek == "=" || peek == "!" {
                            i += 1; lookaround = true
                        } else {
                            // A named group: (?<name>…)
                            while let d = peek, d != ">" {
                                guard d.properties.isAlphabetic || ("0"..."9").contains(d) else { return nil }
                                i += 1
                            }
                            guard peek == ">" else { return nil }
                            i += 1
                        }
                    default:
                        // Flags ((?i), (?x)…) change what the atoms mean.
                        return nil
                    }
                }
                guard let inner = sequence(), peek == ")" else { return nil }
                i += 1
                // An anchor inside a group (`(x$)`, `(?!$)`) isn't followed.
                endsWithAnchor = false
                if lookaround { break }
                switch inner {
                case .none: break
                case .known, .unknown: tail = inner
                }
            default:
                tail = .known(.scalar(c))
            }
        }
        return alternates ? .unknown : tail
    }

    /// Skip a character class, nested ones included, leaving `i` past its `]`.
    private mutating func skipClass() -> Bool {
        var depth = 1
        // A `]` straight after the opening (or after `^`) is a member.
        if peek == "^" { i += 1 }
        if peek == "]" { i += 1 }
        while let c = peek {
            i += 1
            switch c {
            case "\\":
                // \Q…\E could quote a `]`.
                guard let e = peek, e != "Q" else { return false }
                i += 1
            case "[": depth += 1
            case "]":
                depth -= 1
                if depth == 0 { return true }
            default: break
            }
        }
        return false
    }
}

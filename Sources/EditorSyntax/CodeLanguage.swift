#if canImport(UIKit)
import Foundation

/// The languages this highlighter understands.
public enum CodeLanguage: String, Sendable, CaseIterable {
    case javascript
    case typescript
    case css
    case python
    case swift
    case html
    case json
    case shell
    case sql
    case rust
    case go
    case cpp
    case c
}

/// Map a `language` hint (the code block's attribute, or a fenced ```lang tag)
/// to a language, accepting common aliases. Nil when unrecognized.
public func explicitLanguage(_ hint: String?) -> CodeLanguage? {
    guard let h = hint?.lowercased().trimmingCharacters(in: .whitespaces), !h.isEmpty else { return nil }
    switch h {
    case "js", "javascript", "jsx", "mjs", "cjs", "node": return .javascript
    case "ts", "tsx", "typescript": return .typescript
    case "css", "scss", "less", "postcss", "sass": return .css
    case "py", "python", "python3": return .python
    case "swift": return .swift
    case "html", "htm", "xhtml", "xml", "svg", "vue", "svelte": return .html
    case "json", "json5", "jsonc": return .json
    case "sh", "bash", "zsh", "shell", "shell-session", "console", "ksh": return .shell
    case "sql", "postgres", "postgresql", "mysql", "sqlite", "plsql": return .sql
    case "rs", "rust": return .rust
    case "go", "golang": return .go
    case "cpp", "c++", "cxx", "cc", "hpp", "hxx": return .cpp
    case "c", "h": return .c
    default: return nil
    }
}

extension CodeLanguage {
    /// A human label for badges / menus.
    public var displayName: String {
        switch self {
        case .javascript: return "JavaScript"
        case .typescript: return "TypeScript"
        case .css: return "CSS"
        case .python: return "Python"
        case .swift: return "Swift"
        case .html: return "HTML"
        case .json: return "JSON"
        case .shell: return "Shell"
        case .sql: return "SQL"
        case .rust: return "Rust"
        case .go: return "Go"
        case .cpp: return "C++"
        case .c: return "C"
        }
    }
}

/// A content-based language guess and whether it's confident enough to act on
/// (auto-switch highlighting / show as detected). Low-confidence guesses should
/// be ignored so ambiguous snippets render plain.
public struct LanguageGuess: Sendable {
    public let language: CodeLanguage
    public let confident: Bool
}

/// Resolve a language from an explicit hint, falling back to a CONFIDENT
/// content guess. Returns nil when there's no hint and no confident guess.
public func detectCodeLanguage(_ code: String, hint: String?) -> CodeLanguage? {
    if let explicit = explicitLanguage(hint) { return explicit }
    guard let guess = guessLanguage(code), guess.confident else { return nil }
    return guess.language
}

/// Guess the language purely from content. Distinctive, low-overlap signals are
/// weighted; the winner is `confident` only when it clearly beats the field.
public func guessLanguage(_ code: String) -> LanguageGuess? {
    func n(_ pattern: String) -> Int {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return 0 }
        return re.numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code))
    }
    var scores: [CodeLanguage: Int] = [:]

    scores[.html] = 2 * n("</?[a-zA-Z][\\w-]*(?:\\s[^<>]*)?/?>") + 3 * n("(?i)<!doctype")
    scores[.css] = 2 * n("@(?:media|import|keyframes|font-face|supports)\\b")
        + n("[.#][A-Za-z][\\w-]*\\s*\\{") + 2 * n("[A-Za-z-]+\\s*:\\s*[^;{}\\n]+;")
    scores[.python] = 2 * n("(?m)^\\s*(?:def|class|elif)\\b")
        + n("\\b(?:def|elif|lambda|None|True|False|self|import|print)\\b") + n("(?m):\\s*$")
    scores[.shell] = 5 * n("(?m)\\A#!.*\\b(?:sh|bash|zsh)\\b") + n("\\$\\{?\\w")
        + n("\\b(?:fi|esac|done|elif|then)\\b")
    let sqlHits = n("(?i)\\b(?:select|insert|update|delete|create|alter|drop|where|join|from|into)\\b")
    scores[.sql] = sqlHits >= 2 ? sqlHits + 1 : 0
    scores[.rust] = 3 * n("\\bfn\\s") + 2 * n("\\blet\\s+mut\\b") + 2 * n("#!?\\[")
        + n("\\b(?:impl|trait|pub|usize|String|Vec)\\b") + n("::")
    scores[.go] = 3 * n("\\bpackage\\s+\\w") + 2 * n(":=") + n("\\bfunc\\s") + 2 * n("\\bimport\\s+\\(")

    // C-family (C vs C++ by C++-only tokens).
    let cInclude = n("(?m)^\\s*#\\s*include")
    let cppOnly = n("\\bstd::") + n("\\b(?:cout|cin|nullptr|namespace|template)\\b") + n("(?:public|private|protected):")
    let cBase = 2 * cInclude + n("\\bint\\s+main\\b") + n("\\b(?:printf|scanf|malloc|typedef)\\b")
    if cBase + cppOnly > 0 {
        if cppOnly > 0 { scores[.cpp] = cBase + cppOnly + 1 } else { scores[.c] = cBase }
    }

    // Swift: func with arrow/Swift-only keywords (distinguish from Go's func).
    scores[.swift] = n("\\b(?:guard|protocol|extension|mutating|associatedtype)\\b")
        + 3 * n("\\bfunc\\b.*->") + n("->") + n("@\\w+") + n("\\b(?:struct|enum)\\b\\s+\\w")

    // JSON: a leading brace/bracket, quoted keys, and none of the code-y bits.
    if code.range(of: "^\\s*[\\{\\[]", options: .regularExpression) != nil,
       n("=>") == 0, n(";") == 0, n("\\bfunction\\b") == 0 {
        scores[.json] = 2 + n("\"[^\"]*\"\\s*:")
    }

    // JS / TS family (TS only when TS-only tokens appear).
    let jsBase = n("=>") + n("\\b(?:function|const|var|let|console|require|document|window|export)\\b")
    let tsExtra = n("\\b(?:interface|namespace|declare|readonly)\\b")
        + n(":\\s*(?:string|number|boolean|any|void)\\b") + n("\\benum\\b")
    if jsBase + tsExtra > 0 {
        if tsExtra > 0 { scores[.typescript] = jsBase + tsExtra + 1 } else { scores[.javascript] = jsBase }
    }

    let ranked = scores.filter { $0.value > 0 }.sorted { $0.value > $1.value }
    guard let best = ranked.first else { return nil }
    let runnerUp = ranked.dropFirst().first?.value ?? 0
    // Confident when the winner is strong and clearly ahead of the next.
    let confident = best.value >= 3 && best.value >= runnerUp + 2
    return LanguageGuess(language: best.key, confident: confident)
}
#endif

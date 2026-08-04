import Foundation
import Synchronization

// Deliberately not wrapped in `#if canImport(UIKit)`, unlike the rest of
// EditorSyntax. Language *detection* is pure Foundation — only the tokenizer,
// its colours, and the highlighter adapter need UIKit — so this file and
// `LanguageScanner` build on macOS too, which is what lets the detection corpus
// run headless as `swift run EditorSyntaxTests` instead of on a simulator.

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
    case kotlin
    case csharp
    case java
    case php
    case dockerfile
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
    case "kt", "kts", "kotlin": return .kotlin
    case "cs", "c#", "csharp", "dotnet": return .csharp
    case "java", "jsp": return .java
    case "php", "php8", "phtml": return .php
    case "dockerfile", "docker", "containerfile": return .dockerfile
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
        case .kotlin: return "Kotlin"
        case .csharp: return "C#"
        case .java: return "Java"
        case .php: return "PHP"
        case .dockerfile: return "Dockerfile"
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

/// The last few guesses, keyed by the code they were made from.
///
/// A block's language is resolved independently by the highlighter and by the
/// language badge, so laying one out guesses at least twice; repeat layout
/// passes over the same document would pay again. Bounded and small — this
/// exists to collapse those duplicate calls, not to cache a document.
private let recentGuesses = Mutex<[(code: String, guess: LanguageGuess?)]>([])
private let recentGuessLimit = 8

/// Guess the language purely from content. Distinctive, low-overlap signals are
/// weighted; the winner is `confident` only when it clearly beats the field.
///
/// The signals are counted by ``scanGuess`` in a single pass over the block's
/// UTF-8. This used to score ~40 separate regexes over the whole block instead;
/// the scan replaced them at identical verdicts on every sample in the
/// detection corpus, and about three times the speed.
public func guessLanguage(_ code: String) -> LanguageGuess? {
    let cached: LanguageGuess?? = recentGuesses.withLock { entries in
        guard let i = entries.firstIndex(where: { $0.code == code }) else { return nil }
        return .some(entries[i].guess)
    }
    if let cached { return cached }

    let guess = scanGuess(code)
    recentGuesses.withLock { entries in
        entries.append((code, guess))
        if entries.count > recentGuessLimit { entries.removeFirst() }
    }
    return guess
}

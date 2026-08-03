#if canImport(UIKit)
import Foundation
public import EditorUIKit

/// Build a `SyntaxHighlighter` for the EditorUIKit code-block hook.
///
/// ```swift
/// editorView.syntaxHighlighter = makeSyntaxHighlighter()
/// // or themed / restricted:
/// editorView.syntaxHighlighter = makeSyntaxHighlighter(
///     colors: myColors, languages: [.javascript], detectByContent: false)
/// ```
///
/// - colors: token color theme.
/// - languages: which languages to highlight (others render plain).
/// - detectByContent: when no explicit `language` is set on the block, guess
///   from the code's shape. Set false to require an explicit language.
public func makeSyntaxHighlighter(colors: SyntaxColors = .default,
                                  languages: Set<CodeLanguage> = Set(CodeLanguage.allCases),
                                  detectByContent: Bool = true) -> SyntaxHighlighter {
    { code, hint in
        guard let language = resolveLanguage(code, hint, detectByContent: detectByContent),
              languages.contains(language) else { return [] }
        return scan(code, rules(for: language, colors))
    }
}

/// The rule set for a language.
func rules(for language: CodeLanguage, _ c: SyntaxColors) -> [SyntaxRule] {
    switch language {
    case .javascript: return javascriptRules(c)
    case .typescript: return typescriptRules(c)
    case .css: return cssRules(c)
    case .python: return pythonRules(c)
    case .swift: return swiftRules(c)
    case .html: return htmlRules(c)
    case .json: return jsonRules(c)
    case .shell: return shellRules(c)
    case .sql: return sqlRules(c)
    case .rust: return rustRules(c)
    case .go: return goRules(c)
    case .cpp: return cRules(c, cpp: true)
    case .c: return cRules(c, cpp: false)
    case .kotlin: return kotlinRules(c)
    case .csharp: return csharpRules(c)
    case .java: return javaRules(c)
    case .php: return phpRules(c)
    case .dockerfile: return dockerfileRules(c)
    }
}

/// Explicit hint, else a confident content guess (when `detectByContent`).
func resolveLanguage(_ code: String, _ hint: String?, detectByContent: Bool) -> CodeLanguage? {
    if let explicit = explicitLanguage(hint) { return explicit }
    guard detectByContent, let guess = guessLanguage(code), guess.confident else { return nil }
    return guess.language
}

/// Build the code-block language-badge hook for `EditorTextView.codeLanguageLabel`.
/// Returns the language's display name when one is set explicitly or detected
/// confidently, else nil (no badge). `languages` limits which are badged.
public func makeCodeLanguageLabel(languages: Set<CodeLanguage> = Set(CodeLanguage.allCases),
                                  detectByContent: Bool = true) -> (String, String?) -> String? {
    { code, hint in
        guard let language = resolveLanguage(code, hint, detectByContent: detectByContent),
              languages.contains(language) else { return nil }
        return language.displayName
    }
}
#endif

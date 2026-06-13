#if canImport(UIKit)
import Foundation

// Small, deliberately-simple grammars. Rule order is significant: comments and
// strings come first so their contents aren't re-tokenized as keywords/numbers.

func javascriptRules(_ c: SyntaxColors) -> [SyntaxRule] {
    [
        rule(#"/\*.*?\*/"#, c.comment),                 // block comment
        rule(#"//[^\n]*"#, c.comment),                  // line comment
        rule(#"`(?:\\.|[^`\\])*`"#, c.string),          // template string
        rule(#""(?:\\.|[^"\\])*""#, c.string),          // double-quoted
        rule(#"'(?:\\.|[^'\\])*'"#, c.string),          // single-quoted
        rule(#"\b(?:const|let|var|function|return|if|else|for|while|do|switch|case|break|continue|new|class|extends|super|this|typeof|instanceof|in|of|import|export|from|as|default|async|await|yield|try|catch|finally|throw|delete|void|null|true|false|undefined|static|get|set)\b"#, c.keyword),
        rule(#"\b\d+(?:\.\d+)?\b"#, c.number),
    ]
}

func cssRules(_ c: SyntaxColors) -> [SyntaxRule] {
    [
        rule(#"/\*.*?\*/"#, c.comment),                          // comment
        rule(#""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#, c.string), // strings
        rule(#"@[\w-]+"#, c.atRule),                             // at-rules
        rule(#"#[0-9a-fA-F]{3,8}\b"#, c.number),                 // hex colors
        rule(#"\b\d+(?:\.\d+)?(?:px|em|rem|vh|vw|vmin|vmax|pt|pc|cm|mm|ex|ch|fr|deg|s|ms)?%?"#, c.number),
        rule(#"[A-Za-z-][\w-]*(?=\s*:)"#, c.property),           // property name before `:`
    ]
}

func pythonRules(_ c: SyntaxColors) -> [SyntaxRule] {
    [
        rule(#"#[^\n]*"#, c.comment),                            // comment
        rule(#"""""".*?""""""#, c.string),                       // triple-double docstring
        rule(#"'''.*?'''"#, c.string),                           // triple-single docstring
        rule(#""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#, c.string), // strings
        rule(#"@[\w.]+"#, c.atRule),                             // decorators
        rule(#"\b(?:def|class|return|if|elif|else|for|while|import|from|as|with|try|except|finally|raise|lambda|None|True|False|and|or|not|in|is|pass|break|continue|global|nonlocal|yield|assert|del|async|await|self)\b"#, c.keyword),
        rule(#"\b\d+(?:\.\d+)?\b"#, c.number),
    ]
}

func swiftRules(_ c: SyntaxColors) -> [SyntaxRule] {
    [
        rule(#"/\*.*?\*/"#, c.comment),                          // block comment
        rule(#"//[^\n]*"#, c.comment),                           // line comment
        rule(#""""".*?""""#, c.string),                          // multiline string
        rule(#""(?:\\.|[^"\\])*""#, c.string),                   // string
        rule(#"@\w+"#, c.atRule),                                // attributes (@objc…)
        rule(#"\b(?:func|let|var|struct|class|enum|protocol|extension|import|return|if|else|guard|for|while|repeat|switch|case|default|break|continue|defer|do|try|catch|throw|throws|rethrows|init|deinit|self|super|nil|true|false|some|any|as|is|in|where|associatedtype|typealias|public|private|internal|fileprivate|open|final|static|lazy|weak|unowned|mutating|nonmutating|override|convenience|required|indirect|inout|async|await|actor)\b"#, c.keyword),
        rule(#"\b[A-Z]\w*\b"#, c.property),                      // types (Capitalized)
        rule(#"\b\d+(?:\.\d+)?\b"#, c.number),
    ]
}

func htmlRules(_ c: SyntaxColors) -> [SyntaxRule] {
    [
        rule(#"<!--.*?-->"#, c.comment),                         // comment
        rule(#"(?i)<!DOCTYPE[^>]*>"#, c.atRule),                 // doctype
        rule(#""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#, c.string), // attribute values
        rule(#"</?[a-zA-Z][\w-]*"#, c.keyword),                  // tag name (with `<`)
        rule(#"[a-zA-Z-]+(?=\s*=)"#, c.property),                // attribute names
        rule(#"&[a-zA-Z#0-9]+;"#, c.number),                     // entities
    ]
}

func typescriptRules(_ c: SyntaxColors) -> [SyntaxRule] {
    [
        rule(#"/\*.*?\*/"#, c.comment),
        rule(#"//[^\n]*"#, c.comment),
        rule(#"`(?:\\.|[^`\\])*`"#, c.string),
        rule(#""(?:\\.|[^"\\])*""#, c.string),
        rule(#"'(?:\\.|[^'\\])*'"#, c.string),
        rule(#"@[\w.]+"#, c.atRule),                            // decorators
        rule(#"\b(?:const|let|var|function|return|if|else|for|while|do|switch|case|break|continue|new|class|extends|super|this|typeof|instanceof|in|of|import|export|from|as|default|async|await|yield|try|catch|finally|throw|delete|void|null|true|false|undefined|static|get|set|interface|type|enum|namespace|declare|readonly|public|private|protected|implements|abstract|keyof|infer|satisfies|override|is|module)\b"#, c.keyword),
        rule(#"\b[A-Z]\w*\b"#, c.property),                     // types
        rule(#"\b\d+(?:\.\d+)?\b"#, c.number),
    ]
}

func jsonRules(_ c: SyntaxColors) -> [SyntaxRule] {
    [
        rule(#""(?:\\.|[^"\\])*"(?=\s*:)"#, c.property),         // object keys
        rule(#""(?:\\.|[^"\\])*""#, c.string),                  // string values
        rule(#"\b(?:true|false|null)\b"#, c.keyword),
        rule(#"-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#, c.number),
    ]
}

func shellRules(_ c: SyntaxColors) -> [SyntaxRule] {
    [
        rule(#"#[^\n]*"#, c.comment),
        rule(#""(?:\\.|[^"\\])*""#, c.string),
        rule(#"'[^']*'"#, c.string),
        rule(#"\$\{[^}]*\}|\$\w+"#, c.property),                // variables
        rule(#"\b(?:if|then|else|elif|fi|for|while|until|do|done|case|esac|function|in|select|return|break|continue|local|export|readonly|source|alias|echo|cd|exit|set|unset)\b"#, c.keyword),
        rule(#"\b\d+\b"#, c.number),
    ]
}

func sqlRules(_ c: SyntaxColors) -> [SyntaxRule] {
    [
        rule(#"--[^\n]*"#, c.comment),
        rule(#"/\*.*?\*/"#, c.comment),
        rule(#"'(?:''|[^'])*'"#, c.string),
        rule(#"(?i)\b(?:select|from|where|insert|into|values|update|set|delete|create|table|drop|alter|add|column|primary|key|foreign|references|join|inner|left|right|outer|full|on|group|by|order|asc|desc|having|limit|offset|distinct|as|and|or|not|null|is|in|like|between|union|all|exists|count|sum|avg|min|max|case|when|then|else|end|index|view|default|constraint|unique|cascade|begin|commit|rollback)\b"#, c.keyword),
        rule(#"\b\d+(?:\.\d+)?\b"#, c.number),
    ]
}

func rustRules(_ c: SyntaxColors) -> [SyntaxRule] {
    [
        rule(#"/\*.*?\*/"#, c.comment),
        rule(#"//[^\n]*"#, c.comment),
        rule(#""(?:\\.|[^"\\])*""#, c.string),
        rule(#"#!?\[[^\]]*\]"#, c.atRule),                     // attributes
        rule(#"\b(?:fn|let|mut|const|static|struct|enum|trait|impl|pub|use|mod|match|if|else|for|while|loop|return|self|Self|where|as|in|ref|move|dyn|async|await|unsafe|extern|crate|super|type|break|continue|box|true|false)\b"#, c.keyword),
        rule(#"\b[A-Z]\w*\b"#, c.property),
        rule(#"\b\d+(?:\.\d+)?\b"#, c.number),
    ]
}

func goRules(_ c: SyntaxColors) -> [SyntaxRule] {
    [
        rule(#"/\*.*?\*/"#, c.comment),
        rule(#"//[^\n]*"#, c.comment),
        rule(#"`[^`]*`"#, c.string),                           // raw string
        rule(#""(?:\\.|[^"\\])*""#, c.string),
        rule(#"\b(?:func|var|const|type|struct|interface|map|chan|package|import|return|if|else|for|range|switch|case|default|go|defer|select|break|continue|fallthrough|goto|nil|true|false|iota)\b"#, c.keyword),
        rule(#"\b[A-Z]\w*\b"#, c.property),
        rule(#"\b\d+(?:\.\d+)?\b"#, c.number),
    ]
}

func cRules(_ c: SyntaxColors, cpp: Bool) -> [SyntaxRule] {
    let base = "auto|break|case|char|const|continue|default|do|double|else|enum|extern|float|for|goto|if|int|long|register|return|short|signed|sizeof|static|struct|switch|typedef|union|unsigned|void|volatile|while|bool|true|false|NULL"
    let cppExtra = "|class|public|private|protected|virtual|template|typename|namespace|using|new|delete|this|nullptr|constexpr|override|final|friend|operator|explicit|mutable|noexcept|decltype|throw|try|catch|auto"
    let keywords = cpp ? base + cppExtra : base
    return [
        rule(#"/\*.*?\*/"#, c.comment),
        rule(#"//[^\n]*"#, c.comment),
        rule(#"(?m)^\s*#\s*\w+"#, c.atRule),                   // preprocessor
        rule(#""(?:\\.|[^"\\])*""#, c.string),
        rule(#"'(?:\\.|[^'\\])'"#, c.string),                  // char literal
        rule("\\b(?:\(keywords))\\b", c.keyword),
        rule(#"\b[A-Z]\w*\b"#, c.property),                    // types / macros
        rule(#"\b\d+(?:\.\d+)?\b"#, c.number),
    ]
}
#endif

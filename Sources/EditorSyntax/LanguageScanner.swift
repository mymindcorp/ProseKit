import Foundation

// Content-based language detection: one pass over the block's UTF-8, counting
// the signals the scorer weighs.
//
// This replaced a scorer that ran ~40 separate regexes over the whole block.
// Nearly every signal it wanted is "is this identifier in a set" or "are these
// two tokens adjacent" — questions a token stream answers directly, so the
// regexes were doing a dictionary lookup's job forty times over. The rewrite
// reproduced the old verdict on every sample in the detection corpus.
//
// Signals that can't be reduced to a word or a pair — an HTML tag, a CSS
// declaration — are matched by the small hand-rolled scanners at the bottom of
// this file, and their doc comments carry the regex they replaced.
//
// Foundation only, and not UIKit-gated — see the note in `CodeLanguage.swift`.

/// The signals a bare identifier contributes to. One identifier can carry
/// several (`import` is a Python word and part of Go's import-group shape).
private struct WordSignals: OptionSet {
    let rawValue: UInt32
    static let python       = WordSignals(rawValue: 1 << 0)
    static let pythonOpener = WordSignals(rawValue: 1 << 1)
    static let shell        = WordSignals(rawValue: 1 << 2)
    static let rust         = WordSignals(rawValue: 1 << 3)
    static let cpp          = WordSignals(rawValue: 1 << 4)
    static let c            = WordSignals(rawValue: 1 << 5)
    static let swift        = WordSignals(rawValue: 1 << 6)
    static let js           = WordSignals(rawValue: 1 << 7)
    static let ts           = WordSignals(rawValue: 1 << 8)
    static let cssAtRule    = WordSignals(rawValue: 1 << 9)
    static let tsType       = WordSignals(rawValue: 1 << 10)
    static let accessLabel  = WordSignals(rawValue: 1 << 11)
    static let kotlin       = WordSignals(rawValue: 1 << 12)
    static let csharp       = WordSignals(rawValue: 1 << 13)
    static let java         = WordSignals(rawValue: 1 << 14)
    static let php          = WordSignals(rawValue: 1 << 15)
    static let phpStrong    = WordSignals(rawValue: 1 << 16)
    static let dockerfile   = WordSignals(rawValue: 1 << 17)
}

/// The same word lists the regex alternations held, as one lookup table.
private let wordSignals: [String: WordSignals] = {
    var table: [String: WordSignals] = [:]
    func add(_ words: [String], _ signal: WordSignals) {
        for word in words { table[word, default: []].insert(signal) }
    }
    add(["def", "elif", "lambda", "None", "True", "False", "self", "import", "print"], .python)
    add(["def", "class", "elif"], .pythonOpener)
    add(["fi", "esac", "done", "elif", "then"], .shell)
    // `String` is deliberately absent: Java, Kotlin, C# and Swift all lean on
    // it far harder than Rust does, so it scored Rust points on their code
    // while Rust's own samples are carried by `fn` and `let mut`.
    add(["impl", "trait", "pub", "usize", "Vec"], .rust)
    add(["cout", "cin", "nullptr", "namespace", "template"], .cpp)
    add(["printf", "scanf", "malloc", "typedef"], .c)
    add(["guard", "protocol", "extension", "mutating", "associatedtype"], .swift)
    add(["function", "const", "var", "let", "console", "require", "document", "window", "export"], .js)
    add(["interface", "namespace", "declare", "readonly", "keyof", "satisfies", "implements"], .ts)
    add(["media", "import", "keyframes", "font-face", "supports"], .cssAtRule)
    add(["string", "number", "boolean", "any", "void"], .tsType)
    add(["public", "private", "protected"], .accessLabel)
    add(["when", "sealed", "lateinit", "companion", "suspend", "vararg",
         "reified", "object", "Unit", "coroutineScope", "listOf", "mutableListOf",
         "mapOf", "mutableMapOf", "setOf", "mutableSetOf", "arrayOf", "println"], .kotlin)
    add(["nameof", "partial", "virtual", "unchecked", "stackalloc", "IEnumerable",
         "IDisposable", "ICollection", "IReadOnlyList", "Nullable"], .csharp)
    // Deliberately excluded: `instanceof` and `extends` (JavaScript), `String`
    // (Rust's list), `boolean` (TypeScript's), and `println` — Java writes that
    // one as `System.out.println`, which `javaSystemOut` already catches, while
    // a bare `println` is Kotlin's.
    add(["ArrayList", "HashMap", "HashSet", "LinkedList", "StringBuilder",
         "Integer", "synchronized", "throws", "final", "boolean"], .java)
    // `echo` is deliberately absent — shell scripts are full of it, and it was
    // costing shell its own samples.
    add(["var_dump", "isset", "unset", "array_map", "array_filter",
         "str_replace", "implode", "explode", "preg_match", "json_encode",
         "json_decode", "sprintf"], .php)
    add(["__construct", "__toString", "__invoke", "__get", "__set",
         "require_once", "include_once", "elseif"], .phpStrong)
    // Every instruction a Dockerfile can open a line with, except FROM, which
    // is scored on its own — a Dockerfile always has one and little else does.
    add(["RUN", "CMD", "COPY", "ADD", "WORKDIR", "ENV", "EXPOSE", "ENTRYPOINT",
         "VOLUME", "USER", "ARG", "LABEL", "HEALTHCHECK", "ONBUILD",
         "STOPSIGNAL", "SHELL", "MAINTAINER"], .dockerfile)
    return table
}()

/// PHP's superglobals — `$` plus one of these is unmistakable.
private let phpSuperglobals: Set<String> = [
    "_GET", "_POST", "_SERVER", "_SESSION", "_REQUEST", "_ENV", "_FILES", "_COOKIE",
]

private let sqlWords: Set<String> = [
    "select", "insert", "update", "delete", "create", "alter",
    "drop", "where", "join", "from", "into",
]

/// One counter per signal the scorer weighs — the scan's whole output.
private struct SignalCounts {
    var htmlTag = 0, doctype = 0
    var cssAtRule = 0, cssSelector = 0, cssDeclaration = 0
    var pythonOpener = 0, pythonWord = 0, trailingColon = 0
    var shellShebang = 0, shellVariable = 0, shellWord = 0
    var sqlWord = 0
    var rustFn = 0, rustLetMut = 0, rustAttribute = 0, rustWord = 0, scopeOperator = 0
    var goPackage = 0, goAssign = 0, goFunc = 0, goImportGroup = 0
    var cInclude = 0, cppNamespaced = 0, cppWord = 0, cppAccessLabel = 0, cMain = 0, cWord = 0
    var swiftWord = 0, swiftFuncArrow = 0, returnArrow = 0, annotation = 0, swiftTypeDecl = 0
    var jsonOpening = 0, jsonKey = 0, semicolon = 0, functionWord = 0
    var fatArrow = 0, jsWord = 0, tsWord = 0, tsAnnotation = 0, tsEnum = 0
    var kotlinFun = 0, kotlinVal = 0, kotlinDataClass = 0, kotlinWord = 0
    var kotlinWhen = 0, kotlinSuspendFun = 0, kotlinExtensionFun = 0, kotlinItReceiver = 0
    var kotlinPackageDotted = 0
    var csharpConsole = 0, csharpUsing = 0, csharpProperty = 0, csharpForeach = 0
    var csharpMain = 0, csharpVerbatimString = 0, csharpWord = 0
    var csharpPublicType = 0, csharpAsyncTask = 0, csharpSwitchExpression = 0
    var javaSystemOut = 0, javaMain = 0, javaImport = 0, javaOverride = 0
    var javaPackage = 0, javaArrayDecl = 0, javaWord = 0
    var phpOpenTag = 0, phpThisArrow = 0, phpVisibilityFunction = 0
    var phpFunctionDollarParam = 0, phpForeachAs = 0, phpUseBackslash = 0
    var phpSuperglobal = 0, phpStrongWord = 0, phpWord = 0
    var phpVariable = 0, phpAssignment = 0
    var dockerFrom = 0, dockerInstruction = 0
}

private func isIdentifierStart(_ b: UInt8) -> Bool {
    (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F || b >= 0x80
}

private func isIdentifierBody(_ b: UInt8) -> Bool {
    isIdentifierStart(b) || (b >= 0x30 && b <= 0x39)
}

private func isHorizontalSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0D }

private func scanSignals(_ code: String) -> SignalCounts {
    let bytes = Array(code.utf8)
    var counts = SignalCounts()
    guard !bytes.isEmpty else { return counts }

    let newline = UInt8(ascii: "\n"), colon = UInt8(ascii: ":"), semicolon = UInt8(ascii: ";")
    let hash = UInt8(ascii: "#"), at = UInt8(ascii: "@"), dollar = UInt8(ascii: "$")
    let less = UInt8(ascii: "<"), greater = UInt8(ascii: ">"), slash = UInt8(ascii: "/")
    let dot = UInt8(ascii: "."), dash = UInt8(ascii: "-"), equals = UInt8(ascii: "=")
    let bang = UInt8(ascii: "!"), openBrace = UInt8(ascii: "{"), openBracket = UInt8(ascii: "[")
    let openParen = UInt8(ascii: "("), closeBrace = UInt8(ascii: "}")
    let closeBracket = UInt8(ascii: "]"), backslash = UInt8(ascii: "\\")
    let question = UInt8(ascii: "?")

    /// `\A#!.*\b(?:sh|bash|zsh)\b` — first line only.
    let firstLineEnd = bytes.firstIndex(of: newline) ?? bytes.count
    if bytes.count > 1, bytes[0] == hash, bytes[1] == bang {
        let firstLine = String(decoding: bytes[0..<firstLineEnd], as: UTF8.self)
        for shell in ["sh", "bash", "zsh"] where firstLine.contains(shell) {
            // `\b`-equivalent: the shells only appear as a path or argv word here.
            counts.shellShebang = 1
            break
        }
    }

    var i = 0
    var atLineStart = true          // only whitespace so far on this line
    var seenNonSpace = false        // anywhere in the block
    var lastSignificant: UInt8 = 0  // last non-whitespace byte consumed
    var previousWord = ""           // last identifier, for adjacency rules
    var wordBeforeThat = ""         // the one before it, for three-word shapes
    var lineHasFunc = false         // `func` earlier on this line, for `func … ->`
    var lineHasDeclaration = false  // `ident :` earlier on this line, for CSS

    /// The next non-whitespace byte at or after `from`, without consuming.
    func peekSignificant(from: Int) -> UInt8 {
        var j = from
        while j < bytes.count, isHorizontalSpace(bytes[j]) { j += 1 }
        return j < bytes.count ? bytes[j] : 0
    }

    /// The identifier starting exactly at `index`, or "" if none does.
    func identifier(at index: Int) -> String {
        var j = index
        while j < bytes.count, isIdentifierBody(bytes[j]) { j += 1 }
        return j > index ? String(decoding: bytes[index..<j], as: UTF8.self) : ""
    }

    /// First index at or after `from` that isn't whitespace — `\s*`, so
    /// newlines count too.
    func skippingSpace(from: Int) -> Int {
        var j = from
        while j < bytes.count, isHorizontalSpace(bytes[j]) || bytes[j] == newline { j += 1 }
        return j
    }

    while i < bytes.count {
        let b = bytes[i]

        if b == newline {
            if lastSignificant == colon { counts.trailingColon += 1 }
            atLineStart = true
            lineHasFunc = false
            lineHasDeclaration = false
            lastSignificant = 0
            previousWord = ""
            wordBeforeThat = ""
            i += 1
            continue
        }
        if isHorizontalSpace(b) { i += 1; continue }

        let wasLineStart = atLineStart
        atLineStart = false
        if !seenNonSpace {
            seenNonSpace = true
            if b == openBrace || b == openBracket { counts.jsonOpening = 1 }
        }
        let precededByColon = lastSignificant == colon

        // MARK: identifiers

        if isIdentifierStart(b) {
            let start = i
            while i < bytes.count, isIdentifierBody(bytes[i]) { i += 1 }
            let word = String(decoding: bytes[start..<i], as: UTF8.self)
            let signals = wordSignals[word] ?? []

            if signals.contains(.python) { counts.pythonWord += 1 }
            if signals.contains(.pythonOpener), wasLineStart { counts.pythonOpener += 1 }
            if signals.contains(.shell) { counts.shellWord += 1 }
            if signals.contains(.rust) { counts.rustWord += 1 }
            if signals.contains(.cpp) { counts.cppWord += 1 }
            if signals.contains(.c) { counts.cWord += 1 }
            if signals.contains(.swift) { counts.swiftWord += 1 }
            if signals.contains(.js) { counts.jsWord += 1 }
            if signals.contains(.ts) { counts.tsWord += 1 }
            if signals.contains(.tsType), precededByColon { counts.tsAnnotation += 1 }
            if signals.contains(.kotlin) { counts.kotlinWord += 1 }
            if signals.contains(.csharp) { counts.csharpWord += 1 }
            if signals.contains(.java) { counts.javaWord += 1 }
            if signals.contains(.php) { counts.phpWord += 1 }
            if signals.contains(.phpStrong) { counts.phpStrongWord += 1 }
            if signals.contains(.dockerfile), wasLineStart { counts.dockerInstruction += 1 }
            // SQL is the one case-insensitive word list, and lowercasing every
            // identifier in the block to serve it is most of the scan's cost.
            // Every SQL keyword here is 4-6 bytes, so the length check skips
            // the conversion for the overwhelming majority of identifiers.
            if word.utf8.count >= 4, word.utf8.count <= 6,
               sqlWords.contains(word.lowercased()) {
                counts.sqlWord += 1
            }

            let next = i < bytes.count ? bytes[i] : 0
            let nextSignificant = peekSignificant(from: i)
            switch word {
            case "fn" where isHorizontalSpace(next) || next == newline:
                counts.rustFn += 1
            case "func":
                if isHorizontalSpace(next) || next == newline { counts.goFunc += 1 }
                lineHasFunc = true
            case "enum":
                counts.tsEnum += 1
                if previousWord == "public" { counts.csharpPublicType += 1 }
            case "package" where isIdentifierStart(nextSignificant):
                // Three languages open a file this way, and the path itself
                // tells them apart. Go takes a bare name (`package main`);
                // a dotted path is Java or Kotlin, and only Java terminates
                // it with a semicolon.
                //
                // The dotted case deliberately does *not* score for Go — it
                // used to, which meant every Java and Kotlin header handed Go
                // its strongest signal.
                var j = skippingSpace(from: i)
                let nameStart = j
                var dotted = false
                while j < bytes.count, isIdentifierBody(bytes[j]) || bytes[j] == dot {
                    if bytes[j] == dot { dotted = true }
                    j += 1
                }
                if j > nameStart, dotted {
                    if peekSignificant(from: j) == semicolon { counts.javaPackage += 1 }
                    else { counts.kotlinPackageDotted += 1 }
                } else {
                    counts.goPackage += 1
                }
            case "import" where nextSignificant == openParen:
                counts.goImportGroup += 1
            case "std" where next == colon && i + 1 < bytes.count && bytes[i + 1] == colon:
                counts.cppNamespaced += 1
            case "main" where previousWord == "int":
                counts.cMain += 1
            case "mut" where previousWord == "let":
                counts.rustLetMut += 1
            case "fun":
                if isHorizontalSpace(next) || next == newline { counts.kotlinFun += 1 }
                if previousWord == "suspend" { counts.kotlinSuspendFun += 1 }
            case "val" where isHorizontalSpace(next) || next == newline:
                counts.kotlinVal += 1
            case "class" where previousWord == "data":
                counts.kotlinDataClass += 1
            case "when" where nextSignificant == openParen || nextSignificant == openBrace:
                counts.kotlinWhen += 1
            case "it" where next == dot:
                counts.kotlinItReceiver += 1
            case "Console" where next == dot:
                let member = identifier(at: i + 1)
                if member == "Write" || member == "WriteLine"
                    || member == "Read" || member == "ReadLine" {
                    counts.csharpConsole += 1
                }
            case "using" where wasLineStart:
                // `^\s*using\s+[A-Z]\w*(?:\.\w+)*\s*;`
                var j = skippingSpace(from: i)
                if j < bytes.count, bytes[j] >= 0x41, bytes[j] <= 0x5A {
                    while j < bytes.count, isIdentifierBody(bytes[j]) || bytes[j] == dot { j += 1 }
                    j = skippingSpace(from: j)
                    if j < bytes.count, bytes[j] == semicolon { counts.csharpUsing += 1 }
                }
            case "get" where next == semicolon:
                // `\bget;\s*set;`
                let j = skippingSpace(from: i + 1)
                if identifier(at: j) == "set", j + 3 < bytes.count, bytes[j + 3] == semicolon {
                    counts.csharpProperty += 1
                }
            case "foreach" where nextSignificant == openParen:
                counts.csharpForeach += 1
                // `\bforeach\s*\(\s*\$\w+\s+as\b` — PHP's form names the source
                // and the binding either side of `as`; C#'s uses `in`.
                let paren = skippingSpace(from: i)
                if peekSignificant(from: paren + 1) == dollar {
                    let varStart = skippingSpace(from: paren + 1) + 1
                    let name = identifier(at: varStart)
                    if !name.isEmpty,
                       identifier(at: skippingSpace(from: varStart + name.utf8.count)) == "as" {
                        counts.phpForeachAs += 1
                    }
                }
            case "Main" where previousWord == "void" && wordBeforeThat == "static":
                counts.csharpMain += 1
            // `enum` is handled by its own case above (it also feeds TypeScript),
            // so it checks `public` there rather than here.
            case "class", "interface", "record", "struct":
                if previousWord == "public" { counts.csharpPublicType += 1 }
            case "Task" where previousWord == "async":
                counts.csharpAsyncTask += 1
            case "switch" where !previousWord.isEmpty:
                // A switch *expression* — an operand sits before the keyword.
                counts.csharpSwitchExpression += 1
            case "System" where next == dot:
                // `\bSystem\.(?:out|err)\.print` — C#'s `System` is a namespace
                // in a `using`, never a receiver with an `out`/`err` member.
                let stream = identifier(at: i + 1)
                if stream == "out" || stream == "err" {
                    let after = i + 1 + stream.utf8.count
                    if after < bytes.count, bytes[after] == dot,
                       identifier(at: after + 1).hasPrefix("print") {
                        counts.javaSystemOut += 1
                    }
                }
            case "main" where previousWord == "void" && wordBeforeThat == "static":
                // `\bstatic\s+void\s+main\s*\(` — C#'s entry point is `Main`,
                // and the scan is case-sensitive, so the two don't collide.
                if nextSignificant == openParen { counts.javaMain += 1 }
            case "FROM" where wasLineStart:
                counts.dockerFrom += 1
            case "function":
                counts.functionWord += 1
                // `\b(?:public|private|protected)\s+(?:static\s+)?function\b` —
                // the visibility/`function` pairing is PHP's; Java and C# have
                // no `function` keyword and JavaScript classes have no
                // visibility modifiers.
                let owner = previousWord == "static" ? wordBeforeThat : previousWord
                if owner == "public" || owner == "private" || owner == "protected" {
                    counts.phpVisibilityFunction += 1
                }
                // `\bfunction\s+\w+\s*\(\s*\$` — a `$`-sigil parameter list.
                let nameStart = skippingSpace(from: i)
                let name = identifier(at: nameStart)
                if !name.isEmpty {
                    let afterName = skippingSpace(from: nameStart + name.utf8.count)
                    if afterName < bytes.count, bytes[afterName] == openParen,
                       peekSignificant(from: afterName + 1) == dollar {
                        counts.phpFunctionDollarParam += 1
                    }
                }
            case "use" where wasLineStart:
                // `^\s*use\s+\w+(?:\\\w+)+\s*;` — a namespace path separated by
                // backslashes, which no other language here writes.
                var j = skippingSpace(from: i)
                var backslashed = false
                while j < bytes.count, isIdentifierBody(bytes[j]) || bytes[j] == backslash {
                    if bytes[j] == backslash { backslashed = true }
                    j += 1
                }
                if backslashed, peekSignificant(from: j) == semicolon { counts.phpUseBackslash += 1 }
            case "import" where wasLineStart:
                // `^\s*import\s+(?:java|javax)\.`
                let j = skippingSpace(from: i)
                let root = identifier(at: j)
                if root == "java" || root == "javax",
                   j + root.utf8.count < bytes.count, bytes[j + root.utf8.count] == dot {
                    counts.javaImport += 1
                }
            default:
                break
            }
            // `\b(?:struct|enum)\b\s+\w`
            if previousWord == "struct" || previousWord == "enum" { counts.swiftTypeDecl += 1 }
            // `\bfun\s+\w+\.` — an extension function's receiver type.
            if previousWord == "fun", next == dot { counts.kotlinExtensionFun += 1 }
            // `\b[A-Z]\w*\[\]\s+\w` — a Java array declaration (`String[] args`).
            // C# writes the built-in element types in lower case (`string[]`).
            if bytes[start] >= 0x41, bytes[start] <= 0x5A, next == openBracket,
               i + 1 < bytes.count, bytes[i + 1] == closeBracket,
               isIdentifierStart(peekSignificant(from: i + 2)) {
                counts.javaArrayDecl += 1
            }
            // `(?:public|private|protected):` — a label, not a `::` qualifier.
            if signals.contains(.accessLabel), next == colon,
               !(i + 1 < bytes.count && bytes[i + 1] == colon) {
                counts.cppAccessLabel += 1
            }
            // `[A-Za-z-]+\s*:\s*…;` — the declaration shape CSS scores on.
            if nextSignificant == colon { lineHasDeclaration = true }

            wordBeforeThat = previousWord
            previousWord = word
            lastSignificant = bytes[i - 1]
            continue
        }

        // MARK: strings

        // `"[^"]*"\s*:` — the JSON key shape, found by looking ahead rather
        // than by consuming the string. The regexes scored inside string
        // literals too, and that content is real signal: shell's `"$VAR"` is
        // the clearest case. So only the quote itself is consumed here and the
        // body is scanned like any other text.
        if b == UInt8(ascii: "\"") {
            var j = i + 1
            while j < bytes.count, bytes[j] != b, bytes[j] != newline { j += 1 }
            if j < bytes.count, bytes[j] == b, peekSignificant(from: j + 1) == colon {
                counts.jsonKey += 1
            }
            i += 1
            previousWord = ""
            wordBeforeThat = ""
            lastSignificant = b
            continue
        }

        // MARK: operators and punctuation

        let next = i + 1 < bytes.count ? bytes[i + 1] : 0
        switch b {
        case colon where next == equals:
            counts.goAssign += 1
            i += 2
        case colon where next == colon:
            counts.scopeOperator += 1
            i += 2
        case equals where next == greater:
            counts.fatArrow += 1
            i += 2
        case dash where next == greater:
            counts.returnArrow += 1
            if lineHasFunc { counts.swiftFuncArrow += 1 }
            i += 2
        case semicolon:
            if lineHasDeclaration { counts.cssDeclaration += 1; lineHasDeclaration = false }
            counts.semicolon += 1
            i += 1
        case openBrace, closeBrace:
            // `[^;{}\n]+` — a brace between the colon and the semicolon means
            // this was never a declaration. Without this, shell's
            // `echo "usage: $0 {a|b}" ;;` scores as CSS.
            lineHasDeclaration = false
            i += 1
        case at:
            if next == UInt8(ascii: "\"") { counts.csharpVerbatimString += 1 }
            let start = i + 1
            var j = start
            while j < bytes.count, isIdentifierBody(bytes[j]) || bytes[j] == dash { j += 1 }
            if j > start {
                counts.annotation += 1
                let word = String(decoding: bytes[start..<j], as: UTF8.self)
                if wordSignals[word]?.contains(.cssAtRule) == true { counts.cssAtRule += 1 }
                // `@Override` is Java's; Kotlin spells it as a bare keyword.
                if word == "Override" { counts.javaOverride += 1 }
            }
            i = j > start ? j : i + 1
        case hash:
            // `#[`/`#![` (Rust), `^\s*#\s*include` (C), `#id {` (CSS).
            if next == openBracket || (next == bang && i + 2 < bytes.count && bytes[i + 2] == openBracket) {
                counts.rustAttribute += 1
            } else if wasLineStart, matchesWord("include", at: i + 1, in: bytes) {
                counts.cInclude += 1
            } else if next != 0, isIdentifierStart(next) {
                if scanSelectorTail(from: i + 1, in: bytes) { counts.cssSelector += 1 }
            }
            i += 1
        case dot where isIdentifierStart(next):
            if scanSelectorTail(from: i + 1, in: bytes) { counts.cssSelector += 1 }
            i += 1
        case dollar where next == openBrace || isIdentifierBody(next):
            counts.shellVariable += 1
            // PHP shares the `$` sigil with shell, so a variable alone can't
            // separate them — but the shapes around it can.
            let name = identifier(at: i + 1)
            if !name.isEmpty, isIdentifierStart(bytes[i + 1]) {
                // A named variable. `$1`/`$0` are shell's positional
                // parameters and aren't valid PHP identifiers, so they don't
                // count — that's what keeps `case "$1" in` shell.
                counts.phpVariable += 1
                let after = skippingSpace(from: i + 1 + name.utf8.count)
                // `$var =` is an assignment, which shell writes without the
                // sigil (`var=`). `==` is a comparison, not a binding.
                if after < bytes.count, bytes[after] == equals,
                   !(after + 1 < bytes.count && bytes[after + 1] == equals) {
                    counts.phpAssignment += 1
                }
            }
            if phpSuperglobals.contains(name) { counts.phpSuperglobal += 1 }
            if name == "this" {
                let after = i + 1 + name.utf8.count
                if after + 1 < bytes.count, bytes[after] == dash, bytes[after + 1] == greater {
                    counts.phpThisArrow += 1
                }
            }
            i += 1
        case less:
            // `<?php` / `<?=` — decisive, and deliberately not `<?` alone,
            // which would also match an XML processing instruction.
            if next == question, identifier(at: i + 2) == "php" || peekSignificant(from: i + 2) == equals {
                counts.phpOpenTag += 1
            } else if next == bang, matchesWordCaseInsensitive("doctype", at: i + 2, in: bytes) {
                counts.doctype += 1
            } else if isIdentifierStart(next) || (next == slash && i + 2 < bytes.count && isIdentifierStart(bytes[i + 2])) {
                // A tag's `<` never follows an identifier character directly:
                // markup writes `<div>` after whitespace or a `>`, while a
                // generic writes `Result<T>` hard against its type name. That
                // one byte is what separates them, and without it every
                // TypeScript, Kotlin, C# and Java snippet using generics
                // scored as HTML.
                //
                // Closing tags are exempt — `text</div>` legitimately follows
                // content, and `</` can't open a generic.
                let afterIdentifier = i > 0 && isIdentifierBody(bytes[i - 1])
                if !afterIdentifier || next == slash {
                    if scanTagTail(from: i + 1, in: bytes) { counts.htmlTag += 1 }
                }
            }
            i += 1
        default:
            i += 1
        }
        previousWord = ""
        wordBeforeThat = ""
        lastSignificant = bytes[i - 1]
    }
    if lastSignificant == colon { counts.trailingColon += 1 }
    return counts
}

/// Whether `word` sits at `index`, allowing leading horizontal space.
private func matchesWord(_ word: String, at index: Int, in bytes: [UInt8]) -> Bool {
    var j = index
    while j < bytes.count, isHorizontalSpace(bytes[j]) { j += 1 }
    let needle = Array(word.utf8)
    guard j + needle.count <= bytes.count else { return false }
    for (offset, byte) in needle.enumerated() where bytes[j + offset] != byte { return false }
    return true
}

private func matchesWordCaseInsensitive(_ word: String, at index: Int, in bytes: [UInt8]) -> Bool {
    let needle = Array(word.utf8)
    guard index >= 0, index + needle.count <= bytes.count else { return false }
    for (offset, byte) in needle.enumerated() {
        let actual = bytes[index + offset] | 0x20 // ASCII lowercase
        if actual != byte { return false }
    }
    return true
}

/// `[\w-]*\s*\{` — the tail of a CSS selector, on one line.
private func scanSelectorTail(from: Int, in bytes: [UInt8]) -> Bool {
    var j = from
    while j < bytes.count, isIdentifierBody(bytes[j]) || bytes[j] == UInt8(ascii: "-") { j += 1 }
    while j < bytes.count, isHorizontalSpace(bytes[j]) { j += 1 }
    return j < bytes.count && bytes[j] == UInt8(ascii: "{")
}

/// `[a-zA-Z][\w-]*(?:\s[^<>]*)?/?>` — the tail of an HTML tag.
///
/// The optional attribute run has to start with whitespace: without that,
/// `<stdlib.h>` reads as a tag and a C snippet scores as HTML.
private func scanTagTail(from: Int, in bytes: [UInt8]) -> Bool {
    var j = from
    if j < bytes.count, bytes[j] == UInt8(ascii: "/") { j += 1 }
    guard j < bytes.count, isASCIILetter(bytes[j]) else { return false }
    j += 1
    while j < bytes.count, isIdentifierBody(bytes[j]) || bytes[j] == UInt8(ascii: "-") { j += 1 }
    if j < bytes.count, isHorizontalSpace(bytes[j]) || bytes[j] == UInt8(ascii: "\n") {
        j += 1
        while j < bytes.count, bytes[j] != UInt8(ascii: "<"), bytes[j] != UInt8(ascii: ">") { j += 1 }
    }
    if j < bytes.count, bytes[j] == UInt8(ascii: "/") { j += 1 }
    return j < bytes.count && bytes[j] == UInt8(ascii: ">")
}

private func isASCIILetter(_ b: UInt8) -> Bool {
    (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
}

/// Weigh the scanned signals and pick a winner. Called by `guessLanguage`,
/// which adds the memo in front of it.
func scanGuess(_ code: String) -> LanguageGuess? {
    let counts = scanSignals(code)
    var scores: [CodeLanguage: Int] = [:]

    scores[.html] = 2 * counts.htmlTag + 3 * counts.doctype
    scores[.css] = 2 * counts.cssAtRule + counts.cssSelector + 2 * counts.cssDeclaration
    scores[.python] = 2 * counts.pythonOpener + counts.pythonWord + counts.trailingColon
    scores[.shell] = 5 * counts.shellShebang + counts.shellVariable + counts.shellWord
    scores[.sql] = counts.sqlWord >= 2 ? counts.sqlWord + 1 : 0
    scores[.rust] = 3 * counts.rustFn + 2 * counts.rustLetMut + 2 * counts.rustAttribute
        + counts.rustWord + counts.scopeOperator
    scores[.go] = 3 * counts.goPackage + 2 * counts.goAssign + counts.goFunc
        + 2 * counts.goImportGroup

    let cppOnly = counts.cppNamespaced + counts.cppWord + counts.cppAccessLabel
    let cBase = 2 * counts.cInclude + counts.cMain + counts.cWord
    if cBase + cppOnly > 0 {
        if cppOnly > 0 { scores[.cpp] = cBase + cppOnly + 1 } else { scores[.c] = cBase }
    }

    scores[.swift] = counts.swiftWord + 3 * counts.swiftFuncArrow + counts.returnArrow
        + counts.annotation + counts.swiftTypeDecl

    scores[.kotlin] = 3 * counts.kotlinFun + 2 * counts.kotlinVal
        + 2 * counts.kotlinDataClass + 2 * counts.kotlinWhen
        + 2 * counts.kotlinSuspendFun + 2 * counts.kotlinExtensionFun
        + 2 * counts.kotlinPackageDotted
        + counts.kotlinItReceiver + counts.kotlinWord

    scores[.csharp] = 4 * counts.csharpUsing + 3 * counts.csharpConsole
        + 3 * counts.csharpProperty + 2 * counts.csharpPublicType
        + 2 * counts.csharpAsyncTask + 2 * counts.csharpSwitchExpression
        + 2 * counts.csharpForeach + 2 * counts.csharpMain
        + counts.csharpVerbatimString + counts.csharpWord

    // `package com.example;` is weighted above the rest because no other
    // supported language writes it — C# has no `package` at all, Kotlin omits
    // the semicolon, Go takes a bare name. It has to outrun `public class`,
    // which Java and C# share.
    scores[.java] = 4 * counts.javaPackage + 3 * counts.javaSystemOut
        + 3 * counts.javaMain + 3 * counts.javaImport
        + 2 * counts.javaOverride + counts.javaArrayDecl + counts.javaWord

    // PHP shares the `$` sigil with shell, which scores a point per variable,
    // so PHP's structural signals are weighted to carry a snippet that has no
    // opening tag but plenty of variables.
    scores[.php] = 4 * counts.phpOpenTag + 3 * counts.phpThisArrow
        + 3 * counts.phpVisibilityFunction + 3 * counts.phpFunctionDollarParam
        + 3 * counts.phpForeachAs + 3 * counts.phpUseBackslash
        + 2 * counts.phpSuperglobal + 2 * counts.phpStrongWord
        + 2 * counts.phpAssignment + counts.phpVariable + counts.phpWord

    // A lone uppercase `FROM` at the start of a line is more likely SQL's than
    // a Dockerfile's; a Dockerfile always pairs it with other instructions.
    let dockerFrom = counts.dockerInstruction > 0 ? counts.dockerFrom : 0
    scores[.dockerfile] = 4 * dockerFrom + 2 * counts.dockerInstruction

    if counts.jsonOpening > 0, counts.fatArrow == 0, counts.semicolon == 0, counts.functionWord == 0 {
        scores[.json] = 2 + counts.jsonKey
    }

    let jsBase = counts.fatArrow + counts.jsWord
    let tsExtra = counts.tsWord + counts.tsAnnotation + counts.tsEnum
    if jsBase + tsExtra > 0 {
        if tsExtra > 0 { scores[.typescript] = jsBase + tsExtra + 1 } else { scores[.javascript] = jsBase }
    }

    let ranked = scores.filter { $0.value > 0 }.sorted { $0.value > $1.value }
    guard let best = ranked.first else { return nil }
    let runnerUp = ranked.dropFirst().first?.value ?? 0
    let confident = best.value >= 3 && best.value >= runnerUp + 2
    return LanguageGuess(language: best.key, confident: confident)
}

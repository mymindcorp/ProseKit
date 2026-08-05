import Foundation
import EditorSyntax
import TestHarness

// `explicitLanguage` and `displayName` are tables, and a table is data rather
// than code. Line coverage reports both as well covered once any one alias on
// a line has been tried, so the existing spot-checks in `Detection.swift` —
// two dozen of the sixty-eight aliases — read as complete when two thirds of
// the table has never been evaluated.
//
// So the table is written out here in full. The point isn't the aliases that
// work today; it's that adding a language, or renaming one, can't quietly
// leave a hole. The three structural tests at the bottom are what catch that.

/// Every alias `explicitLanguage` accepts, and what it means.
private let aliases: [(hint: String, language: CodeLanguage)] = [
    ("js", .javascript), ("javascript", .javascript), ("jsx", .javascript),
    ("mjs", .javascript), ("cjs", .javascript), ("node", .javascript),

    ("ts", .typescript), ("tsx", .typescript), ("typescript", .typescript),

    ("css", .css), ("scss", .css), ("less", .css), ("postcss", .css), ("sass", .css),

    ("py", .python), ("python", .python), ("python3", .python),

    ("swift", .swift),

    ("html", .html), ("htm", .html), ("xhtml", .html), ("xml", .html),
    ("svg", .html), ("vue", .html), ("svelte", .html),

    ("json", .json), ("json5", .json), ("jsonc", .json),

    ("sh", .shell), ("bash", .shell), ("zsh", .shell), ("shell", .shell),
    ("shell-session", .shell), ("console", .shell), ("ksh", .shell),

    ("sql", .sql), ("postgres", .sql), ("postgresql", .sql), ("mysql", .sql),
    ("sqlite", .sql), ("plsql", .sql),

    ("rs", .rust), ("rust", .rust),

    ("go", .go), ("golang", .go),

    ("cpp", .cpp), ("c++", .cpp), ("cxx", .cpp), ("cc", .cpp),
    ("hpp", .cpp), ("hxx", .cpp),

    ("c", .c), ("h", .c),

    ("kt", .kotlin), ("kts", .kotlin), ("kotlin", .kotlin),

    ("cs", .csharp), ("c#", .csharp), ("csharp", .csharp), ("dotnet", .csharp),

    ("java", .java), ("jsp", .java),

    ("php", .php), ("php8", .php), ("phtml", .php),

    ("dockerfile", .dockerfile), ("docker", .dockerfile), ("containerfile", .dockerfile),
]

func registerVocabularyTests() {
    // MARK: The table itself

    test("hint: every alias resolves to its language") {
        var wrong: [String] = []
        for (hint, expected) in aliases where explicitLanguage(hint) != expected {
            wrong.append("  \(hint) → \(explicitLanguage(hint).map(String.init(describing:)) ?? "nil")"
                         + ", expected \(expected)")
        }
        try expect(wrong.isEmpty, "\(wrong.count)/\(aliases.count) aliases wrong:\n"
                   + wrong.joined(separator: "\n"))
    }

    test("hint: an alias means one language, not several") {
        // The same spelling appearing under two languages would make the
        // verdict depend on case order. `h` is C's and `hpp` is C++'s; a new
        // entry that collides with either has to be noticed.
        var seen: [String: CodeLanguage] = [:]
        var collisions: [String] = []
        for (hint, language) in aliases {
            if let first = seen[hint], first != language {
                collisions.append("  \(hint): \(first) and \(language)")
            }
            seen[hint] = language
        }
        try expect(collisions.isEmpty, "aliases claimed twice:\n" + collisions.joined(separator: "\n"))
    }

    // MARK: The structural guards
    //
    // These are the reason this file exists. Each one fails when a language is
    // added to the enum and something downstream isn't updated to match.

    test("hint: every language is reachable by name") {
        // The plainest thing a user writes in a fence is the language's own
        // name, so every case must answer to its raw value.
        var unreachable: [String] = []
        for language in CodeLanguage.allCases where explicitLanguage(language.rawValue) != language {
            unreachable.append("  \(language.rawValue)")
        }
        try expect(unreachable.isEmpty,
                   "\(unreachable.count) languages don't answer to their own name — a new case "
                   + "needs a line in explicitLanguage:\n" + unreachable.joined(separator: "\n"))
    }

    test("hint: every language is covered by this file's table") {
        // Guards the test rather than the code: a language added to the enum
        // and to `explicitLanguage`, but not here, would go on being untested
        // while everything above still passed.
        let covered = Set(aliases.map(\.language))
        let missing = CodeLanguage.allCases.filter { !covered.contains($0) }
        try expect(missing.isEmpty,
                   "\(missing.count) languages have no aliases listed here: "
                   + missing.map(\.rawValue).joined(separator: ", "))
    }

    test("displayName: every language has a distinct, non-empty label") {
        // It's what the code-block badge shows. An empty one is a blank badge;
        // two the same makes two languages indistinguishable in the menu.
        var labels: [String: String] = [:]
        var problems: [String] = []
        for language in CodeLanguage.allCases {
            let label = language.displayName
            if label.isEmpty { problems.append("  \(language.rawValue) has no label") }
            if let other = labels[label] {
                problems.append("  \(other) and \(language.rawValue) both show \"\(label)\"")
            }
            labels[label] = language.rawValue
        }
        try expect(problems.isEmpty, problems.joined(separator: "\n"))
    }

    test("displayName: the labels are spelled the way the languages are") {
        // Pinned exactly, because these are read by users and the casing is
        // the whole content: "Csharp" and "Cpp" would be wrong in a way no
        // structural check can see.
        let expected: [CodeLanguage: String] = [
            .javascript: "JavaScript", .typescript: "TypeScript", .css: "CSS",
            .python: "Python", .swift: "Swift", .html: "HTML", .json: "JSON",
            .shell: "Shell", .sql: "SQL", .rust: "Rust", .go: "Go",
            .cpp: "C++", .c: "C", .kotlin: "Kotlin", .csharp: "C#",
            .java: "Java", .php: "PHP", .dockerfile: "Dockerfile",
        ]
        for language in CodeLanguage.allCases {
            try expectEqual(language.displayName, expected[language] ?? "",
                            "wrong label for \(language.rawValue)")
        }
    }

    // MARK: How a hint is read

    test("hint: case and surrounding spaces don't matter") {
        for hint in ["swift", "Swift", "SWIFT", "sWiFt", " swift", "swift ",
                     "  swift  ", "\tswift", "swift\t"] {
            try expectEqual(explicitLanguage(hint), .swift, "failed on \(hint.debugDescription)")
        }
    }

    test("hint: nothing to go on gives nothing back") {
        for hint in [nil, "", " ", "   ", "\t"] as [String?] {
            try expect(explicitLanguage(hint) == nil,
                       "expected nil for \(hint.debugDescription)")
        }
    }

    test("hint: a trailing newline is not trimmed") {
        // Recorded, not endorsed. `explicitLanguage` trims `.whitespaces`,
        // which by definition excludes newlines, so a hint that ends in one
        // resolves to nothing and the block renders plain.
        //
        // Nothing in tree delivers such a hint any more: the Markdown parser
        // splits the fence info on `isWhitespace`, and the HTML parser now
        // splits the class attribute the same way — it used to split on a
        // literal space, which is how this was found. Pinned so that if a
        // third source of hints ever appears, the sharp edge is already
        // written down.
        try expectNil(explicitLanguage("swift\n"))
        try expectNil(explicitLanguage("\nswift"))
    }

    test("hint: an info string with more than a language is not one") {
        // A fence can carry attributes after the language. Whoever passes the
        // hint is expected to have taken the first word; the whole string is
        // not a language and must not be guessed at.
        for hint in ["swift title=\"x\"", "js;", "python{.numberLines}", "c++ 17"] {
            try expect(explicitLanguage(hint) == nil,
                       "expected nil for \(hint.debugDescription)")
        }
    }

    test("hint: a language we don't highlight is nil, not a near miss") {
        // The failure that would matter: answering `.c` for "csv" or `.rust`
        // for "rs-something" would colour a block by the wrong grammar, which
        // looks like a bug in the highlighter rather than a missing language.
        let unsupported = ["ruby", "rb", "perl", "lua", "scala", "dart", "elixir",
                           "haskell", "erlang", "clojure", "ocaml", "fsharp", "objc",
                           "yaml", "yml", "toml", "ini", "csv", "makefile", "cmake",
                           "diff", "patch", "text", "plaintext", "md", "markdown",
                           "tex", "latex", "graphql", "proto", "r", "matlab", "vim",
                           "asm", "brainfuck", "", "language", "code"]
        var surprises: [String] = []
        for hint in unsupported {
            if let got = explicitLanguage(hint) { surprises.append("  \(hint) → \(got)") }
        }
        try expect(surprises.isEmpty,
                   "unsupported hints resolved to something:\n" + surprises.joined(separator: "\n"))
    }

    // MARK: What the hint does to detection

    test("detect: an unrecognized hint doesn't suppress the content guess") {
        // Writing ```ruby on a block of Python should still highlight as
        // Python rather than render plain: the hint named nothing this
        // highlighter knows, so it carries no information to respect.
        let python = "def f(x):\n    return x\n\nclass A:\n    pass\n"
        try expectEqual(guessLanguage(python)?.language, .python, "the sample must be detectable")
        try expectEqual(detectCodeLanguage(python, hint: "ruby"), .python)
        try expectEqual(detectCodeLanguage(python, hint: ""), .python)
        try expectEqual(detectCodeLanguage(python, hint: nil), .python)
    }

    test("detect: a recognized hint is respected even against the content") {
        // The other side of the same rule: an author who wrote the language
        // down has said something, and a content guess must not overrule it.
        let python = "def f(x):\n    return x\n"
        try expectEqual(detectCodeLanguage(python, hint: "rust"), .rust)
        try expectEqual(detectCodeLanguage(python, hint: "  RUST  "), .rust)
    }

    test("detect: every language can be named into place") {
        // Whatever the content, naming a language must select it — the path a
        // language picker takes. Content that resembles nothing keeps this
        // about the hint.
        for language in CodeLanguage.allCases {
            try expectEqual(detectCodeLanguage("...", hint: language.rawValue), language)
        }
    }
}

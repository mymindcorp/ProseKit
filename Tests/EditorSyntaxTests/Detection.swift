import Foundation
import EditorSyntax
import TestHarness

// How a code block's language gets resolved: the explicit hint's aliases, and
// the content guess that runs when there is no hint. These pin the individual
// verdicts that the corpus only measures in aggregate — the pairs of languages
// that share a keyword, and the shapes that tell them apart.

func registerDetectionTests() {
    test("hint: aliases resolve to their language") {
        try expectEqual(explicitLanguage("js"), .javascript)
        try expectEqual(explicitLanguage("TSX"), .typescript)
        try expectEqual(explicitLanguage("scss"), .css)
        try expectEqual(explicitLanguage("py"), .python)
        try expectEqual(explicitLanguage("Swift"), .swift)
        try expectEqual(explicitLanguage("svg"), .html)
        try expectEqual(explicitLanguage("json5"), .json)
        try expectEqual(explicitLanguage("bash"), .shell)
        try expectEqual(explicitLanguage("zsh"), .shell)
        try expectEqual(explicitLanguage("postgresql"), .sql)
        try expectEqual(explicitLanguage("rs"), .rust)
        try expectEqual(explicitLanguage("golang"), .go)
        try expectEqual(explicitLanguage("c++"), .cpp)
        try expectEqual(explicitLanguage("c"), .c)
        try expectEqual(explicitLanguage("kt"), .kotlin)
        try expectEqual(explicitLanguage("kts"), .kotlin)
        try expectEqual(explicitLanguage("Kotlin"), .kotlin)
        try expectEqual(explicitLanguage("cs"), .csharp)
        try expectEqual(explicitLanguage("c#"), .csharp)
        try expectEqual(explicitLanguage("csharp"), .csharp)
        try expectEqual(explicitLanguage("java"), .java)
        try expectEqual(explicitLanguage("php"), .php)
        try expectEqual(explicitLanguage("Dockerfile"), .dockerfile)
        try expectEqual(explicitLanguage("docker"), .dockerfile)
        try expectNil(explicitLanguage("brainfuck"))
        try expectNil(explicitLanguage(nil))
    }

    test("detect: each language from content alone") {
        try expectEqual(detectCodeLanguage("const x = () => { console.log(x) }", hint: nil), .javascript)
        try expectEqual(detectCodeLanguage("interface A { x: number }", hint: nil), .typescript)
        try expectEqual(detectCodeLanguage(".btn { color: red; padding: 4px; }", hint: nil), .css)
        try expectEqual(detectCodeLanguage("def f(x):\n    return x\n", hint: nil), .python)
        try expectEqual(detectCodeLanguage("func greet() -> String { return \"hi\" }", hint: nil), .swift)
        try expectEqual(detectCodeLanguage("<div class=\"a\">hi</div>", hint: nil), .html)
        try expectEqual(detectCodeLanguage("{ \"a\": 1, \"b\": [2, 3] }", hint: nil), .json)
        try expectEqual(detectCodeLanguage("#!/bin/bash\nif true; then echo x; fi", hint: nil), .shell)
        try expectEqual(detectCodeLanguage("SELECT id FROM users WHERE id = 1", hint: nil), .sql)
        try expectEqual(detectCodeLanguage("fn main() { let mut x = 1; }", hint: nil), .rust)
        try expectEqual(detectCodeLanguage("package main\nfunc main() {}", hint: nil), .go)
        try expectEqual(detectCodeLanguage("#include <iostream>\nint main() { std::cout << 1; }", hint: nil), .cpp)
        try expectEqual(detectCodeLanguage("#include <stdio.h>\nint main() { printf(\"hi\"); }", hint: nil), .c)
        try expectEqual(detectCodeLanguage("fun main() { val names = listOf(\"a\") }", hint: nil), .kotlin)
        try expectEqual(
            detectCodeLanguage("using System;\nclass P { static void Main() { Console.WriteLine(1); } }",
                               hint: nil), .csharp)
    }

    /// Four of the supported languages write generics, and `Result<T>` used to
    /// score as an HTML tag. A tag's `<` never follows an identifier character;
    /// a generic's always does.
    test("detect: generics are not read as HTML tags") {
        let generics = "type Result<T> = { ok: true; value: T }\n"
            + "function unwrap<T>(result: Result<T>): T { return result.value }"
        try expect(detectCodeLanguage(generics, hint: nil) != .html)
        // Java's generics likewise, and here the real language wins outright.
        try expectEqual(
            detectCodeLanguage("import java.util.List;\nList<String> names = new ArrayList<>();",
                               hint: nil), .java)
        // Real markup still reads as markup — including a closing tag that does
        // follow content, which is why `</` is exempt.
        try expectEqual(
            detectCodeLanguage("<div class=\"card\">\n  <span>Report</span>\n</div>", hint: nil), .html)
    }

    /// PHP and shell both sigil their variables with `$`, so a PHP snippet with
    /// no opening tag is competing with shell on every line.
    test("detect: PHP is not confused with shell") {
        try expectEqual(
            detectCodeLanguage("$totals = [];\nforeach ($orders as $order) {\n"
                               + "    $totals[] = $order->amount;\n}", hint: nil), .php)
        try expectEqual(detectCodeLanguage("<?php\n$name = \"Ada\";", hint: nil), .php)
        // Shell keeps its own: `$1` isn't a valid PHP identifier, and `x=1`
        // assigns without a sigil.
        try expectEqual(detectCodeLanguage("#!/bin/bash\nif true; then echo x; fi", hint: nil), .shell)
        try expectEqual(
            detectCodeLanguage("case \"$1\" in\n  start) echo \"starting\" ;;\n"
                               + "  *) echo \"usage: $0 {start|stop}\" ;;\nesac", hint: nil), .shell)
    }

    /// A Dockerfile's `FROM` and SQL's are the same word in the same place.
    test("detect: Dockerfile is not confused with SQL") {
        try expectEqual(detectCodeLanguage("FROM node:20-alpine\nWORKDIR /app\nRUN npm ci", hint: nil),
                        .dockerfile)
        try expectEqual(detectCodeLanguage("SELECT id, name\nFROM users\nWHERE active = true;", hint: nil),
                        .sql)
    }

    /// Three languages open a file with `package …`. The path is what separates
    /// them: Go takes a bare name, Java and Kotlin take a dotted one, and only
    /// Java ends it with a semicolon.
    test("detect: the package header tells Java, Kotlin and Go apart") {
        try expectEqual(detectCodeLanguage("package com.example;\n\npublic class User { }", hint: nil),
                        .java)
        try expectEqual(detectCodeLanguage("package com.example\n\ndata class User(val id: Int)", hint: nil),
                        .kotlin)
        try expectEqual(detectCodeLanguage("package main\nfunc main() {}", hint: nil), .go)
    }

    /// Java's entry point and C#'s differ only in the case of `Main`, and both
    /// sit behind `public class`.
    test("detect: Java is not confused with C#") {
        try expectEqual(
            detectCodeLanguage("public class Main {\n  public static void main(String[] args) {\n"
                               + "    System.out.println(\"hi\");\n  }\n}", hint: nil), .java)
        try expectEqual(
            detectCodeLanguage("using System;\nclass P { static void Main() { Console.WriteLine(1); } }",
                               hint: nil), .csharp)
    }

    /// C# shares `namespace`, `interface`, `readonly` and `var` with TypeScript,
    /// and `using` with C++. The signals that separate them are shapes, not
    /// words, so pin the ones that would collide.
    test("detect: C# is not confused with TypeScript or C++") {
        try expectEqual(detectCodeLanguage("using System;\npublic interface IRepo { }", hint: nil), .csharp)
        try expectEqual(detectCodeLanguage("public class User { public int Id { get; set; } }", hint: nil),
                        .csharp)
        // C++'s `using namespace std;` starts lowercase, so it isn't a C# using.
        try expectEqual(detectCodeLanguage("#include <iostream>\nusing namespace std;\nint main() { std::cout << 1; }",
                                           hint: nil), .cpp)
        // And a TypeScript interface stays TypeScript.
        try expectEqual(detectCodeLanguage("interface A { x: number }", hint: nil), .typescript)
    }

    /// Kotlin's `fun`/`val` must not be read as Swift's `func`/`let`, and
    /// Kotlin's leading `package` must not read as Go.
    test("detect: Kotlin is not confused with Swift or Go") {
        try expectEqual(detectCodeLanguage("fun greet(name: String) = \"hi $name\"", hint: nil), .kotlin)
        try expectEqual(detectCodeLanguage("package com.example\n\ndata class User(val id: Int)", hint: nil),
                        .kotlin)
        // And the reverse: Swift and Go keep their own snippets.
        try expectEqual(detectCodeLanguage("func greet() -> String { return \"hi\" }", hint: nil), .swift)
        try expectEqual(detectCodeLanguage("package main\nfunc main() {}", hint: nil), .go)
    }

    test("detect: ambiguous text is not detected confidently") {
        // A bare token isn't enough to switch.
        try expectNil(detectCodeLanguage("x = 1", hint: nil))
        try expectNil(detectCodeLanguage("hello world", hint: nil))
    }

    test("detect: an explicit hint always wins") {
        try expectEqual(detectCodeLanguage("x = 1", hint: "rust"), .rust)
        try expectEqual(detectCodeLanguage(".btn { a: b; }", hint: "javascript"), .javascript)
    }

    /// The memo in `guessLanguage` must be invisible: a repeat guess agrees with
    /// the first, and distinct sources keep distinct answers once it has evicted.
    test("detect: the guess memo doesn't change any verdict") {
        let samples: [(String, CodeLanguage?)] = [
            ("const x = () => { console.log(x) }", .javascript),
            ("interface A { x: number }", .typescript),
            (".btn { color: red; padding: 4px; }", .css),
            ("def f(x):\n    return x", .python),
            ("fn main() { let mut v = Vec::new(); }", .rust),
            ("package main\nfunc main() { x := 1 }", .go),
            ("#include <stdio.h>\nint main() { printf(\"hi\"); }", .c),
            ("guard let x else { return }\nfunc f() -> Int { 0 }", .swift),
            ("{ \"a\": 1, \"b\": [2, 3] }", .json),
            ("#!/bin/bash\nfor f in *; do echo $f; done", .shell),
        ]
        // First pass populates and overflows the memo (10 samples, 8 slots).
        let first = samples.map { guessLanguage($0.0)?.language }
        // Second pass: the early ones have been evicted and are recomputed, the
        // late ones are served from the memo. Both must match the first pass.
        let second = samples.map { guessLanguage($0.0)?.language }
        try expectEqual(first, second, "a repeat guess disagreed with the first")
        try expectEqual(first, samples.map(\.1), "detection changed")

        // Interleaving must not let one block's answer leak into another's.
        for (code, expected) in samples {
            try expectEqual(guessLanguage(code)?.language, expected, "wrong guess for: \(code)")
            try expectNil(guessLanguage("   ")?.language)
        }
    }
}

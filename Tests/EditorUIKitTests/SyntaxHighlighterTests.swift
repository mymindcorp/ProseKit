#if canImport(UIKit)
import XCTest
import UIKit
@testable import EditorSyntax
@testable import EditorUIKit

@MainActor
final class SyntaxHighlighterTests: XCTestCase {
    private let hl = makeSyntaxHighlighter()

    /// The token (if any) covering the first occurrence of `substring`.
    private func color(of substring: String, in code: String, language: String?) -> UIColor? {
        let tokens = hl(code, language)
        guard let r = code.range(of: substring) else { return nil }
        let lo = code.distance(from: code.startIndex, to: r.lowerBound)
        return tokens.first { $0.range.contains(lo) }?.color
    }

    // MARK: aliases

    func testExplicitLanguageAliases() {
        XCTAssertEqual(explicitLanguage("js"), .javascript)
        XCTAssertEqual(explicitLanguage("TSX"), .typescript)
        XCTAssertEqual(explicitLanguage("scss"), .css)
        XCTAssertEqual(explicitLanguage("py"), .python)
        XCTAssertEqual(explicitLanguage("Swift"), .swift)
        XCTAssertEqual(explicitLanguage("svg"), .html)
        XCTAssertEqual(explicitLanguage("json5"), .json)
        XCTAssertEqual(explicitLanguage("bash"), .shell)
        XCTAssertEqual(explicitLanguage("zsh"), .shell)
        XCTAssertEqual(explicitLanguage("postgresql"), .sql)
        XCTAssertEqual(explicitLanguage("rs"), .rust)
        XCTAssertEqual(explicitLanguage("golang"), .go)
        XCTAssertEqual(explicitLanguage("c++"), .cpp)
        XCTAssertEqual(explicitLanguage("c"), .c)
        XCTAssertEqual(explicitLanguage("kt"), .kotlin)
        XCTAssertEqual(explicitLanguage("kts"), .kotlin)
        XCTAssertEqual(explicitLanguage("Kotlin"), .kotlin)
        XCTAssertEqual(explicitLanguage("cs"), .csharp)
        XCTAssertEqual(explicitLanguage("c#"), .csharp)
        XCTAssertEqual(explicitLanguage("csharp"), .csharp)
        XCTAssertEqual(explicitLanguage("java"), .java)
        XCTAssertEqual(explicitLanguage("php"), .php)
        XCTAssertEqual(explicitLanguage("Dockerfile"), .dockerfile)
        XCTAssertEqual(explicitLanguage("docker"), .dockerfile)
        XCTAssertNil(explicitLanguage("brainfuck"))
        XCTAssertNil(explicitLanguage(nil))
    }

    // MARK: confident content detection

    func testConfidentDetection() {
        XCTAssertEqual(detectCodeLanguage("const x = () => { console.log(x) }", hint: nil), .javascript)
        XCTAssertEqual(detectCodeLanguage("interface A { x: number }", hint: nil), .typescript)
        XCTAssertEqual(detectCodeLanguage(".btn { color: red; padding: 4px; }", hint: nil), .css)
        XCTAssertEqual(detectCodeLanguage("def f(x):\n    return x\n", hint: nil), .python)
        XCTAssertEqual(detectCodeLanguage("func greet() -> String { return \"hi\" }", hint: nil), .swift)
        XCTAssertEqual(detectCodeLanguage("<div class=\"a\">hi</div>", hint: nil), .html)
        XCTAssertEqual(detectCodeLanguage("{ \"a\": 1, \"b\": [2, 3] }", hint: nil), .json)
        XCTAssertEqual(detectCodeLanguage("#!/bin/bash\nif true; then echo x; fi", hint: nil), .shell)
        XCTAssertEqual(detectCodeLanguage("SELECT id FROM users WHERE id = 1", hint: nil), .sql)
        XCTAssertEqual(detectCodeLanguage("fn main() { let mut x = 1; }", hint: nil), .rust)
        XCTAssertEqual(detectCodeLanguage("package main\nfunc main() {}", hint: nil), .go)
        XCTAssertEqual(detectCodeLanguage("#include <iostream>\nint main() { std::cout << 1; }", hint: nil), .cpp)
        XCTAssertEqual(detectCodeLanguage("#include <stdio.h>\nint main() { printf(\"hi\"); }", hint: nil), .c)
        XCTAssertEqual(detectCodeLanguage("fun main() { val names = listOf(\"a\") }", hint: nil), .kotlin)
        XCTAssertEqual(
            detectCodeLanguage("using System;\nclass P { static void Main() { Console.WriteLine(1); } }",
                               hint: nil), .csharp)
    }

    /// Four of the supported languages write generics, and `Result<T>` used to
    /// score as an HTML tag. A tag's `<` never follows an identifier character;
    /// a generic's always does.
    func testGenericsAreNotReadAsHtmlTags() {
        let generics = "type Result<T> = { ok: true; value: T }\n"
            + "function unwrap<T>(result: Result<T>): T { return result.value }"
        XCTAssertNotEqual(detectCodeLanguage(generics, hint: nil), .html)
        // Java's generics likewise, and here the real language wins outright.
        XCTAssertEqual(
            detectCodeLanguage("import java.util.List;\nList<String> names = new ArrayList<>();",
                               hint: nil), .java)
        // Real markup still reads as markup — including a closing tag that does
        // follow content, which is why `</` is exempt.
        XCTAssertEqual(
            detectCodeLanguage("<div class=\"card\">\n  <span>Report</span>\n</div>", hint: nil), .html)
    }

    /// PHP and shell both sigil their variables with `$`, so a PHP snippet with
    /// no opening tag is competing with shell on every line.
    func testPhpIsNotConfusedWithShell() {
        XCTAssertEqual(
            detectCodeLanguage("$totals = [];\nforeach ($orders as $order) {\n"
                               + "    $totals[] = $order->amount;\n}", hint: nil), .php)
        XCTAssertEqual(detectCodeLanguage("<?php\n$name = \"Ada\";", hint: nil), .php)
        // Shell keeps its own: `$1` isn't a valid PHP identifier, and `x=1`
        // assigns without a sigil.
        XCTAssertEqual(detectCodeLanguage("#!/bin/bash\nif true; then echo x; fi", hint: nil), .shell)
        XCTAssertEqual(
            detectCodeLanguage("case \"$1\" in\n  start) echo \"starting\" ;;\n"
                               + "  *) echo \"usage: $0 {start|stop}\" ;;\nesac", hint: nil), .shell)
    }

    /// A Dockerfile's `FROM` and SQL's are the same word in the same place.
    func testDockerfileIsNotConfusedWithSql() {
        XCTAssertEqual(detectCodeLanguage("FROM node:20-alpine\nWORKDIR /app\nRUN npm ci", hint: nil),
                       .dockerfile)
        XCTAssertEqual(detectCodeLanguage("SELECT id, name\nFROM users\nWHERE active = true;", hint: nil),
                       .sql)
    }

    /// Three languages open a file with `package …`. The path is what separates
    /// them: Go takes a bare name, Java and Kotlin take a dotted one, and only
    /// Java ends it with a semicolon.
    func testPackageHeaderTellsJavaKotlinAndGoApart() {
        XCTAssertEqual(detectCodeLanguage("package com.example;\n\npublic class User { }", hint: nil),
                       .java)
        XCTAssertEqual(detectCodeLanguage("package com.example\n\ndata class User(val id: Int)", hint: nil),
                       .kotlin)
        XCTAssertEqual(detectCodeLanguage("package main\nfunc main() {}", hint: nil), .go)
    }

    /// Java's entry point and C#'s differ only in the case of `Main`, and both
    /// sit behind `public class`.
    func testJavaIsNotConfusedWithCSharp() {
        XCTAssertEqual(
            detectCodeLanguage("public class Main {\n  public static void main(String[] args) {\n"
                               + "    System.out.println(\"hi\");\n  }\n}", hint: nil), .java)
        XCTAssertEqual(
            detectCodeLanguage("using System;\nclass P { static void Main() { Console.WriteLine(1); } }",
                               hint: nil), .csharp)
    }

    /// C# shares `namespace`, `interface`, `readonly` and `var` with TypeScript,
    /// and `using` with C++. The signals that separate them are shapes, not
    /// words, so pin the ones that would collide.
    func testCSharpIsNotConfusedWithTypeScriptOrCpp() {
        XCTAssertEqual(detectCodeLanguage("using System;\npublic interface IRepo { }", hint: nil), .csharp)
        XCTAssertEqual(detectCodeLanguage("public class User { public int Id { get; set; } }", hint: nil),
                       .csharp)
        // C++'s `using namespace std;` starts lowercase, so it isn't a C# using.
        XCTAssertEqual(detectCodeLanguage("#include <iostream>\nusing namespace std;\nint main() { std::cout << 1; }",
                                          hint: nil), .cpp)
        // And a TypeScript interface stays TypeScript.
        XCTAssertEqual(detectCodeLanguage("interface A { x: number }", hint: nil), .typescript)
    }

    /// Kotlin's `fun`/`val` must not be read as Swift's `func`/`let`, and
    /// Kotlin's leading `package` must not read as Go.
    func testKotlinIsNotConfusedWithSwiftOrGo() {
        XCTAssertEqual(detectCodeLanguage("fun greet(name: String) = \"hi $name\"", hint: nil), .kotlin)
        XCTAssertEqual(detectCodeLanguage("package com.example\n\ndata class User(val id: Int)", hint: nil),
                       .kotlin)
        // And the reverse: Swift and Go keep their own snippets.
        XCTAssertEqual(detectCodeLanguage("func greet() -> String { return \"hi\" }", hint: nil), .swift)
        XCTAssertEqual(detectCodeLanguage("package main\nfunc main() {}", hint: nil), .go)
    }

    func testAmbiguousIsNotConfident() {
        // A bare token isn't enough to switch.
        XCTAssertNil(detectCodeLanguage("x = 1", hint: nil))
        XCTAssertNil(detectCodeLanguage("hello world", hint: nil))
    }

    func testExplicitHintAlwaysWins() {
        XCTAssertEqual(detectCodeLanguage("x = 1", hint: "rust"), .rust)
        XCTAssertEqual(detectCodeLanguage(".btn { a: b; }", hint: "javascript"), .javascript)
    }

    // MARK: tokenizing (per language, via explicit hint)

    func testTypeScriptColorsBuiltinAndUserTypes() {
        let code = "function id(x: number): User { return x }"
        XCTAssertEqual(color(of: "function", in: code, language: "ts"), SyntaxColors.default.keyword)
        XCTAssertEqual(color(of: "number", in: code, language: "ts"), SyntaxColors.default.property)
        XCTAssertEqual(color(of: "User", in: code, language: "ts"), SyntaxColors.default.property)
    }

    func testKeywordInsideStringStaysString() {
        let code = "let s = \"const\""
        XCTAssertEqual(color(of: "\"const\"", in: code, language: "js"), SyntaxColors.default.string)
    }

    func testEachLanguageColorsItsKeyword() {
        let cases: [(String, String, String)] = [
            ("js", "function f() {}", "function"),
            ("ts", "interface A {}", "interface"),
            ("css", ".x { color: red; }", "color"),       // property color, not keyword
            ("py", "def f(): pass", "def"),
            ("swift", "func f() {}", "func"),
            ("json", "{ \"k\": true }", "true"),
            ("bash", "if x; then echo 1; fi", "then"),
            ("sql", "SELECT 1", "SELECT"),
            ("rust", "fn main() {}", "fn"),
            ("go", "func main() {}", "func"),
            ("cpp", "int main() {}", "int"),
            ("c", "int main() {}", "int"),
            ("html", "<a>x</a>", "<a"),
            ("kotlin", "fun main() {}", "fun"),
            ("kt", "val x = 1", "val"),
            ("csharp", "class Program {}", "class"),
            ("cs", "using System;", "using"),
            ("java", "public class Main {}", "class"),
            ("php", "<?php function f() {}", "function"),
            ("dockerfile", "FROM node:20", "FROM"),
        ]
        for (lang, code, token) in cases {
            let c = color(of: token, in: code, language: lang)
            XCTAssertNotNil(c, "\(lang): '\(token)' should be tokenized in \(code)")
        }
    }

    // MARK: configuration

    func testDisabledLanguageRendersPlain() {
        let onlyJS = makeSyntaxHighlighter(languages: [.javascript])
        XCTAssertTrue(onlyJS(".x { color: red; }", "css").isEmpty)
        XCTAssertFalse(onlyJS("const x = 1", "js").isEmpty)
    }

    func testDetectByContentOffRequiresHint() {
        let strict = makeSyntaxHighlighter(detectByContent: false)
        XCTAssertTrue(strict("const x = () => { console.log(1) }", nil).isEmpty)
        XCTAssertFalse(strict("const x = 1", "js").isEmpty)
    }

    func testCustomColors() {
        var colors = SyntaxColors.default
        colors.keyword = .systemGreen
        let green = makeSyntaxHighlighter(colors: colors)
        XCTAssertTrue(green("const x = 1", "js").contains { $0.color == .systemGreen })
    }

    // MARK: badge label

    func testBadgeLabelFromExplicitLanguage() {
        let label = makeCodeLanguageLabel()
        XCTAssertEqual(label("whatever", "swift"), "Swift")
        XCTAssertEqual(label("whatever", "c++"), "C++")
    }

    func testBadgeLabelFromConfidentDetection() {
        let label = makeCodeLanguageLabel()
        XCTAssertEqual(label("SELECT id FROM t WHERE id = 1", nil), "SQL")
        XCTAssertNil(label("x = 1", nil), "ambiguous → no badge")
    }
}
#endif

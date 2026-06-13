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

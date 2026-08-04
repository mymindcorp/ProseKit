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

    // Language *detection* (hint aliases + content guessing) is Foundation-only
    // and lives in the headless `EditorSyntaxTests` suite. What's left here is
    // what genuinely needs UIKit: the tokenizer's colours and the badge label.

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

#if canImport(UIKit)
import XCTest
import UIKit
@testable import EditorSyntax
@testable import EditorUIKit

/// Tokenizing TypeScript.
///
/// The grammar's rule *order* is as much of the behaviour as the patterns:
/// comments and strings are matched first so their contents aren't re-coloured
/// as keywords, and built-in type names are matched before the general
/// capitalized-identifier rule. Most of what follows pins that ordering.
@MainActor
final class TypeScriptSyntaxTests: XCTestCase {
    private let hl = makeSyntaxHighlighter()
    private let colors = SyntaxColors.default

    /// The colour of the token covering `substring` (the `occurrence`-th one,
    /// 0-based), or nil when nothing claims that range.
    private func color(of substring: String, occurrence: Int = 0, in code: String) -> UIColor? {
        let tokens = hl(code, "ts")
        var searchStart = code.startIndex
        var found: Range<String.Index>?
        for _ in 0...occurrence {
            guard let r = code.range(of: substring, range: searchStart ..< code.endIndex) else { return nil }
            found = r
            searchStart = r.upperBound
        }
        guard let found else { return nil }
        let lo = code.distance(from: code.startIndex, to: found.lowerBound)
        return tokens.first { $0.range.contains(lo) }?.color
    }

    // MARK: keywords

    func testTypeScriptOnlyKeywords() {
        // The tokens that separate TS from the JavaScript grammar.
        let cases = [
            ("interface Shape {}", "interface"),
            ("type Id = string", "type"),
            ("enum Level { Debug }", "enum"),
            ("namespace Config {}", "namespace"),
            ("declare const VERSION: string", "declare"),
            ("class A { readonly x = 1 }", "readonly"),
            ("class A implements B {}", "implements"),
            ("abstract class A {}", "abstract"),
            ("type K = keyof Shape", "keyof"),
            ("const a = b satisfies C", "satisfies"),
            ("class A { override f() {} }", "override"),
            ("class A { private x = 1 }", "private"),
            ("class A { protected y = 2 }", "protected"),
            // `f` rather than `isCat`, so the first "is" in the snippet is the
            // type-predicate keyword and not a substring of the function name.
            ("function f(a: unknown): a is Cat { return true }", "is"),
        ]
        for (code, token) in cases {
            XCTAssertEqual(color(of: token, in: code), colors.keyword,
                           "\(token) should be a keyword in: \(code)")
        }
    }

    // MARK: types

    func testBuiltinTypeNamesAreColoredAsTypes() {
        let code = "function f(a: string, b: number, c: boolean, d: any): void {}"
        for name in ["string", "number", "boolean", "any", "void"] {
            XCTAssertEqual(color(of: name, in: code), colors.property, "\(name) should read as a type")
        }
    }

    func testRarerBuiltinTypeNames() {
        let code = "type T = never | unknown | object | symbol | bigint"
        for name in ["never", "unknown", "object", "symbol", "bigint"] {
            XCTAssertEqual(color(of: name, in: code), colors.property, "\(name) should read as a type")
        }
    }

    func testUserTypesAndGenericsAreColored() {
        let code = "function unwrap<T>(result: Result<T>): User { return result.value }"
        XCTAssertEqual(color(of: "Result", in: code), colors.property)
        XCTAssertEqual(color(of: "User", in: code), colors.property)
        XCTAssertEqual(color(of: "T", in: code), colors.property, "a bare type parameter is still a type")
    }

    // MARK: comments and strings win over keywords

    func testKeywordsInsideCommentsStayComments() {
        let line = "// interface Shape { x: number }"
        XCTAssertEqual(color(of: "interface", in: line), colors.comment)
        XCTAssertEqual(color(of: "number", in: line), colors.comment)

        let block = "/* declare const x: string */ const y = 1"
        XCTAssertEqual(color(of: "declare", in: block), colors.comment)
        XCTAssertEqual(color(of: "string", in: block), colors.comment)
        // …and the code after the block comment is still tokenized.
        XCTAssertEqual(color(of: "const", occurrence: 1, in: block), colors.keyword)
    }

    func testKeywordsInsideStringsStayStrings() {
        XCTAssertEqual(color(of: "interface", in: "const a = \"interface\""), colors.string)
        XCTAssertEqual(color(of: "readonly", in: "const a = 'readonly'"), colors.string)
        XCTAssertEqual(color(of: "enum", in: "const a = `enum`"), colors.string)
    }

    func testBlockCommentSpansLines() {
        let code = "/*\n interface A {}\n*/\nconst x = 1"
        XCTAssertEqual(color(of: "interface", in: code), colors.comment)
        XCTAssertEqual(color(of: "const", in: code), colors.keyword)
    }

    // MARK: decorators

    func testDecoratorsAreColoredAsAtRules() {
        XCTAssertEqual(color(of: "@Component", in: "@Component\nclass A {}"), colors.atRule)
        // The pattern spans dots, so a qualified decorator is one token.
        XCTAssertEqual(color(of: "@core.Inject", in: "@core.Inject()\nclass A {}"), colors.atRule)
    }

    // MARK: numbers

    func testNumbersAreColored() {
        let code = "const a = 42, b = 3.5"
        XCTAssertEqual(color(of: "42", in: code), colors.number)
        XCTAssertEqual(color(of: "3.5", in: code), colors.number)
    }

    // MARK: known limitations

    /// A regex grammar has no scope information, so a built-in type name used
    /// as an ordinary identifier is still coloured as a type. This documents
    /// current behaviour rather than requiring it — a scope-aware tokenizer
    /// would be free to improve on it.
    func testBuiltinTypeNameUsedAsIdentifierIsStillColoredAsType() {
        XCTAssertEqual(color(of: "object", in: "const object = { a: 1 }"), colors.property)
    }

    /// Likewise, a template literal is one span: interpolations inside it are
    /// not tokenized as code.
    func testTemplateInterpolationIsPartOfTheString() {
        let code = "const greeting = `Hello ${user.name}, you are ${count}`"
        XCTAssertEqual(color(of: "user.name", in: code), colors.string)
        XCTAssertEqual(color(of: "count", in: code), colors.string)
    }

    // MARK: the highlighter contract

    func testTokensAreSortedAndNonOverlapping() {
        let code = """
        // header
        import { Store } from "./store"

        export interface Options {
          readonly retries: number
          onDone?: (id: string) => void
        }

        @injectable()
        export class Runner implements Disposable {
          private count = 0

          async run(options: Options): Promise<void> {
            for (const attempt of [1, 2, 3]) {
              await this.step(attempt)
            }
          }
        }
        """
        let tokens = hl(code, "ts")
        XCTAssertFalse(tokens.isEmpty)
        var previousEnd = 0
        for token in tokens {
            XCTAssertLessThan(token.range.lowerBound, token.range.upperBound, "empty token range")
            XCTAssertGreaterThanOrEqual(token.range.lowerBound, previousEnd,
                                        "tokens must be sorted and must not overlap")
            XCTAssertLessThanOrEqual(token.range.upperBound, code.count, "token runs past the end")
            previousEnd = token.range.upperBound
        }
    }
}
#endif

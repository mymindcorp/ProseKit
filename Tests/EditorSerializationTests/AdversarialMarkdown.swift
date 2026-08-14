import Foundation
import DocumentModel
import EditorSerialization
import TestHarness

// Nested blocks are parsed by recursion, and a nesting marker costs the writer
// one character — so pasted Markdown could run the stack out and take the
// process down. A stack overflow isn't catchable, so the depth has to be
// refused before it is recursed into.

private let limit = MarkdownParser.maxNestingDepth

@Sendable private func nestingError(_ markdown: String) -> MarkdownParseError? {
    do { _ = try MarkdownParser.parse(markdown, schema: schema); return nil }
    catch let error as MarkdownParseError { return error }
    catch { return nil }
}

func registerAdversarialMarkdownTests() {

    test("adversarial markdown: runaway quote nesting is refused, not recursed into") {
        // ~8 KB, which used to be enough to overflow an 8 MB stack.
        try expectEqual(nestingError(String(repeating: "> ", count: 4000) + "hi"),
                        .nestingTooDeep(limit: limit))
    }

    test("adversarial markdown: the refusal doesn't depend on the depth being huge") {
        try expectEqual(nestingError(String(repeating: "> ", count: limit + 2) + "hi"),
                        .nestingTooDeep(limit: limit))
    }

    test("adversarial markdown: runaway list nesting is refused") {
        var md = ""
        for i in 0..<(limit + 4) { md += String(repeating: " ", count: i * 2) + "- x\n" }
        try expectEqual(nestingError(md), .nestingTooDeep(limit: limit))
    }

    test("adversarial markdown: nesting inside a quote counts too") {
        var md = "> "
        for i in 0..<(limit + 4) { md += "\n> " + String(repeating: " ", count: i * 2) + "- x" }
        try expectNotNil(nestingError(md))
    }

    // The limit only has to stop what nobody writes on purpose. A quoted mail
    // thread is the deepest real case and stops far short of it.
    test("adversarial markdown: ordinary nesting still parses") {
        let d = try MarkdownParser.parse(String(repeating: "> ", count: 20) + "hi", schema: schema)
        try d.check()
        try expectEqual(d.textContent, "hi")
    }

    test("adversarial markdown: nesting just under the limit still parses") {
        let d = try MarkdownParser.parse(String(repeating: "> ", count: limit - 2) + "hi", schema: schema)
        try d.check()
        try expectEqual(d.textContent, "hi")
    }

    test("adversarial markdown: a deep document is refused rather than truncated") {
        // Silently dropping the over-deep part would look like a successful
        // parse of a document the source doesn't contain.
        try expectThrows({
            _ = try MarkdownParser.parse(String(repeating: "> ", count: limit * 4) + "hi", schema: schema)
        })
    }
}

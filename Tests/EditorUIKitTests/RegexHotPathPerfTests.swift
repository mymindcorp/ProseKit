#if canImport(UIKit)
import XCTest
import DocumentModel
import EditorInputRules
import EditorStateKit
@testable import EditorSyntax
import SchemaKit
@testable import EditorUIKit

/// What the library's remaining regex paths actually cost, on the paths that
/// run often enough for it to matter.
///
/// Two of them fire per keystroke: the input rules run on every character typed
/// anywhere in the document, and the find bar searches as you type. The third,
/// grammar construction, recompiles a language's patterns on every highlight.
@MainActor
final class RegexHotPathPerfTests: XCTestCase {
    private func bestMs(_ runs: Int = 9, _ body: () -> Void) -> Double {
        var best = Double.infinity
        for _ in 0 ..< runs {
            let t = CFAbsoluteTimeGetCurrent()
            body()
            best = min(best, (CFAbsoluteTimeGetCurrent() - t) * 1000)
        }
        return best
    }

    private func article(_ paragraphs: Int, schema s: Schema) throws -> Node {
        let words = Array(repeating: "lorem ipsum dolor sit amet consectetur", count: 8).joined(separator: " ")
        let children = try (0 ..< paragraphs).map { i in
            try s.node("paragraph", [:], content: Fragment.from([s.text("Para \(i): \(words)")]))
        }
        return try s.node("doc", [:], content: Fragment.from(children))
    }

    /// One keystroke through the input-rules plugin: every rule's pattern is
    /// matched against the text before the cursor, up to MAX_MATCH characters.
    func testInputRulesPerKeystroke() throws {
        let editor = try Editor(extensions: fullKit())
        editor.setContent(try article(200, schema: editor.schema))
        let state = editor.state
        guard let plugin = state.plugins.first(where: { $0.key == inputRulesKey.key }),
              let handler = plugin.props?.handleTextInput else {
            return XCTFail("no input-rules plugin in fullKit")
        }
        // A cursor deep inside a paragraph, so the rules see a full window of
        // preceding text rather than a near-empty one.
        let end = state.doc.child(100).nodeSize
        var pos = 0
        for i in 0 ..< 100 { pos += state.doc.child(i).nodeSize }
        let caret = pos + min(end - 1, 200)

        let ms = bestMs { _ = handler(caret, caret, "a", state, nil) }
        print(unsafe "INPUTRULES keystroke=\(String(format: "%.3f", ms))ms")
        // A keystroke has a 16ms frame to fit in, alongside layout and
        // typesetting. This is a smoke alarm, not a target.
        XCTAssertLessThan(ms, 4.0, "input rules are eating a keystroke's frame budget")
    }

    /// Find-as-you-type: `onQueryChange` fires per keystroke in the find field,
    /// and each one searches the document.
    func testSearchPerQueryKeystroke() throws {
        let editor = try Editor(extensions: fullKit())
        editor.setContent(try article(400, schema: editor.schema))
        let state = editor.state
        // A query that hits in the first paragraph never scans the document, so
        // the no-match cases are the ones that show what a full pass costs —
        // and typing a query prefix that matches nothing is the common case.
        let queries: [(String, SearchQuery)] = [
            ("literal-hit", SearchQuery(search: "consectetur")),
            ("literal-miss", SearchQuery(search: "zzzznotpresent")),
            ("regexp-hit", SearchQuery(search: "co\\w+tur", regexp: true)),
            ("regexp-miss", SearchQuery(search: "zz\\w+qq", regexp: true)),
        ]
        for (label, query) in queries {
            let next = bestMs { _ = query.findNext(state, 0) }
            let prev = bestMs { _ = query.findPrev(state) }
            print(unsafe "SEARCH \(label) findNext=\(String(format: "%.3f", next))ms "
                + "findPrev=\(String(format: "%.3f", prev))ms")
        }
    }

    /// Building a language's rule set compiles its patterns. This happens on
    /// every highlight of a changed block.
    func testGrammarConstruction() {
        for language in [CodeLanguage.javascript, .typescript, .csharp] {
            let ms = bestMs(50) { _ = rules(for: language, .default) }
            print(unsafe "GRAMMAR \(language.rawValue) build=\(String(format: "%.4f", ms))ms")
        }
    }
}
#endif

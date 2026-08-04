#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import SchemaKit
@testable import EditorSyntax
@testable import EditorUIKit

/// The cost of guessing a code block's language from its content.
///
/// A guess scans the whole block once. It runs whenever a block has no explicit
/// `language` attribute — twice per block, in fact, since the highlighter and
/// the language badge each resolve it independently, which is what the memo in
/// `guessLanguage` exists to collapse.
@MainActor
final class SyntaxDetectionPerfTests: XCTestCase {
    /// JavaScript-shaped source of roughly `chars` bytes, deliberately with no
    /// language hint on the block so detection has to run. `seed` makes the
    /// text unique: blocks that share a string would collapse onto one guess
    /// and measure the memo instead of the work.
    private func source(chars: Int, seed: Int = 0) -> String {
        var out = "// block \(seed)\n"
        var i = 0
        while out.utf8.count < chars {
            out += """
                // number \(seed)_\(i)
                const value\(seed)_\(i) = function(alpha, beta) {
                    if (alpha > \(i)) { return "text \(i)" + beta; }
                    return null;
                }

                """
            i += 1
        }
        return out
    }

    private func bestMs(_ runs: Int = 7, _ body: () -> Void) -> Double {
        var best = Double.infinity
        for _ in 0 ..< runs {
            let t = CFAbsoluteTimeGetCurrent()
            body()
            best = min(best, (CFAbsoluteTimeGetCurrent() - t) * 1000)
        }
        return best
    }

    private func doc(_ schema: Schema, blocks: Int, chars: Int) throws -> Node {
        let children = try (0 ..< blocks).map { i in
            try schema.node("codeBlock", [:],
                            content: Fragment.from([schema.text(source(chars: chars, seed: i))]))
        }
        return try schema.node("doc", [:], content: Fragment.from(children))
    }

    // The memo's *correctness* (a repeat guess agreeing with the first) is
    // checked in the headless `EditorSyntaxTests` suite; what's timed here is
    // what it saves.

    /// One guess, in isolation. Every timed run gets its own source so this
    /// measures the guess rather than a repeat lookup.
    func testGuessScaling() {
        for n in [1_000, 4_000, 16_000] {
            var seed = 0
            var chars = 0
            var best = Double.infinity
            for _ in 0 ..< 7 {
                seed += 1
                let code = source(chars: n, seed: seed)
                chars = code.count
                let t = CFAbsoluteTimeGetCurrent()
                _ = guessLanguage(code)
                best = min(best, (CFAbsoluteTimeGetCurrent() - t) * 1000)
            }
            // What the second resolver of the same block pays.
            let code = source(chars: n, seed: seed)
            _ = guessLanguage(code)
            let repeated = bestMs { _ = guessLanguage(code) }
            print(unsafe "GUESS chars=\(chars) first=\(String(format: "%.2f", best))ms "
                + "repeat=\(String(format: "%.3f", repeated))ms")
        }
    }

    /// A cold layout of a document made of unhinted code blocks: every block
    /// pays detection for the highlighter and again for the badge.
    func testColdLayoutWithDetection() throws {
        let editor = try Editor(extensions: fullKit())
        let theme = DocumentTheme()
        let hl = makeSyntaxHighlighter()
        let label = makeCodeLanguageLabel()
        for blocks in [10, 40] {
            let d = try doc(editor.schema, blocks: blocks, chars: 1_000)
            let bare = bestMs(3) { _ = DocumentLayout(doc: d, width: 390, theme: theme) }
            let full = bestMs(3) {
                _ = DocumentLayout(doc: d, width: 390, theme: theme,
                                   syntaxHighlighter: hl, codeLanguageLabel: label)
            }
            print(unsafe "COLD blocks=\(blocks) bare=\(String(format: "%.1f", bare))ms "
                + "full=\(String(format: "%.1f", full))ms "
                + "delta=\(String(format: "%.1f", full - bare))ms")
        }
    }

    /// A keystroke inside one code block of a document full of them. The block
    /// cache and the incremental entries should confine the work to the edited
    /// block — this measures what that block still costs.
    func testKeystrokeInsideCodeBlock() throws {
        let editor = try Editor(extensions: fullKit())
        let s = editor.schema
        let theme = DocumentTheme()
        let hl = makeSyntaxHighlighter()
        let label = makeCodeLanguageLabel()
        let blocks = 40
        var current = try doc(s, blocks: blocks, chars: 4_000)
        let cache = TextBlockLayoutCache()
        var previous = DocumentLayout(doc: current, width: 390, theme: theme, blockCache: cache,
                                      syntaxHighlighter: hl, codeLanguageLabel: label)
        var times: [Double] = []
        for round in 0 ..< 5 {
            var children = (0 ..< current.childCount).map { current.child($0) }
            let edited = source(chars: 4_000, seed: blocks / 2) + "\nconst edit\(round) = 1"
            children[blocks / 2] = try s.node("codeBlock", [:], content: Fragment.from([s.text(edited)]))
            current = try s.node("doc", [:], content: Fragment.from(children))
            let t = CFAbsoluteTimeGetCurrent()
            previous = DocumentLayout(doc: current, width: 390, theme: theme, blockCache: cache,
                                      previous: previous, syntaxHighlighter: hl, codeLanguageLabel: label)
            times.append((CFAbsoluteTimeGetCurrent() - t) * 1000)
        }
        print(unsafe "KEYSTROKE blocks=\(blocks) chars=4000 "
            + "best=\(String(format: "%.2f", times.min()!))ms")
    }
}
#endif

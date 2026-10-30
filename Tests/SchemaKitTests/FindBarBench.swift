import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import SchemaKit
import TestHarness

private func time(_ label: String, ops: Int, runs: Int = 5, _ body: () throws -> Void) rethrows {
    var best = Double.infinity
    for _ in 0..<runs {
        let start = Date()
        try body()
        best = min(best, Date().timeIntervalSince(start))
    }
    unsafe print(String(format: "  %-44s %7.2f ms  %7.1f µs each",
                        (label as NSString).utf8String!, best * 1000, best * 1e6 / Double(ops)))
    unsafe fflush(stdout)
}

/// What the find bar and suggestion mode cost on the paths a user waits on.
/// Off by default:
///
///     PROSEKIT_BENCH=1 swift run -c release SchemaKitTests
///
/// "n of m" is what the find bar reads after every keystroke in its field and
/// every next/previous; the suggestion decorations are read on every paint.
func registerFindBarBench() {
    guard ProcessInfo.processInfo.environment["PROSEKIT_BENCH"] != nil else { return }
    test("find bar bench") {
        for count in [500, 2000] {
            print("\n  --- \(count) paragraphs ---"); unsafe fflush(stdout)
            let editor = try Editor(extensions: fullKit())
            try editor.setContent(html: (0..<count).map {
                "<p>Paragraph \($0): the quick brown fox jumps over the lazy dog.</p>"
            }.joined())
            editor.setSearch("the")
            time("find count, \"the\" (x20)", ops: 20) {
                for _ in 0..<20 {
                    _ = editor.currentSearchMatchIndex
                    _ = editor.searchMatches.count
                }
            }
        }

        // One long paragraph thick with regex matches: each match used to be
        // measured from the start of the block.
        for length in [20_000, 40_000] {
            let editor = try Editor(extensions: fullKit())
            try editor.setContent(html: "<p>\(String(repeating: "ab ", count: length / 3))</p>")
            time("regex \"a.\" over \(length / 1000)k chars", ops: 1, runs: 3) {
                editor.setSearch("a.", regexp: true)
                editor.clearSearch()
            }
        }

        print("\n  --- suggestion mode ---"); unsafe fflush(stdout)
        let editor = try Editor(extensions: fullKit())
        try editor.setContent(html: (0..<500).map { "<p>Paragraph \($0) of base text.</p>" }.joined())
        editor.dispatch(setSuggestionMode(editor.state.tr, enabled: true))
        // Delete a word from every other paragraph: a deletion widget each.
        // Back to front, so the earlier positions still hold.
        var starts: [Int] = []
        editor.doc.descendants { _, pos, _, index in
            if index % 2 == 0 { starts.append(pos) }
            return false
        }
        for start in starts.reversed() {
            let tr = editor.state.tr
            try tr.delete(start + 1, start + 10)
            editor.dispatch(tr)
        }
        try expect(suggestionDecorations(editor.state)?.decorations.count == starts.count,
                   "one deletion widget per edited paragraph")
        time("suggestion decorations, one paint (x100)", ops: 100) {
            for _ in 0..<100 { _ = suggestionDecorations(editor.state) }
        }
    }
}

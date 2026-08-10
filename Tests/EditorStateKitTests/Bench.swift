import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import TestHarness

private func time(_ label: String, _ runs: Int = 5, _ body: () throws -> Void) rethrows {
    var best = Double.infinity
    for _ in 0..<runs {
        let start = Date()
        try body()
        best = min(best, Date().timeIntervalSince(start))
    }
    unsafe print(String(format: "  %-52s %8.2f ms", (label as NSString).utf8String!, best * 1000))
    unsafe fflush(stdout)
}

/// Timings for the editing path — the work every keystroke does beneath the
/// renderer. Off by default so CI stays quiet:
///
///     PROSEKIT_BENCH=1 swift run -c release EditorStateKitTests
///
/// Two document shapes, because they stress different things. A thousand short
/// paragraphs makes every scan of the top-level fragment long; twenty blocks of
/// long text makes every measurement of a single text node expensive. A change
/// can be free on one and decisive on the other, so both are here.
func registerEditBench() {
    guard ProcessInfo.processInfo.environment["PROSEKIT_BENCH"] != nil else { return }
    test("edit bench") {
        var blocks: [Node] = []
        for i in 0..<1000 {
            blocks.append(B.p("Paragraph \(i) with some words in it that go on for a while "
                + "so the block is a realistic length for an article body."))
        }
        let doc = B.node("doc", [:], blocks)
        let size = doc.content.size
        let state = freshState(doc)
        print("\n  --- \(doc.childCount) paragraphs, \(size) positions ---")
        unsafe fflush(stdout)

        // A keystroke: one character inserted, near the start and near the end.
        try time("insertText near the start x1000") {
            for _ in 0..<1000 { let tr = state.tr; _ = try tr.insertText("a", 5) }
        }
        try time("insertText near the end x1000") {
            for _ in 0..<1000 { let tr = state.tr; _ = try tr.insertText("a", size - 5) }
        }
        // Applying, which is what a real keystroke does.
        try time("apply a keystroke x1000") {
            var s = state
            for _ in 0..<1000 { let tr = s.tr; _ = try tr.insertText("a", 5); s = s.apply(tr) }
        }
        try time("apply a keystroke at the end x1000") {
            var s = state
            for _ in 0..<1000 {
                let tr = s.tr; _ = try tr.insertText("a", s.doc.content.size - 5); s = s.apply(tr)
            }
        }
        // Resolving a position, which everything does constantly.
        time("doc.resolve near the end x10000") {
            for _ in 0..<10000 { _ = doc.resolve(size - 5) }
        }
        time("doc.resolve near the start x10000") {
            for _ in 0..<10000 { _ = doc.resolve(5) }
        }
        // Marks over a wide range.
        try time("addMark over the whole document") {
            let tr = state.tr
            _ = try tr.addMark(1, size - 1, B.schema.mark("italic"))
        }
        try time("replace a block x1000") {
            for _ in 0..<1000 {
                let tr = state.tr
                _ = try tr.replaceWith(1, 60, B.schema.text("replacement"))
            }
        }
        // The other shape a document takes: few blocks, each holding a lot of
        // text. A pasted article, a long code block. Here one text node is
        // most of the document, so anything that measures its length is
        // measuring the whole document.
        var longBlocks: [Node] = []
        for i in 0..<20 {
            longBlocks.append(B.p(String(repeating: "some words in a long paragraph ", count: 700) + "\(i)"))
        }
        let longDoc = B.node("doc", [:], longBlocks)
        let longSize = longDoc.content.size
        let longState = freshState(longDoc)
        print("  --- 20 blocks, \(longSize) positions (long text nodes) ---"); unsafe fflush(stdout)
        time("long: doc.resolve near the end x1000") {
            for _ in 0..<1000 { _ = longDoc.resolve(longSize - 5) }
        }
        try time("long: insertText near the end x1000") {
            for _ in 0..<1000 { let tr = longState.tr; _ = try tr.insertText("a", longSize - 5) }
        }
        time("long: doc.textBetween a small slice x1000") {
            for _ in 0..<1000 { _ = longDoc.textBetween(20, 60) }
        }

        // Mapping through a long history, which collab and undo both do.
        let tr = state.tr
        for i in 0..<500 { _ = try tr.insertText("x", 5 + i * 2) }
        print("  (a transaction of \(tr.steps.count) steps)"); unsafe fflush(stdout)
        time("map a position through 500 steps x1000") {
            for _ in 0..<1000 { _ = tr.mapping.map(size / 2) }
        }
        try time("apply 500 steps to a fresh state") {
            var s = state
            let t = s.tr
            for i in 0..<500 { _ = try t.insertText("x", 5 + i * 2) }
            s = s.apply(t)
            _ = s
        }
    }
}

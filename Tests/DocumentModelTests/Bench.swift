import Foundation
import DocumentModel
import TestHarness

private func time(_ label: String, _ runs: Int = 5, _ body: () throws -> Void) rethrows {
    var best = Double.infinity
    for _ in 0..<runs {
        let start = Date()
        try body()
        best = min(best, Date().timeIntervalSince(start))
    }
    unsafe print(String(format: "  %-46s %8.2f ms", (label as NSString).utf8String!, best * 1000))
    unsafe fflush(stdout)
}

/// Timings for the paths that read and slice a document's text, off by default
/// so CI output stays quiet:
///
///     PROSEKIT_BENCH=1 swift run -c release DocumentModelTests
///
/// Run it in release — debug numbers are dominated by unspecialized generics.
///
/// These positions are grapheme-cluster offsets, so the work here can't move to
/// bytes the way a serializer's can; what it can avoid is walking the clusters
/// more times than the answer needs.
func registerBench() {
    guard ProcessInfo.processInfo.environment["PROSEKIT_BENCH"] != nil else { return }
    test("bench") {
        // A document the size of a long article.
        var blocks: [Node] = []
        for i in 0..<1000 {
            blocks.append(B.p("Paragraph \(i) with some words in it that go on for a while "
                + "so the block is a realistic length for an article body."))
        }
        let doc = B.node("doc", [:], blocks)
        let size = doc.content.size
        print("\n  --- \(doc.childCount) paragraphs, \(size) positions, "
            + "\(doc.textContent.count / 1024) KB of text ---")
        unsafe fflush(stdout)

        time("doc.textContent") { _ = doc.textContent }
        time("doc.textBetween, a slice of one block") {
            for _ in 0..<1000 { _ = doc.textBetween(20, 60) }
        }
        time("doc.cut(1, half) x100") { for _ in 0..<100 { _ = doc.cut(1, size / 2) } }
        time("doc.slice(1, half) x100") { for _ in 0..<100 { _ = doc.slice(1, size / 2) } }
        // A cut landing inside a text node, which is the path that has to
        // actually slice one rather than hand it back whole.
        time("doc.slice, both ends mid-word, x100") {
            for _ in 0..<100 { _ = doc.slice(5, size - 5) }
        }
    }
}

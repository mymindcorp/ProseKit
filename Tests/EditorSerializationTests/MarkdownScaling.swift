import Foundation
import DocumentModel
import EditorSerialization
import TestHarness

// The inline scanner used to look for a closing delimiter from every position
// that could open one, and walk the rest of the line each time it wasn't there.
// That is quadratic, and a line of openers is the cheapest thing to type: 200 KB
// of `[` took 17.9s, `*a` repeated 6.0s, `[a](` repeated 4.0s. None of it
// crashed — it hung, on the thread doing the paste.
//
// These payloads are the shapes that were quadratic, held to a wall-clock bound
// far above what linear parsing needs and far below what a return of the
// quadratic behaviour would take. The bound is generous on purpose: it is here
// to catch an algorithmic regression, not to measure the machine.

private func parseWithin(_ seconds: Double, _ markdown: String,
                         file: StaticString = #file, line: UInt = #line) throws {
    let start = Date()
    _ = try? MarkdownParser.parse(markdown, schema: schema)
    let elapsed = Date().timeIntervalSince(start)
    try expect(elapsed <= seconds,
               "parsing \(markdown.utf8.count / 1024) KB took \(Int(elapsed * 1000))ms, over the "
                   + "\(Int(seconds * 1000))ms bound — the scan is quadratic again",
               file: file, line: line)
}

func registerMarkdownScalingTests() {
    // 200 KB each: what every one of these took before, in seconds, is in the
    // comment beside it.
    let hostile: [(name: String, markdown: String)] = [
        ("unclosed brackets", String(repeating: "[", count: 200_000)),                    // 17.9s
        ("openers, one closer", String(repeating: "[", count: 199_999) + "]"),            // 19.8s
        ("unclosed wiki links", String(repeating: "[[", count: 100_000)),                 // 17.8s
        ("unclosed link destinations", String(repeating: "[a](", count: 50_000)),         //  4.0s
        ("link destinations, one closer", String(repeating: "[a](", count: 49_999) + ")"), // 4.1s
        ("reference-shaped brackets", String(repeating: "[a][", count: 50_000)),          //  5.5s
        ("emphasis runs", String(repeating: "*a", count: 100_000)),                       //  6.0s
        ("unclosed angle brackets", String(repeating: "<", count: 200_000)),              //  5.1s
        ("tag-shaped angle brackets", String(repeating: "<a ", count: 66_666)),           //  1.7s
    ]
    for (name, markdown) in hostile {
        test("markdown scaling: \(name)") { try parseWithin(5.0, markdown) }
    }

    // Doubling the input may not more than triple the time. Quadratic growth is
    // a factor of four, linear a factor of two, and the gap between them is wide
    // enough that the machine's noise doesn't reach across it.
    test("markdown scaling: cost grows with the input, not with its square") {
        func elapsed(_ n: Int) -> Double {
            let markdown = String(repeating: "[", count: n)
            let start = Date()
            _ = try? MarkdownParser.parse(markdown, schema: schema)
            return Date().timeIntervalSince(start)
        }
        _ = elapsed(20_000)                    // warm the allocator
        let small = max(elapsed(100_000), 0.0005)
        let large = elapsed(200_000)
        try expect(large < small * 3,
                   "100 KB took \(small)s, 200 KB took \(large)s — that is superlinear")
    }
}

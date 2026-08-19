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
// These payloads are the shapes that were quadratic. What's asserted is how the
// cost *grows*, not how long it takes, because a wall-clock bound can't do the
// job here: to survive a loaded machine — a simulator running beside the suite
// was enough — it had to sit around 9s, which is *above* what six of these nine
// payloads cost when they were quadratic. A bound that can't fail on the bug it
// guards isn't a test.
//
// The comparison gives both of its measurements the same number of characters
// to chew on: four parses of the smaller input against one of an input four
// times its size. Linear work makes those two equal, and quadratic work makes
// the single large parse cost four times the four small ones — so healthy sits
// near 1, the regression sits near 4, and the bound goes between them.
//
// Equal exposure is the part that matters, and it is the same lesson as
// `testScanScaling` in EditorUIKitTests (see the commit that stopped it failing
// on a busy machine): comparing one small parse to one large one lets the small
// sample find an uncontended slice far more often than the large one does, and
// the ratio then climbs on a curve that is perfectly flat. Measured over three
// runs here, every payload lands between 0.65 and 1.94.

private func parseSeconds(_ markdown: String) -> Double {
    let start = Date()
    _ = try? MarkdownParser.parse(markdown, schema: schema)
    return Date().timeIntervalSince(start)
}

/// Healthy is ~1 and quadratic is ~4, so this sits between them with room on
/// both sides.
private let growthBound = 2.5

/// A single parse taking this long is a hang however it scales — the bug this
/// file guards showed up as a frozen paste, and freezing linearly is no better.
private let hangBound = 60.0

/// A floor under the small side, so a payload too cheap to time can't turn
/// scheduler noise into a ratio. It lets anything under 125ms past, and the
/// cheapest of these payloads cost 1.7s when it was quadratic.
private let smallFloor = 0.050

/// Assert that four parses of `build(n)` cost about as much as one of
/// `build(n * 4)`.
///
/// Measured twice before failing: one load spike landing across a pair of
/// samples is not an algorithmic regression, and the second measurement costs
/// nothing on the passing path.
private func expectLinearGrowth(_ build: @Sendable (Int) -> String, _ n: Int,
                                file: StaticString = #file, line: UInt = #line) throws {
    var report = ""
    for _ in 1...2 {
        let smallInput = build(n), largeInput = build(n * 4)
        var small = 0.0
        for _ in 0..<4 { small += parseSeconds(smallInput) }
        small = max(small, smallFloor)
        let large = parseSeconds(largeInput)
        // Say what was measured, so a failure doesn't need a rerun to diagnose.
        report = "4 × \(smallInput.utf8.count / 1024) KB took \(Int(small * 1000))ms, "
            + "1 × \(largeInput.utf8.count / 1024) KB took \(Int(large * 1000))ms "
            + "— a ratio of \((large / small * 100).rounded() / 100) against the \(growthBound) bound"
        // A hang gets no second measurement: it already took long enough.
        try expect(large <= hangBound, "\(report); one parse taking \(Int(large)) seconds is a hang",
                   file: file, line: line)
        if large < small * growthBound { return }
    }
    try expect(false, "\(report); the same characters should cost about the same either way",
               file: file, line: line)
}

func registerMarkdownScalingTests() {
    // Each builds to 200 KB at `n * 4`, the size every one of these was measured
    // at above. What it took then, in seconds, is beside it.
    let hostile: [(name: String, build: @Sendable (Int) -> String, n: Int)] = [
        ("unclosed brackets", { String(repeating: "[", count: $0) }, 50_000),              // 17.9s
        ("openers, one closer", { String(repeating: "[", count: $0 - 1) + "]" }, 50_000),  // 19.8s
        ("unclosed wiki links", { String(repeating: "[[", count: $0) }, 25_000),           // 17.8s
        ("unclosed link destinations", { String(repeating: "[a](", count: $0) }, 12_500),  //  4.0s
        ("link destinations, one closer", { String(repeating: "[a](", count: $0 - 1) + ")" }, 12_500), // 4.1s
        ("reference-shaped brackets", { String(repeating: "[a][", count: $0) }, 12_500),   //  5.5s
        ("emphasis runs", { String(repeating: "*a", count: $0) }, 25_000),                 //  6.0s
        ("unclosed angle brackets", { String(repeating: "<", count: $0) }, 50_000),        //  5.1s
        ("tag-shaped angle brackets", { String(repeating: "<a ", count: $0) }, 16_666),    //  1.7s
    ]
    for (name, build, n) in hostile {
        test("markdown scaling: \(name)") { try expectLinearGrowth(build, n) }
    }
}

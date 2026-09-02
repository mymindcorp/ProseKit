import Foundation
import DocumentModel
import EditorSerialization
import TestHarness

// A byte-level fuzzer for the JSON reader.
//
// The reader replaced `JSONSerialization` under the document loader, and its
// promise is that the loader behaves as it did: the same bytes are accepted
// or refused, and accepted bytes read as the same value. The value-level
// fuzzer in SchemaKit can't check that — it corrupts a document and then
// *re-encodes* it, so every input it produces is well-formed JSON. This one
// corrupts the bytes: a byte flipped, one inserted or deleted, a run copied,
// the file cut short. Nothing it produces may trap, and on every input the
// reader and Foundation have to agree.
//
// A bounded, seeded sweep always runs; `PROSEKIT_FUZZ=1` makes it a deep one.

/// SplitMix64: enough randomness for mutations, and reproducible from a seed.
private struct ByteRNG: RandomNumberGenerator {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
}

/// The bytes a mutation is likely to reach for: JSON's own punctuation and
/// the characters that begin a literal, a number or an escape, the whitespace
/// JSON allows and the whitespace it doesn't, a byte-order mark, and the
/// bytes that make a string stop being UTF-8.
private let interestingBytes: [UInt8] = Array("\"\\,:{}[]0123456789.eE+-utfn ".utf8)
    + [0x09, 0x0A, 0x0D, 0x0B, 0x0C, 0x00, 0x1F, 0x7F, 0x80, 0xA0, 0xC3, 0xE2, 0xEF, 0xBB, 0xBF, 0xF0, 0xFE, 0xFF]

private enum Mutation: CaseIterable {
    case flip, insert, delete, duplicate, truncate
}

private func mutate(_ bytes: inout [UInt8], _ rng: inout ByteRNG) -> String {
    guard !bytes.isEmpty else { bytes.append(interestingBytes[rng.below(interestingBytes.count)]); return "insert into empty" }
    func randomByte() -> UInt8 {
        rng.below(10) < 7 ? interestingBytes[rng.below(interestingBytes.count)] : UInt8(rng.below(256))
    }
    let at = rng.below(bytes.count)
    // Truncation is rarer than the rest: every prefix of the corpus is
    // already a test of its own, and a cut file has little left to mutate.
    let op = rng.below(20) == 0 ? Mutation.truncate : Mutation.allCases[rng.below(4)]
    switch op {
    case .flip:
        let b = randomByte()
        bytes[at] = b
        return "flip byte \(at) to 0x\(String(b, radix: 16))"
    case .insert:
        let b = randomByte()
        bytes.insert(b, at: at)
        return "insert 0x\(String(b, radix: 16)) at \(at)"
    case .delete:
        bytes.remove(at: at)
        return "delete byte \(at)"
    case .duplicate:
        let length = min(1 + rng.below(16), bytes.count - at)
        let run = Array(bytes[at..<(at + length)])
        let to = rng.below(bytes.count + 1)
        bytes.insert(contentsOf: run, at: to)
        return "copy \(length) bytes from \(at) to \(to)"
    case .truncate:
        bytes.removeSubrange(at...)
        return "truncate at \(at)"
    }
}

/// Whether two readings are the same document, allowing the two differences
/// the reader makes on purpose: an integer past `Int`'s range is a `Double`
/// where Foundation wrapped it, and a decimal with more digits than a
/// `Double` holds is correctly rounded where Foundation's was a few ulps off.
private func agrees(_ ours: AttributeValue, _ theirs: AttributeValue) -> Bool {
    switch (ours, theirs) {
    case let (.double(a), .double(b)):
        return a == b || abs(a - b) <= abs(b) * 1e-12
    case let (.double(a), .int):
        return abs(a) >= 9_223_372_036_854_775_808.0
    case let (.array(a), .array(b)):
        return a.count == b.count && zip(a, b).allSatisfy { agrees($0, $1) }
    case let (.object(a), .object(b)):
        return a.count == b.count && a.allSatisfy { key, value in b[key].map { agrees(value, $0) } ?? false }
    default:
        return ours == theirs
    }
}

/// Whether a value holds the replacement character anywhere — the sign that
/// Foundation let a stray byte through as U+FFFD.
private func holdsReplacement(_ value: AttributeValue) -> Bool {
    switch value {
    case let .string(s): return s.unicodeScalars.contains("\u{FFFD}")
    case let .array(a): return a.contains(where: holdsReplacement)
    case let .object(o): return o.contains { holdsReplacement(.string($0.key)) || holdsReplacement($0.value) }
    default: return false
    }
}

/// Whether a value holds an infinity — which JSON can't spell, and which
/// Foundation nonetheless produces for `-1e1000` while refusing `1e1000`.
private func holdsInfinity(_ value: AttributeValue) -> Bool {
    switch value {
    case let .double(d): return !d.isFinite
    case let .array(a): return a.contains(where: holdsInfinity)
    case let .object(o): return o.values.contains(where: holdsInfinity)
    default: return false
    }
}

/// Whether the bytes hold an exponent of four or more digits. Foundation
/// refuses any number whose exponent reaches a thousand — `1e-1000` — while
/// reading `1e-999` as zero; the reader reads both as the zero (or, for a
/// positive exponent, the out-of-range refusal) the value actually is.
private func hasHugeExponent(_ bytes: [UInt8]) -> Bool {
    var i = 0
    while i < bytes.count {
        if bytes[i] | 0x20 == UInt8(ascii: "e") {
            var j = i + 1
            if j < bytes.count, bytes[j] == UInt8(ascii: "+") || bytes[j] == UInt8(ascii: "-") { j += 1 }
            var digits = 0
            while j < bytes.count, bytes[j] >= UInt8(ascii: "0"), bytes[j] <= UInt8(ascii: "9") { j += 1; digits += 1 }
            if digits >= 4 { return true }
        }
        i += 1
    }
    return false
}

/// What the loader used to answer for these bytes.
private func foundationParse(_ data: Data) -> AttributeValue? {
    guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
    return try? DocumentJSON.attributeValue(from: object)
}

private func printable(_ bytes: [UInt8]) -> String {
    let text = String(decoding: bytes.prefix(240), as: UTF8.self).debugDescription
    return bytes.count > 240 ? text + "… (\(bytes.count) bytes)" : text
}

func registerJSONByteFuzzTests() {
    let deep = ProcessInfo.processInfo.environment["PROSEKIT_FUZZ"] != nil
    let seeds = deep ? 100_000 : 10_000

    test("json byte fuzz: the reader agrees with Foundation on corrupted bytes (\(seeds) seeds)") {
        // The corpus: the document that uses every node and mark, dense and
        // laid out; a value with every escape and number shape; and a string
        // long enough that a mutation lands deep in the reader's fast path.
        let everything = everythingDocument()
        let shapes: AttributeValue = .object([
            "escapes": .string("quote \" backslash \\ slash / newline \n tab \t nul \u{00} del \u{7F}"),
            "unicode": .string("é ü 日本語 😀 \u{200B}"),
            "numbers": .array([.int(0), .int(-1), .int(Int.max), .int(Int.min), .double(1.5), .double(-0.25),
                               .double(1e100), .double(1e-7), .double(100)]),
            "literals": .array([.bool(true), .bool(false), .null]),
            "empty": .array([.array([]), .object([:]), .string("")]),
        ])
        let long = AttributeValue.string(String(repeating: "x", count: 4_000) + "\n" + String(repeating: "y", count: 200))
        let corpus: [[UInt8]] = [
            Array(try DocumentJSON.encode(everything)),
            Array(try DocumentJSON.encode(everything, pretty: true)),
            Array(try DocumentJSON.encode(shapes)),
            Array(try DocumentJSON.encode(shapes, pretty: true)),
            Array(try DocumentJSON.encode(long)),
        ]

        var mismatches: [String] = []
        var accepted = 0, refused = 0
        for seed in 0..<seeds {
            var rng = ByteRNG(UInt64(seed))
            var bytes = corpus[seed % corpus.count]
            var steps: [String] = []
            for _ in 0..<(1 + rng.below(3)) { steps.append(mutate(&bytes, &rng)) }
            let data = Data(bytes)
            let ours = try? DocumentJSON.parse(data)
            let theirs = foundationParse(data)
            if ours == nil { refused += 1 } else { accepted += 1 }
            let agree: Bool
            switch (ours, theirs) {
            case (nil, nil): agree = true
            case let (o?, t?): agree = agrees(o, t)
            case let (nil, t?):
                // Foundation refuses broken UTF-8 in a string — except for
                // the odd stray continuation byte, which it lets through as
                // U+FFFD — and refuses a number past `Double`'s range, except
                // a negative one, which it reads as minus infinity. The reader
                // refuses both; those are the two ways it may be stricter.
                agree = (holdsReplacement(t) && String(validating: bytes, as: UTF8.self) == nil) || holdsInfinity(t)
            case (_?, nil):
                agree = hasHugeExponent(bytes)
            }
            if !agree, mismatches.count < 10 {
                mismatches.append("seed \(seed) (\(steps.joined(separator: "; "))): reader \(ours.map { "\($0)" } ?? "refused"), Foundation \(theirs.map { "\($0)" } ?? "refused")\n    input: \(printable(bytes))")
            }
        }
        // A sweep that only ever produced refusals would be asserting the two
        // agree on nothing in particular.
        try expect(accepted > seeds / 20, "only \(accepted) of \(seeds) mutated inputs were accepted")
        try expect(refused > seeds / 20, "only \(refused) of \(seeds) mutated inputs were refused")
        try expect(mismatches.isEmpty, "\(mismatches.count)+ disagreements:\n" + mismatches.joined(separator: "\n"))
    }
}

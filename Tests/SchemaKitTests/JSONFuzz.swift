import Foundation
import DocumentModel
import DocumentTransform
import EditorSerialization
import EditorStateKit
import SchemaKit
import TestDocGen
import TestHarness

// A fuzzer for the JSON loaders on input that isn't what they wrote.
//
// Document JSON comes back from disk after another version of the app wrote
// it; step JSON arrives from a peer, who may be running anything; selection
// JSON rides along with both. Each loader is allowed to refuse. None of them
// may trap, and none may hand back something the schema rejects — a loaded
// document is *the* document from then on, and a step that decodes into
// nonsense is applied to every peer's copy at once.
//
// The corpus is real JSON — documents from the generator, steps from the op
// driver, selections from every position — with one thing wrong with each: a
// key dropped, a value swapped for another type, a number pushed out of range,
// a string emptied, a child duplicated or removed.
//
// Opt-in for the same reason as the selection sweeps; see `SelectionFuzz`.
func registerJSONFuzzTests() {
    guard ProcessInfo.processInfo.environment["PROSEKIT_FUZZ"] != nil else { return }

    test("json fuzz: a corrupted document either refuses to load or loads valid") {
        let schema = try fuzzSchema()
        var rng = SelRNG(113)
        for (seed, doc) in fuzzCorpus(schema, count: 20) {
            let json = doc.toJSON()
            for i in 0 ..< 40 {
                let (what, mutated) = mutate(.object(json), &rng)
                guard case let .object(dict) = mutated else { continue }
                let ctx = "\(seed) mutation \(i): \(what)"
                // `Node.fromJSON` builds what it is given — a slice's open
                // nodes are partial by design — so it owes only safety: no
                // trap, positions that resolve, JSON that survives a
                // round-trip. Validity is the document loader's promise.
                if let loaded = try? Node.fromJSON(schema, dict) {
                    for pos in 0 ... loaded.content.size { _ = loaded.resolve(pos) }
                    let again = try Node.fromJSON(schema, loaded.toJSON())
                    // NaN is never equal to itself, so an attribute holding one
                    // can't round-trip by `==`; JSON has no spelling for it
                    // either, and the file loader refuses it further up.
                    if !containsNaN(.object(loaded.toJSON())) {
                        try expect(again == loaded, "a built node doesn't survive its own JSON — \(ctx)")
                    }
                }
                // And the file loader, which goes through Foundation's JSON on
                // both sides and has its own attribute-value conversion.
                if let data = try? DocumentJSON.encode(mutated), let loaded = try? DocumentJSON.decode(schema, data) {
                    try checkLoaded(loaded, "DocumentJSON — \(ctx)")
                }
            }
        }
    }

    test("json fuzz: a corrupted step either refuses to decode or applies cleanly") {
        var rng = SelRNG(127)
        for seed in 1 ... Swift.min(fuzzOpSeeds, 12) {
            let recorder = try FuzzRecorder()
            let schema = recorder.editor.schema
            var opRNG = SelRNG(seed)
            for _ in 0 ..< 20 {
                let (what, trs) = recorder.step(&opRNG)
                for (step, doc) in fuzzSteps(trs) {
                    let json = step.toJSON()
                    for i in 0 ..< 12 {
                        let (how, mutated) = mutate(.object(json), &rng)
                        guard case let .object(dict) = mutated else { continue }
                        let ctx = "seed \(seed) \(step.jsonID) from \(what), mutation \(i): \(how)"
                        guard let decoded = try? decodeStep(schema, dict) else { continue }
                        // Decoded: applying it may fail, but must say so
                        // rather than trap, and a success is a valid document
                        // whose map the step can describe.
                        guard let applied = decoded.apply(doc).doc else { continue }
                        var invalid: (any Error)?
                        do { try applied.check() } catch { invalid = error }
                        try expect(invalid == nil, "a corrupted step applied into an invalid document — \(ctx): \(invalid.map { "\($0)" } ?? "")")
                        let map = decoded.getMap()
                        for pos in stride(from: 0, through: doc.content.size, by: Swift.max(1, doc.content.size / 8)) {
                            let there = map.map(pos, 1)
                            try expect(there >= 0 && there <= applied.content.size,
                                       "the corrupted step's map sent \(pos) to \(there), outside \(applied.content.size) — \(ctx)")
                        }
                        // Its inverse is a step too, and inverting a step that
                        // applied has to bring the document back.
                        let inverse = decoded.invert(doc)
                        if let back = inverse.apply(applied).doc {
                            try expect(back == doc, "a corrupted step's inverse didn't restore the document — \(ctx)")
                        }
                    }
                }
            }
        }
    }

    test("json fuzz: a corrupted selection either refuses to decode or is a selection the document holds") {
        let schema = try fuzzSchema()
        var rng = SelRNG(131)
        for (seed, doc) in fuzzCorpus(schema, count: 15) {
            for sel in everySelection(in: doc).prefix(60) {
                let json = sel.toJSON()
                for i in 0 ..< 6 {
                    let (how, mutated) = mutate(.object(json), &rng)
                    guard case let .object(dict) = mutated else { continue }
                    let ctx = "\(seed) \(describeSelection(sel)) mutation \(i): \(how)"
                    let decoded: Selection?
                    if dict["type"]?.stringValue == "cell" {
                        decoded = CellSelection.fromCellJSON(doc, dict)
                    } else {
                        decoded = try? Selection.fromJSON(doc, dict)
                    }
                    if let decoded { try checkSelectionValid(decoded, in: doc, ctx) }
                }
            }
        }
    }
}

private func checkLoaded(_ doc: Node, _ ctx: @autoclosure () -> String) throws {
    var invalid: (any Error)?
    do { try doc.check() } catch { invalid = error }
    try expect(invalid == nil, "a corrupted document loaded but is invalid — \(ctx()): \(invalid.map { "\($0)" } ?? "")\n\(fuzzOutline(doc))")
    for pos in 0 ... doc.content.size { _ = doc.resolve(pos) }
    // What loaded has to write back out and load again the same: a loader
    // that accepts something its own writer can't reproduce has a document
    // that changes on the next save.
    let again = try Node.fromJSON(doc.type.schema, doc.toJSON())
    try expect(again == doc, "a loaded document doesn't survive its own JSON — \(ctx())")
}

private func containsNaN(_ v: AttributeValue) -> Bool {
    switch v {
    case let .double(d): return d.isNaN
    case let .array(a): return a.contains(where: containsNaN)
    case let .object(o): return o.values.contains(where: containsNaN)
    default: return false
    }
}

// MARK: - One thing wrong

/// A copy of `value` with one random corruption somewhere inside it, and a
/// description of what was done.
func mutate(_ value: AttributeValue, _ rng: inout SelRNG) -> (String, AttributeValue) {
    // Collect every path, pick one, corrupt what is there.
    var paths: [[String]] = []
    func walk(_ v: AttributeValue, _ path: [String]) {
        paths.append(path)
        switch v {
        case let .object(o): for (k, child) in o.sorted(by: { $0.key < $1.key }) { walk(child, path + [k]) }
        case let .array(a): for (i, child) in a.enumerated() { walk(child, path + ["\(i)"]) }
        default: break
        }
    }
    walk(value, [])
    let path = paths.randomElement(using: &rng)!
    var what = ""
    let result = rewrite(value, path[...], &rng, &what)
    return ("\(path.joined(separator: "/")): \(what)", result)
}

private func rewrite(_ v: AttributeValue, _ path: ArraySlice<String>, _ rng: inout SelRNG, _ what: inout String) -> AttributeValue {
    guard let head = path.first else { return corrupt(v, &rng, &what) }
    switch v {
    case var .object(o):
        if let child = o[head] {
            // Sometimes drop the key rather than corrupt the value.
            if Int.random(in: 0 ..< 5, using: &rng) == 0 { o[head] = nil; what = "dropped"; return .object(o) }
            o[head] = rewrite(child, path.dropFirst(), &rng, &what)
        }
        return .object(o)
    case var .array(a):
        if let i = Int(head), a.indices.contains(i) {
            switch Int.random(in: 0 ..< 6, using: &rng) {
            case 0: a.remove(at: i); what = "removed"; return .array(a)
            case 1: a.insert(a[i], at: i); what = "duplicated"; return .array(a)
            default: a[i] = rewrite(a[i], path.dropFirst(), &rng, &what)
            }
        }
        return .array(a)
    default:
        return corrupt(v, &rng, &what)
    }
}

private func corrupt(_ v: AttributeValue, _ rng: inout SelRNG, _ what: inout String) -> AttributeValue {
    let replacements: [AttributeValue] = [
        .null, .bool(true), .int(-1), .int(0), .int(1), .int(999_999), .int(Int.max), .int(Int.min),
        .double(0.5), .double(.nan), .string(""), .string("text"), .string("doc"), .string("paragraph"),
        .string("nosuchtype"), .string("replace"), .string("cell"), .array([]), .object([:]),
        .object(["type": .string("text")]), .object(["type": .string("text"), "text": .string("")]),
    ]
    switch v {
    case let .int(i) where Bool.random(using: &rng):
        let delta = [1, -1, 2, -2, 7, -7, 1000].randomElement(using: &rng)!
        what = "\(i) → \(i + delta)"; return .int(i &+ delta)
    case let .string(s) where Bool.random(using: &rng) && !s.isEmpty:
        what = "\(s.debugDescription) → dropped last char"; return .string(String(s.dropLast()))
    default:
        let r = replacements.randomElement(using: &rng)!
        what = "→ \(r)"; return r
    }
}

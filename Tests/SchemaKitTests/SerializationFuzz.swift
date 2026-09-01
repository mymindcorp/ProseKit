import Foundation
import DocumentModel
import EditorSerialization
import SchemaKit
import TestDocGen
import TestHarness

// A fuzzer for the serializers, run over the same schema-driven corpus the
// selection sweeps use.
//
// The existing serialization suites are fixture-based: a document someone wrote
// by hand, and the HTML or Markdown it should produce. That catches regressions
// in shapes somebody thought of. It does not catch the figure whose caption
// holds a table, or the heading with a link inside a code mark — and those
// arrive from real notes, from paste, and from other apps.
//
// Three properties, in descending strength:
//
//   * JSON is *lossless*: it is the storage format, so decoding what it encodes
//     has to give the identical document back. Anything less is data loss on
//     the next save.
//   * HTML and Markdown are *stable*: they are lossy by nature (Markdown has no
//     way to say "underlined"), so the round-trip may change a document once.
//     What it may not do is keep changing it — a serializer that never reaches
//     a fixed point is one that rewrites the user's note a little more every
//     time it is opened.
//   * And whatever comes back is a document the schema accepts, with the text
//     still in it.
//
// Opt-in for the same reason as the selection sweeps; see `SelectionFuzz`.
func registerSerializationFuzzTests() {
    guard ProcessInfo.processInfo.environment["PROSEKIT_FUZZ"] != nil else { return }

    test("serialization fuzz: JSON is lossless for every document in the corpus") {
        let schema = try fuzzSchema()
        for (seed, doc) in fuzzCorpus(schema, count: 60) {
            let back = try Node.fromJSON(schema, doc.toJSON())
            try expect(back == doc, "a document didn't survive its own JSON at \(seed)")
            // And through the encoder that actually writes the file, which has
            // its own attribute-value conversion either side of `Data`.
            let text = try DocumentJSON.string(doc)
            let decoded = try DocumentJSON.decode(schema, text)
            try expect(decoded == doc, "a document didn't survive DocumentJSON at \(seed)")
        }
    }

    test("serialization fuzz: HTML round-trips settle instead of drifting") {
        let schema = try fuzzSchema()
        for (seed, doc) in fuzzCorpus(schema, count: 40) {
            let html = HTMLSerializer.serialize(doc)
            let once: Node
            do {
                once = try HTMLParser.parse(html, schema: schema)
            } catch {
                try expect(false, "the parser rejected the serializer's own output at \(seed): \(error)\n  \(html.debugDescription)")
                continue
            }
            try checkParsed(once, schema: schema, source: html, what: "HTML", seed: seed)

            let again = HTMLSerializer.serialize(once)
            let twice = try HTMLParser.parse(again, schema: schema)
            try expect(twice == once,
                       "HTML is still changing the document on the second round-trip at \(seed)\n  once: \(html)\n  again: \(again)")
        }
    }

    test("serialization fuzz: Markdown round-trips settle instead of drifting") {
        let schema = try fuzzSchema()
        for (seed, doc) in fuzzCorpus(schema, count: 40) {
            let markdown = MarkdownSerializer.serialize(doc)
            let once: Node
            do {
                once = try MarkdownParser.parse(markdown, schema: schema)
            } catch {
                try expect(false, "the parser rejected the serializer's own output at \(seed): \(error)\n  \(markdown.debugDescription)")
                continue
            }
            try checkParsed(once, schema: schema, source: markdown, what: "Markdown", seed: seed)

            let again = MarkdownSerializer.serialize(once)
            let twice = try MarkdownParser.parse(again, schema: schema)
            try expect(twice == once,
                       "Markdown is still changing the document on the second round-trip at \(seed)\n  once: \(markdown.debugDescription)\n  again: \(again.debugDescription)")
        }
    }

    test("serialization fuzz: a document's text survives HTML and Markdown") {
        // Formatting is allowed to be lost. Words are not — that is the line
        // between "this export doesn't carry underlines" and "this export ate a
        // paragraph". Compared with whitespace removed, because both formats
        // legitimately re-flow it and neither promises to keep it.
        let schema = try fuzzSchema()
        for (seed, doc) in fuzzCorpus(schema, count: 40) {
            let want = collapsed(typedText(doc))
            guard !want.isEmpty else { continue }
            for (what, text) in [("HTML", HTMLSerializer.serialize(doc)),
                                 ("Markdown", MarkdownSerializer.serialize(doc))] {
                let parsed = what == "HTML" ? try HTMLParser.parse(text, schema: schema)
                                            : try MarkdownParser.parse(text, schema: schema)
                let got = collapsed(typedText(parsed))
                try expect(got.contains(want) || want.contains(got) || got == want,
                           "\(what) lost text at \(seed)\n  wanted: \(want.debugDescription)\n  got:    \(got.debugDescription)\n  via:    \(text.debugDescription)")
            }
        }
    }
}

/// What a parse has to be regardless of format: a document the schema accepts,
/// and one whose positions resolve — a serializer round-trip is where a
/// hand-built fragment reaches the model without going through `createChecked`.
private func checkParsed(_ doc: Node, schema: Schema, source: String, what: String, seed: String) throws {
    var invalid: (any Error)?
    do { try doc.check() } catch { invalid = error }
    try expect(invalid == nil,
               "\(what) parsed into an invalid document at \(seed): \(invalid.map { "\($0)" } ?? "")\n  \(source.debugDescription)")
    for pos in 0 ... doc.content.size { _ = doc.resolve(pos) }
}

/// The characters actually in text nodes.
///
/// Deliberately not `Node.textContent`, which synthesizes a stand-in for an
/// atom — an inline math node reads back as `$…$` whether or not anyone typed
/// anything into it. That stand-in is not text the export owes the user, and
/// counting it turns "an empty formula didn't survive" into "a paragraph was
/// eaten", which are not the same finding.
private func typedText(_ doc: Node) -> String {
    var out = ""
    doc.descendants { node, _, _, _ in
        if let text = node.text { out += text }
        return true
    }
    return out
}

/// The text with its whitespace removed.
///
/// Both formats re-flow whitespace by design, and neither promises to keep it:
/// a paragraph holding one space is a blank line in Markdown and comes back as
/// nothing. Comparing whitespace at all — even collapsed — asserts something
/// no serializer here owes, so this property is about the words.
private func collapsed(_ text: String) -> String {
    text.split(whereSeparator: { $0.isWhitespace }).joined()
}

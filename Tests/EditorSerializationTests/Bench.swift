import Foundation
import DocumentModel
import EditorSerialization
import TestHarness

private func time(_ label: String, _ runs: Int = 5, _ body: () throws -> Void) rethrows {
    var best = Double.infinity
    for _ in 0..<runs {
        let start = Date()
        try body()
        best = min(best, Date().timeIntervalSince(start))
    }
    print(String(format: "  %-46s %8.1f ms", (label as NSString).utf8String!, best * 1000))
    fflush(stdout)
}

/// Timings for the serialization paths, off by default so CI output stays quiet:
///
///     PROSEKIT_BENCH=1 swift run -c release EditorSerializationTests
///
/// Run it in release — debug numbers are dominated by unspecialized generics.
func registerBench() {
    guard ProcessInfo.processInfo.environment["PROSEKIT_BENCH"] != nil else { return }
    test("bench") {
        // A document the size of a long article, with the markup real pastes carry.
        func article(_ paragraphs: Int) -> String {
            var out = "<h1>Title</h1>"
            for i in 0..<paragraphs {
                out += "<p>Paragraph \(i) with <strong>bold</strong>, <em>italic</em>, "
                out += "<a href=\"https://example.test/\(i)\">a link</a> and some plain text "
                out += "that goes on for a while so the block is a realistic length.</p>"
                if i % 10 == 0 {
                    out += "<ul><li>item <strong>one</strong></li><li>item two</li></ul>"
                }
                if i % 25 == 0 {
                    out += "<table><tr><td>a</td><td>b</td></tr><tr><td>c</td><td>d</td></tr></table>"
                }
            }
            return out
        }

        for n in [200, 1000] {
            let html = article(n)
            print("\n  --- \(n) paragraphs, \(html.count / 1024) KB of HTML ---"); fflush(stdout)
            var parsed: Node!
            try time("HTMLParser.parse (total)") { parsed = try HTMLParser.parse(html, schema: schema) }
            time("  of which: tokenize") { _ = HTMLParser.tokenCountForBenchmark(html) }
            try time("  of which: doc.check()") { try parsed.check() }
            time("HTMLSerializer.serialize") { _ = HTMLSerializer.serialize(parsed) }
            let markdown = MarkdownSerializer.serialize(parsed)
            try time("MarkdownParser.parse") { _ = try MarkdownParser.parse(markdown, schema: schema) }
            var json = ""
            try time("DocumentJSON.string (encode)") { json = try DocumentJSON.string(parsed) }
            let tree = AttributeValue.object(parsed.toJSON())
            try time("  of which: the writer") { _ = try DocumentJSON.encode(tree) }
            try time("  was: JSONEncoder (sortedKeys)") {
                let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
                _ = try e.encode(tree)
            }
            try time("DocumentJSON.decode") { _ = try DocumentJSON.decode(schema, json) }
            let jsonData = Data(json.utf8)
            var decoded: AttributeValue!
            try time("  of which: JSONSerialization + bridge") {
                decoded = try DocumentJSON.attributeValue(
                    from: try JSONSerialization.jsonObject(with: jsonData))
            }
            guard case let .object(decodedObj) = decoded! else { fatalError("not an object") }
            try time("  of which: Node.fromJSON") { _ = try Node.fromJSON(schema, decodedObj) }
            try time("  reference: JSONSerialization alone") {
                _ = try JSONSerialization.jsonObject(with: jsonData)
            }
            try time("  was: JSONDecoder -> AttributeValue") {
                _ = try JSONDecoder().decode(AttributeValue.self, from: jsonData)
            }
            time("Node.toJSON (to AttributeValue)") { _ = parsed.toJSON() }
        }
    }
}

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
    unsafe print(String(format: "  %-46s %8.1f ms", (label as NSString).utf8String!, best * 1000))
    unsafe fflush(stdout)
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
            print("\n  --- \(n) paragraphs, \(html.count / 1024) KB of HTML ---"); unsafe fflush(stdout)
            var parsed: Node!
            try time("HTMLParser.parse (total)") { parsed = try HTMLParser.parse(html, schema: schema) }
            time("  of which: tokenize") { _ = HTMLParser.tokenCountForBenchmark(html) }
            try time("  of which: doc.check()") { try parsed.check() }
            time("HTMLSerializer.serialize") { _ = HTMLSerializer.serialize(parsed) }
            let markdown = MarkdownSerializer.serialize(parsed)
            time("MarkdownSerializer.serialize") { _ = MarkdownSerializer.serialize(parsed) }
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
            try time("  of which: the reader") { decoded = try DocumentJSON.parse(jsonData) }
            try time("  was: JSONSerialization + bridge") {
                _ = try DocumentJSON.attributeValue(
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

        // RTF the size of a pasted document: prose with formatting runs and
        // escapes, plus the lists and tables real documents carry.
        func rtfArticle(_ paragraphs: Int) -> String {
            var out = #"{\rtf1\ansi\ansicpg1252\deff0{\fonttbl{\f0\fswiss Helvetica;}{\f1\fmodern Courier;}}"#
            out += #"{\colortbl;\red255\green0\blue0;}"#
            out += #"{\*\listtable{\list\listtemplateid1{\listlevel\levelnfc23{\leveltext\'01\'b7;}}\listid1}}"#
            out += #"{\*\listoverridetable{\listoverride\listid1\listoverridecount0\ls1}}"#
            for i in 0..<paragraphs {
                out += #"\pard Paragraph \#(i) with \b bold\b0 , \i italic\i0 , \cf1 colour\cf0 , "#
                out += #"caf\'e9 and \u8212? a dash, plus {\field{\*\fldinst{HYPERLINK "https://example.test/\#(i)"}}"#
                out += #"{\fldrslt\ul a link}} and text that runs on a while.\par"#
                if i % 10 == 0 {
                    out += #"\pard\ls1\ilvl0{\listtext\'b7\tab}item one\par"#
                    out += #"\pard\ls1\ilvl1{\listtext\'b7\tab}item two\par"#
                }
                if i % 25 == 0 {
                    out += #"\trowd\cellx2880\cellx5760\pard\intbl a\cell\pard\intbl b\cell\row"#
                    out += #"\trowd\cellx2880\cellx5760\pard\intbl c\cell\pard\intbl d\cell\row"#
                }
            }
            return out + "}"
        }

        for n in [200, 1000] {
            let source = rtfArticle(n)
            print("\n  --- \(n) paragraphs, \(source.count / 1024) KB of RTF ---"); unsafe fflush(stdout)
            try time("RTFParser.parse (String)") { _ = try RTFParser.parse(source, schema: schema) }
            let data = Data(source.utf8)
            try time("RTFParser.parse (Data)") { _ = try RTFParser.parse(data, schema: schema) }
        }

        // Prose dense with character references — smart quotes, dashes, nbsp,
        // the accented letters. Decoding them is a different path from the
        // markup around them, and an article's worth of markup barely uses it.
        var entities = ""
        for i in 0..<2000 {
            entities += "<p>It&rsquo;s a &ldquo;test&rdquo; &mdash; number \(i) &amp; more&nbsp;text "
            entities += "with &eacute;, &copy;, &#8212; and &#x2019; in it.</p>"
        }
        print("\n  --- entity-dense prose, \(entities.count / 1024) KB of HTML ---"); unsafe fflush(stdout)
        try time("HTMLParser.parse (total)") { _ = try HTMLParser.parse(entities, schema: schema) }
        time("  of which: tokenize") { _ = HTMLParser.tokenCountForBenchmark(entities) }

        // One mark spanning a long run of children that differ underneath it.
        // The children can't merge into one text node, so writing this asks
        // where the bold run ends once per child — which is how far the writer
        // has to look ahead, and what made it quadratic.
        var run = "<p><strong>"
        for i in 0..<3000 { run += "w\(i) <em>x\(i)</em> " }
        run += "</strong></p>"
        let marked = try HTMLParser.parse(run, schema: schema)
        print("\n  --- one mark over \(marked.child(0).childCount) children ---"); unsafe fflush(stdout)
        time("HTMLSerializer.serialize") { _ = HTMLSerializer.serialize(marked) }
        time("MarkdownSerializer.serialize") { _ = MarkdownSerializer.serialize(marked) }

        // Prose thick with the characters Markdown reads as markup, which is
        // the path that has to add a backslash rather than copy the text over.
        var punctuated = ""
        for i in 0..<2000 {
            punctuated += "<p>snake_case_name_\(i) and 2 * 3 * 4 &amp; a [bracket] "
            punctuated += "with `ticks`, $dollars$ and a &lt;tag&gt; in it.</p>"
        }
        let punctuatedDoc = try HTMLParser.parse(punctuated, schema: schema)
        print("\n  --- escape-dense prose, \(punctuated.count / 1024) KB of HTML ---")
        unsafe fflush(stdout)
        time("MarkdownSerializer.serialize") { _ = MarkdownSerializer.serialize(punctuatedDoc) }

        // A deeply nested list: every level re-indents the text of everything
        // under it, so the cost of writing the innermost item is paid once per
        // level above it.
        var nested = ""
        for i in 0..<40 { nested += "<ul><li><p>level \(i) with some words in it</p>" }
        for _ in 0..<40 { nested += "</li></ul>" }
        let deep = try HTMLParser.parse(nested, schema: schema)
        print("\n  --- 40-deep nested list ---"); unsafe fflush(stdout)
        time("MarkdownSerializer.serialize") { _ = MarkdownSerializer.serialize(deep) }

        // Markdown parsing against input size rather than against a repeat
        // count — a payload whose own generator is quadratic will otherwise
        // read as a quadratic parser. Doubling the size should about double the
        // time; anything nearer four times is a scan that has gone quadratic
        // again. The first group is prose and the shapes documents really have,
        // the second the ones that used to hang.
        let payloads: [(String, (Int) -> String)] = [
            ("prose", { n in String(repeating: "word ", count: n / 5) }),
            ("list items", { n in String(repeating: "- x\n", count: n / 4) }),
            ("quotes, nested", { n in
                var out = ""
                var i = 0
                while out.utf8.count < n { out += String(repeating: "> ", count: i % 32) + "hi\n\n"; i += 1 }
                return out
            }),
            ("table rows", { n in "| a | b |\n| - | - |\n" + String(repeating: "| x | y |\n", count: n / 10) }),
            ("unclosed brackets", { n in String(repeating: "[", count: n) }),
            ("openers, one closer", { n in String(repeating: "[", count: n - 1) + "]" }),
            ("unclosed wiki links", { n in String(repeating: "[[", count: n / 2) }),
            ("unclosed destinations", { n in String(repeating: "[a](", count: n / 4) }),
            ("emphasis runs", { n in String(repeating: "*a", count: n / 2) }),
            ("unclosed angle brackets", { n in String(repeating: "<", count: n) }),
        ]
        for (name, build) in payloads {
            print("\n  --- markdown: \(name) ---"); unsafe fflush(stdout)
            for size in [50_000, 100_000, 200_000] {
                let markdown = build(size)
                time("\(markdown.utf8.count / 1024) KB", 3) { _ = try? MarkdownParser.parse(markdown, schema: schema) }
            }
        }
    }
}

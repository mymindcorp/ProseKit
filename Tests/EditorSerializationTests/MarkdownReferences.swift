import DocumentModel
import EditorSerialization
import TestHarness

func registerMarkdownReferenceTests() {
    test("Markdown references: false closing fences preserve code and hide definitions") {
        for fence in ["````", "~~~~"] {
            for falseClose in [String(fence.prefix(3)), fence + " info", "    " + fence] {
                let body = falseClose + "\n\n[ref]: /inside"
                let markdown = fence + "\n" + body + "\n" + fence + "\n\n[ref]"
                let expected = doc(node("codeBlock", [:], [t(body)]), p("[ref]"))
                try expectEqual(
                    try MarkdownParser.parse(markdown, schema: schema), expected,
                    "false closer: \(falseClose)")
            }
        }
    }

    test("Markdown references: real closing fences expose following definitions") {
        for (open, close) in [("````", "`````"), ("   ~~~~", "  ~~~~~  ")] {
            let markdown = open + "\ncode\n" + close + "\n\n[ref]: /outside\n\n[ref]"
            let link = schema.text("ref", [schema.mark("link", ["href": .string("/outside")])])
            try expectEqual(
                try MarkdownParser.parse(markdown, schema: schema),
                doc(node("codeBlock", [:], [t("code")]), p(link)))
        }
    }

    test("Markdown references: indented code does not open a fence") {
        let markdown = "    ```\n\n[ref]: /outside\n\n[ref]"
        let link = schema.text("ref", [schema.mark("link", ["href": .string("/outside")])])
        try expectEqual(
            try MarkdownParser.parse(markdown, schema: schema),
            doc(node("codeBlock", [:], [t("```")]), p(link)))
    }

    test("Markdown references: list items still collect local and quoted definitions") {
        for definition in ["[ref]: /local", "> [ref]: /local"] {
            let markdown = "- [ref]\n\n  " + definition
            let parsed = try MarkdownParser.parse(markdown, schema: schema)
            let link = schema.text("ref", [schema.mark("link", ["href": .string("/local")])])
            try expectEqual(parsed.child(0).child(0).child(0), p(link))
        }
    }

    test("Markdown references: list items inherit document definitions") {
        for marker in ["- ", "1. ", "- [ ] "] {
            for (content, expectedContent) in [
                ("[ref]", "[ref](/target)"),
                ("[ref][]", "[ref](/target)"),
                ("[label][ref]", "[label](/target)"),
                ("![alt][ref]", "![alt](/target)"),
                ("first\n   [ref]", "first\n   [ref](/target)"),
                ("first\n\n   [ref]", "first\n\n   [ref](/target)"),
                ("first\n   - [ref]", "first\n   - [ref](/target)"),
                ("> [ref]", "> [ref](/target)"),
            ] {
                // Inline links provide the equivalent document structure for
                // references, including images and nested containers.
                let expected = try MarkdownParser.parse(marker + expectedContent, schema: schema)
                for markdown in [
                    "[ref]: /target\n\n" + marker + content,
                    marker + content + "\n\n[ref]: /target",
                ] {
                    try expectEqual(
                        try MarkdownParser.parse(markdown, schema: schema), expected,
                        "input: \(markdown)")
                }
            }
        }
    }
}

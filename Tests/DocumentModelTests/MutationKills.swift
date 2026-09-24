import Foundation
import DocumentModel
import TestHarness

// Tests written against surviving mutants: each one pins a behaviour of the
// model that the rest of the suite let be broken without failing. Expected
// values follow upstream prosemirror-model (test-resolve.ts, test-diff.ts,
// test-node.ts, test-content.ts, test-mark.ts) and what its code computes.

func registerModelMutationKillTests() {
    // MARK: ResolvedPos marks

    // A non-inclusive mark (link) is dropped at its edge, but between two
    // nodes that *both* carry it the position is inside the link, not at its
    // edge — so the link stays.
    test("mutation: marks() keeps a non-inclusive mark that continues after the position") {
        let link = TestSchema.schema.mark("link", ["href": .string("x")])
        let italic = TestSchema.schema.mark("italic")
        let para = B.p(TestSchema.schema.text("fo", [link]), TestSchema.schema.text("o", [link, italic]), B.t("!"))
        let d = B.doc(para)
        // 3: between "fo" (link) and "o" (italic, link).
        try expectEqual(d.resolve(3).marks(), [link])
        // 4: between the linked "o" and plain "!": the link ends here.
        try expectEqual(d.resolve(4).marks(), [italic])
        // marksAcross: deleting 1..3 leaves the link going on after it.
        try expectEqual(d.resolve(1).marksAcross(d.resolve(3)), [link])
        // Deleting 1..4 ends at plain text, so the link doesn't carry across.
        try expectEqual(d.resolve(1).marksAcross(d.resolve(4)), [])
    }

    // MARK: Fragment traversal

    // A node that ends exactly where the range starts is not in the range.
    test("mutation: nodesBetween skips a node that ends at the range's start") {
        let d = B.doc(B.p("ab"), B.p("cd"))
        var seen: [String] = []
        d.nodesBetween(4, 8, { node, pos, _, _ in
            seen.append("\(node.type.name)@\(pos)")
            return true
        })
        try expectEqual(seen, ["paragraph@4", "text@5"])
        // The same inside a textblock: text ending at `from` is skipped.
        let para = B.p(B.t("ab"), B.img("x"), B.t("cd"))
        var inline: [String] = []
        B.doc(para).nodesBetween(3, 4, { node, pos, _, _ in
            inline.append("\(node.type.name)@\(pos)")
            return true
        })
        try expectEqual(inline, ["paragraph@0", "image@3"])
    }

    // MARK: Node queries

    // Upstream test-node: "doesn't allow marks in code blocks" — the content
    // types fit, but the replacement's marks don't.
    test("mutation: canReplace rejects a replacement carrying marks the parent disallows") {
        let code = B.node("codeBlock", [:], [B.t("x")])
        try expect(!code.canReplace(0, 0, replacement: Fragment.from(B.em("y"))))
        try expect(code.canReplace(0, 0, replacement: Fragment.from(B.t("y"))))
        // Only the replaced children within start..<end are asked.
        let mixed = Fragment.from([B.t("a"), B.em("b")])
        try expect(code.canReplace(0, 0, replacement: mixed, start: 0, end: 1))
        try expect(!code.canReplace(0, 0, replacement: mixed, start: 0, end: 2))
        // canReplaceWith asks about the marks it is given, too.
        let text = TestSchema.schema.nodes["text"]!
        try expect(!code.canReplaceWith(0, 0, text, [TestSchema.schema.mark("italic")]))
        try expect(code.canReplaceWith(0, 0, text, []))
        try expect(B.p("x").canReplaceWith(0, 0, text, [TestSchema.schema.mark("italic")]))
    }

    // An empty range holds no marks, even inside marked text.
    test("mutation: rangeHasMark is false for an empty range") {
        let d = B.doc(B.p(B.strong("bold")))
        let bold = TestSchema.schema.marks["bold"]!
        try expect(!d.rangeHasMark(3, 3, bold))
        try expect(d.rangeHasMark(3, 4, bold))
    }

    // MARK: blockRange

    // doc(blockquote(p("a"), p("b"))): the quote's content runs 1…7.
    test("mutation: blockRange reaching exactly the end of an ancestor stays inside it") {
        let d = B.doc(B.blockquote(B.p("a"), B.p("b")))
        guard let range = d.resolve(2).blockRange(d.resolve(7)) else {
            try expect(false, "a range exists"); return
        }
        try expectEqual(range.depth, 1, "the blockquote, not the document")
        try expectEqual(range.startIndex, 0)
        try expectEqual(range.endIndex, 2)
        try expectEqual(range.start, 1)
        try expectEqual(range.end, 7)
    }

    // A collapsed range between two blocks is not a range *inside* the
    // parent: it goes one level up and covers the parent itself.
    test("mutation: a collapsed blockRange between blocks covers the parent") {
        let d = B.doc(B.blockquote(B.p("a"), B.p("b")))
        guard let range = d.resolve(4).blockRange() else {
            try expect(false, "a range exists"); return
        }
        try expectEqual(range.depth, 0)
        try expectEqual(range.startIndex, 0)
        try expectEqual(range.endIndex, 1)
        // …while a non-empty range between blocks stays in the blockquote.
        guard let wide = d.resolve(4).blockRange(d.resolve(7)) else {
            try expect(false, "a range exists"); return
        }
        try expectEqual(wide.depth, 1)
        try expectEqual([wide.startIndex, wide.endIndex], [1, 2])
    }
}

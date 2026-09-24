import Foundation
import DocumentModel
import TestHarness

// The model's public surface that nothing else in the package calls: the
// child lookups, hashing, the JSON loaders' rejections, and the schema and
// content-expression errors a hand-written schema can run into. Each one is a
// promise a host can rely on; none of them had a test.

/// A schema whose document content expression is the one under test.
private func schema(withDocContent content: String) throws(ModelError) -> Schema {
    try Schema(nodes: [
        ("doc", NodeSpec(content: content)),
        ("paragraph", NodeSpec(content: "text*", group: "block")),
        ("heading", NodeSpec(content: "text*", group: "block")),
        ("text", NodeSpec()),
    ])
}

func registerModelAPIEdgeTests() {
    // MARK: Child lookup

    test("childAfter: the child at or after an offset, with its index and start") {
        let para = B.p(B.t("ab"), B.img("x"), B.t("cd"))
        // "ab" spans 0..2, the image 2..3, "cd" 3..5.
        var r = para.childAfter(0)
        try expectEqual(r.node?.text, "ab"); try expectEqual(r.index, 0); try expectEqual(r.offset, 0)
        r = para.childAfter(1)
        try expectEqual(r.node?.text, "ab", "inside a text node still answers that node")
        r = para.childAfter(2)
        try expectEqual(r.node?.type.name, "image"); try expectEqual(r.index, 1); try expectEqual(r.offset, 2)
        r = para.childAfter(5)
        try expectNil(r.node)
        try expectEqual(r.index, 3)
    }

    test("childBefore: the child ending at or covering an offset") {
        let para = B.p(B.t("ab"), B.img("x"), B.t("cd"))
        var r = para.childBefore(0)
        try expectNil(r.node)
        r = para.childBefore(2)
        try expectEqual(r.node?.text, "ab", "at a boundary, the node that ends there")
        try expectEqual(r.index, 0); try expectEqual(r.offset, 0)
        r = para.childBefore(3)
        try expectEqual(r.node?.type.name, "image"); try expectEqual(r.index, 1); try expectEqual(r.offset, 2)
        r = para.childBefore(4)
        try expectEqual(r.node?.text, "cd", "inside a text node answers that node")
        try expectEqual(r.offset, 3)
    }

    // MARK: Hashing

    test("Node and Fragment: equal values hash alike, so a Set dedups them") {
        let a = B.doc(B.p("x"), B.p(B.strong("y")))
        let b = B.doc(B.p("x"), B.p(B.strong("y")))
        let c = B.doc(B.p("x"), B.p("y"))
        try expectEqual(a, b)
        try expectEqual(a.hashValue, b.hashValue)
        try expectEqual(Set([a, b, c]).count, 2)
        try expectEqual(Set([a.content, b.content, c.content]).count, 2)
        var byDoc: [Node: String] = [a: "first"]
        byDoc[b] = "second"
        try expectEqual(byDoc.count, 1, "an equal node is the same key")
        try expectEqual(byDoc[a], "second")
    }

    // MARK: Marks and traversal

    test("withMarks: the same node carrying a different mark set") {
        let plain = B.t("x")
        let bold = plain.withMarks([B.schema.mark("bold")])
        try expectEqual(bold.text, "x")
        try expectEqual(bold.marks.map(\.type.name), ["bold"])
        try expect(plain.marks.isEmpty, "the original is untouched")
    }

    test("Fragment.descendants: visits every node with its position and parent") {
        let frag = B.doc(B.blockquote(B.p("ab")), B.hr()).content
        var seen: [(String, Int, String?)] = []
        frag.descendants { node, pos, parent, _ in
            seen.append((node.type.name, pos, parent?.type.name))
            return true
        }
        try expectEqual(seen.map { "\($0.0)@\($0.1)<\($0.2 ?? "-")" },
                        ["blockquote@0<-", "paragraph@1<blockquote", "text@2<paragraph", "horizontalRule@6<-"])
        // Returning false skips a node's children.
        var shallow: [String] = []
        frag.descendants { node, _, _, _ in shallow.append(node.type.name); return false }
        try expectEqual(shallow, ["blockquote", "horizontalRule"])
    }

    test("Fragment.addToStart: prepends and grows the size") {
        let frag = Fragment.from([B.p("b")])
        let grown = frag.addToStart(B.p("a"))
        try expectEqual(grown.childCount, 2)
        try expectEqual(grown.firstChild?.textContent, "a")
        try expectEqual(grown.size, frag.size + B.p("a").nodeSize)
        try expectEqual(frag.childCount, 1, "fragments are values")
    }

    test("Slice.eq: compares content and open depths") {
        let d = B.doc(B.p("ab"), B.p("cd"))
        try expect(d.slice(2, 5).eq(d.slice(2, 5)))
        try expect(!d.slice(2, 5).eq(d.slice(1, 5)))
    }

    // MARK: JSON rejections

    test("Node.fromJSON: a node without a type is rejected") {
        try expectThrows { _ = try Node.fromJSON(B.schema, ["text": .string("x")]) }
    }
    test("Node.fromJSON: a text node without text is rejected") {
        try expectThrows { _ = try Node.fromJSON(B.schema, ["type": .string("text")]) }
    }
    test("Node.fromJSON: an unknown node type is rejected") {
        try expectThrows { _ = try Node.fromJSON(B.schema, ["type": .string("marquee")]) }
    }
    test("Fragment.fromJSON: a child that isn't an object is rejected") {
        try expectThrows { _ = try Fragment.fromJSON(B.schema, [.string("nope")]) }
        try expectEqual(try Fragment.fromJSON(B.schema, nil).size, 0)
        try expectEqual(try Fragment.fromJSON(B.schema, []).size, 0)
    }
    test("Node.fromJSON: a mark that isn't an object is rejected") {
        try expectThrows {
            _ = try Node.fromJSON(B.schema, ["type": .string("text"), "text": .string("x"), "marks": .array([.string("bold")])])
        }
    }
    test("Mark.fromJSON: a mark without a type, or of an unknown type, is rejected") {
        try expectThrows { _ = try Mark.fromJSON(B.schema, [:]) }
        try expectThrows { _ = try B.schema.markFromJSON(["type": .string("glow")]) }
        let bold = try B.schema.markFromJSON(["type": .string("bold")])
        try expectEqual(bold.type.name, "bold")
    }

    // MARK: Schema construction

    test("schema: the top node has to be one of the nodes") {
        try expectThrows {
            _ = try Schema(nodes: [("doc", NodeSpec(content: "text*")), ("text", NodeSpec())], topNode: "root")
        }
    }
    test("schema: a node's mark expression names marks, groups, everything, or nothing") {
        let s = try Schema(nodes: [
            ("doc", NodeSpec(content: "block+")),
            ("everything", NodeSpec(content: "text*", marks: "_", group: "block")),
            ("nothing", NodeSpec(content: "text*", marks: "", group: "block")),
            ("named", NodeSpec(content: "text*", marks: "bold", group: "block")),
            ("grouped", NodeSpec(content: "text*", marks: "styling", group: "block")),
            ("text", NodeSpec()),
        ], marks: [
            ("bold", MarkSpec(group: "styling")),
            ("italic", MarkSpec(group: "styling")),
            ("link", MarkSpec()),
        ])
        let bold = [s.mark("bold")], italic = [s.mark("italic")], link = [s.mark("link")]
        try expect(s.nodes["everything"]!.allowsMarks(link))
        try expect(!s.nodes["nothing"]!.allowsMarks(bold))
        try expect(s.nodes["named"]!.allowsMarks(bold))
        try expect(!s.nodes["named"]!.allowsMarks(italic))
        try expect(s.nodes["grouped"]!.allowsMarks(bold))
        try expect(s.nodes["grouped"]!.allowsMarks(italic))
        try expect(!s.nodes["grouped"]!.allowsMarks(link))
    }
    test("schema: a mark expression naming nothing that exists is rejected") {
        try expectThrows {
            _ = try Schema(nodes: [("doc", NodeSpec(content: "text*", marks: "sparkle")), ("text", NodeSpec())],
                           marks: [("bold", MarkSpec())])
        }
    }
    test("schema: node(...) with an unknown type name is an error, not a trap") {
        try expectThrows { _ = try B.schema.node("marquee") }
    }
    test("schema.mark: builds a mark of the type with its attributes") {
        let link = B.schema.mark(B.schema.marks["link"]!, ["href": .string("/x")])
        try expectEqual(link.attrs["href"], .string("/x"))
        try expectEqual(link.attrs["title"], .null, "an optional attribute takes its default")
    }
    test("NodeType.whitespace: reads the spec") {
        let s = try Schema(nodes: [
            ("doc", NodeSpec(content: "block+")),
            ("pre", NodeSpec(content: "text*", group: "block", whitespace: .pre)),
            ("paragraph", NodeSpec(content: "text*", group: "block")),
            ("text", NodeSpec()),
        ])
        try expectEqual(s.nodes["pre"]!.whitespace, .pre)
        try expectEqual(s.nodes["paragraph"]!.whitespace, .normal)
    }

    // MARK: Content expressions

    test("content expression: text after the expression is rejected") {
        try expectThrows { _ = try schema(withDocContent: "paragraph+ )") }
    }
    test("content expression: a range needs a number") {
        try expectThrows { _ = try schema(withDocContent: "paragraph{x}") }
    }
    test("content expression: a range needs its closing brace") {
        try expectThrows { _ = try schema(withDocContent: "paragraph{2") }
    }
    test("content expression: a group needs its closing paren") {
        try expectThrows { _ = try schema(withDocContent: "(paragraph | heading") }
    }
    test("content expression: it can't end after an operator") {
        try expectThrows { _ = try schema(withDocContent: "paragraph |") }
    }
    test("content expression: an unknown name is rejected") {
        try expectThrows { _ = try schema(withDocContent: "marquee+") }
    }
    test("content expression: {n,} is an open-ended range and {n,m} a closed one") {
        let open = try schema(withDocContent: "paragraph{2,}")
        let p = open.nodes["paragraph"]!
        try expect(!open.topNodeType.validContent(Fragment.from([try p.create()])))
        try expect(open.topNodeType.validContent(Fragment.from([try p.create(), try p.create(), try p.create()])))
        let closed = try schema(withDocContent: "paragraph{1,2}")
        try expect(closed.topNodeType.validContent(Fragment.from([try p.create()].map { _ in try! closed.nodes["paragraph"]!.create() })))
        try expect(!closed.topNodeType.validContent(Fragment.from((0..<3).map { _ in try! closed.nodes["paragraph"]!.create() })))
    }
    test("content expression: a character outside the grammar is rejected") {
        // Anything that is neither a name nor one of the operators becomes a
        // token of its own, which then fails as an unknown name — it isn't
        // silently skipped the way whitespace is.
        try expectThrows { _ = try schema(withDocContent: "paragraph & heading") }
        try expectThrows { _ = try schema(withDocContent: "paragraph.") }
        // The same names without the stray character compile.
        _ = try schema(withDocContent: "paragraph heading")
    }
    test("content expression: two readings of one type merge into a single state") {
        // `heading` can start the sequence *or* be the whole `block` choice, so
        // after one heading the match has to allow both stopping and carrying
        // on with a paragraph.
        let s = try schema(withDocContent: "heading paragraph | block")
        let h = s.nodes["heading"]!, p = s.nodes["paragraph"]!
        let doc = s.topNodeType
        try expect(doc.validContent(Fragment.from([try h.create()])))
        try expect(doc.validContent(Fragment.from([try h.create(), try p.create()])))
        try expect(doc.validContent(Fragment.from([try p.create()])))
        try expect(!doc.validContent(Fragment.from([try p.create(), try p.create()])))
        try expect(!doc.validContent(Fragment.from([try h.create(), try h.create()])))
        let afterHeading = doc.contentMatch.matchType(h)
        try expect(afterHeading?.validEnd == true)
        try expectEqual(afterHeading?.edgeTypes.map(\.name), ["paragraph"])
    }
    test("content expression: an operator with nothing before it is a stray token") {
        // "+" on its own is tokenized as punctuation and then rejected as a
        // name; the point is that it fails rather than compiling to anything.
        try expectThrows { _ = try schema(withDocContent: "+paragraph") }
    }

    // MARK: Content matching on nodes

    test("defaultType: the first type a fill could generate, or none") {
        // Text can't be generated from nothing, and neither can a node with a
        // required attribute: an inline match skips both and settles on the
        // hard break, a text-only one has nothing to offer.
        let s = B.schema
        try expectEqual(s.nodes["paragraph"]!.contentMatch.defaultType?.name, "hardBreak")
        try expectNil(s.nodes["codeBlock"]!.contentMatch.defaultType)
        try expectEqual(s.nodes["doc"]!.contentMatch.defaultType?.name, "paragraph")
        // A leaf's match has no edges at all, so nothing either.
        try expectNil(s.nodes["horizontalRule"]!.contentMatch.defaultType)
    }

    test("canAppend: an empty node appends when its content is compatible") {
        // With nothing to append, the question is whether the two types could
        // share content at all — the same type, or overlapping expressions.
        let para = B.p("a")
        try expect(para.canAppend(B.p()))
        try expect(para.canAppend(B.h(1)), "heading and paragraph both hold inline*")
        try expect(!para.canAppend(B.hr()), "a leaf has no content to share")
        try expect(!para.canAppend(B.node("bulletList")), "list items are not inline")
        // With content, the content itself has to fit.
        try expect(para.canAppend(B.h(1, B.t("b"))))
        try expect(!para.canAppend(B.blockquote(B.p("b"))))
    }

    test("contentMatchAt: content the expression rejects answers the start state") {
        // `create` doesn't validate, so a node can hold content its expression
        // can't match. ProseMirror throws here; this port answers the type's
        // start state instead, so a query on such a node degrades rather than
        // trapping.
        let paragraph = B.schema.nodes["paragraph"]!
        let broken = try paragraph.create(content: Fragment.from(B.p("x")))
        try expect(broken.contentMatchAt(1) === paragraph.contentMatch)
        try expect(broken.contentMatchAt(0) === paragraph.contentMatch)
        // A valid node's match moves on past its children.
        try expect(B.p("x").contentMatchAt(1) !== paragraph.contentMatch)
    }
}

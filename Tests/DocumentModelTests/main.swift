import Foundation
import DocumentModel
import TestHarness

let collector = TestCollector()
func test(_ name: String, _ body: @escaping @Sendable () throws -> Void) {
    collector.test(name, body)
}

// MARK: - Node basics

test("node sizes") {
    let doc = B.doc(B.p("hello"))
    try expectEqual(doc.child(0).nodeSize, 7)
    try expectEqual(doc.content.size, 7)
    try expectEqual(B.t("hello").nodeSize, 5)
    try expectEqual(B.br().nodeSize, 1)
    try expectEqual(B.hr().nodeSize, 1)
}

test("text content / textBetween") {
    let doc = B.doc(B.p("hello"), B.p("world"))
    try expectEqual(doc.textBetween(0, doc.content.size, blockSeparator: " "), "hello world")
}

test("textBetween: only blocks that render a line get a separator") {
    // A wrapper contributes no text of its own, so it must not open a line.
    // Counting one per block put a blank line in front of every nested block —
    // which is what the plain-text copy and `plainText` paths read.
    let quote = B.doc(B.blockquote(B.p("a"), B.p("b")))
    try expectEqual(quote.textBetween(0, quote.content.size, blockSeparator: "\n"), "a\nb")

    let list = B.doc(B.ul(B.li(B.p("x"))), B.p("y"))
    try expectEqual(list.textBetween(0, list.content.size, blockSeparator: "\n"), "x\ny")

    // A block leaf with no text of its own doesn't open a line either.
    let rule = B.doc(B.p("a"), B.hr(), B.p("b"))
    try expectEqual(rule.textBetween(0, rule.content.size, blockSeparator: "\n"), "a\nb")
}

test("equality and structural sharing") {
    let a = B.doc(B.p("a"), B.p("b"))
    let b = B.doc(B.p("a"), B.p("b"))
    try expectEqual(a, b)
    try expect(a.eq(b))
    try expect(a != B.doc(B.p("a"), B.p("c")))
}

test("cut text") {
    let doc = B.doc(B.p("hello world"))
    let cut = doc.cut(1, 6)
    try expectEqual(cut.textContent, "hello")
}

test("nodeAt") {
    let doc = B.doc(B.p("hi"), B.p("yo"))
    try expectEqual(doc.nodeAt(1)?.text, "hi")
}

test("rangeHasMark") {
    let doc = B.doc(B.p(B.t("plain "), B.strong("bold")))
    try expect(doc.rangeHasMark(1, doc.content.size, B.schema.marks["bold"]!))
    try expect(!doc.rangeHasMark(1, 7, B.schema.marks["bold"]!))
}

test("JSON round-trip") {
    let doc = B.doc(B.h(2, B.t("Title")),
                    B.p(B.t("Hello "), B.strong("world")),
                    B.ul(B.li(B.p("item"))))
    let restored = try Node.fromJSON(B.schema, doc.toJSON())
    try expectEqual(doc, restored)
}

// MARK: - Marks

test("mark addToSet keeps sorted, dedups") {
    let bold = B.schema.mark("bold")
    let italic = B.schema.mark("italic")
    let set = italic.addToSet(bold.addToSet([]))
    try expectEqual(set.count, 2)
    // bold has lower rank than italic in TestSchema (italic, bold order -> ranks)
    try expect(Mark.sameSet(bold.addToSet(set), set), "adding existing mark is a no-op")
}

test("code mark excludes others (excludes _)") {
    let code = B.schema.mark("code")
    let bold = B.schema.mark("bold")
    // code excludes everything (excludes: "_"), so adding bold onto a set that
    // already has code leaves the set unchanged (bold is rejected).
    let set = bold.addToSet(code.addToSet([]))
    try expectEqual(set, [code])
    // Conversely, adding code onto a bold set drops bold.
    let set2 = code.addToSet(bold.addToSet([]))
    try expectEqual(set2, [code])
}

// MARK: - ResolvedPos

test("resolve position depth/parent") {
    let doc = B.doc(B.blockquote(B.p("hi")))
    // doc(0) > blockquote(1) > p(2) ; pos 2 is inside the paragraph at "h|i" start
    let r = doc.resolve(2)
    try expectEqual(r.depth, 2)
    try expectEqual(r.parent.type.name, "paragraph")
    try expectEqual(r.node(1).type.name, "blockquote")
}

test("resolve start/end/before/after") {
    let doc = B.doc(B.p("ab"), B.p("cd"))
    let r = doc.resolve(1) // start of first paragraph content
    try expectEqual(r.start(1), 1)
    try expectEqual(r.end(1), 3)
    try expectEqual(r.before(1), 0)
    try expectEqual(r.after(1), 4)
}

// MARK: - Slice / replace

test("slice openStart/openEnd") {
    let doc = B.doc(B.p("hello"), B.p("world"))
    let slice = doc.slice(2, 8) // from inside first p to inside second p
    try expectEqual(slice.openStart, 1)
    try expectEqual(slice.openEnd, 1)
}

test("replace: delete within paragraph") {
    let doc = B.doc(B.p("hello world"))
    let result = try doc.replace(1, 6, .empty) // delete "hello"
    try expectEqual(result, B.doc(B.p(" world")))
}

test("replace: insert text") {
    let doc = B.doc(B.p("ad"))
    let slice = Slice(content: Fragment.from(B.t("bc")), openStart: 0, openEnd: 0)
    let result = try doc.replace(2, 2, slice)
    try expectEqual(result, B.doc(B.p("abcd")))
}

test("replace: raw replace across block boundary throws (join is a Transform concern)") {
    let doc = B.doc(B.p("foo"), B.p("bar"))
    // from depth 1 (end of p1) to depth 0 (between blocks) with an empty slice
    // is an inconsistent-open-depths replace; joining is handled by Transform.
    try expectThrows {
        _ = try doc.replace(4, 5, .empty)
    }
}

// MARK: - ContentMatch

test("content match: paragraph accepts inline, rejects block") {
    let para = B.schema.nodes["paragraph"]!
    let text = B.schema.nodes["text"]!
    try expectNotNil(para.contentMatch.matchType(text))
}

test("content match: doc requires block+") {
    let doc = B.schema.nodes["doc"]!
    let para = B.schema.nodes["paragraph"]!
    let afterOne = doc.contentMatch.matchType(para)
    try expectNotNil(afterOne)
    try expect(afterOne!.validEnd, "one paragraph is a valid doc")
    try expect(!doc.contentMatch.validEnd, "empty doc content is invalid")
}

test("createAndFill fills required content") {
    let doc = B.schema.nodes["doc"]!
    let filled = doc.createAndFill()
    try expectNotNil(filled)
    // doc must contain at least one block, and it should prefer a paragraph
    // (schema definition order) rather than recursing into blockquote.
    try expect(filled!.childCount >= 1)
    try expectEqual(filled!.child(0).type.name, "paragraph")
}

test("createAndFill puts the required content in front of what it is given") {
    // `listItem` is "paragraph block*", so a bare blockquote needs an empty
    // paragraph ahead of it. Computing the trailing fill before that leading
    // one made the match fail and dropped the content entirely.
    let listItem = B.schema.nodes["listItem"]!
    let filled = listItem.createAndFill([:], content: Fragment.from(B.blockquote(B.p("a"))))
    try expectNotNil(filled)
    try expectEqual(filled!.childCount, 2)
    try expectEqual(filled!.child(0).type.name, "paragraph")
    try expectEqual(filled!.child(1).type.name, "blockquote")
    try filled!.check()
}

test("findWrapping: paragraph into blockquote") {
    let bq = B.schema.nodes["blockquote"]!
    let para = B.schema.nodes["paragraph"]!
    let wrapping = bq.contentMatch.findWrapping(para)
    try expectNotNil(wrapping)
}

test("findWrapping: a wrapper it cannot satisfy is not offered") {
    // Same shape as the shipped `details` node — a container whose content is a
    // fixed two-node sequence. Wrapping into `summary` alone would leave the
    // container missing its `body`, so it is not a wrapping at all.
    let nodes: [(String, NodeSpec)] = [
        ("doc", NodeSpec(content: "container+")),
        ("container", NodeSpec(content: "summary body")),
        ("summary", NodeSpec(content: "paragraph")),
        ("body", NodeSpec(content: "paragraph+")),
        ("paragraph", NodeSpec(content: "inline*")),
        ("text", NodeSpec(group: "inline")),
    ]
    let schema = try Schema(nodes: nodes, marks: [], topNode: "doc")
    let wrapping = schema.topNodeType.contentMatch.findWrapping(schema.nodes["paragraph"]!)
    try expect(wrapping?.map(\.name) != ["container", "summary"],
               "offered a wrapping that leaves the container incomplete")

    // Whatever it does offer has to actually build a valid node.
    if let wrapping {
        var node = try schema.nodes["paragraph"]!.create()
        for type in wrapping.reversed() {
            let built = type.createAndFill([:], content: Fragment.from(node))
            try expect(built != nil, "could not build \(type.name) around the wrapped content")
            node = built!
        }
        try node.check()
    }
}

test("schema: a document does not keep its schema alive") {
    // The back-reference from a type to its schema is non-owning on purpose:
    // the schema owns its types, so a strong reference back would be a cycle
    // that leaks every schema ever built. This pins that — if the reference
    // ever becomes strong, the schema below outlives the block and this fails.
    weak var released: Schema?
    do {
        let schema = try Schema(nodes: [
            ("doc", NodeSpec(content: "paragraph+")),
            ("paragraph", NodeSpec(content: "text*")),
            ("text", NodeSpec()),
        ], marks: [], topNode: "doc")
        released = schema
        let doc = try schema.node("doc", [:], content: Fragment.from([
            try schema.node("paragraph", [:], content: Fragment.from([schema.text("x")])),
        ]))
        try expectEqual(doc.childCount, 1)
        try expect(released != nil, "the schema is alive while it is in scope")
    }
    try expect(released == nil, "a schema outlived its scope — the back-reference is a cycle")
}

test("schema: a type reaches its schema while it is alive") {
    // The other half: non-owning doesn't mean absent. Every type the schema
    // built points back at it, which is what the table and transform code
    // reads to find sibling types.
    let schema = try Schema(nodes: [
        ("doc", NodeSpec(content: "paragraph+")),
        ("paragraph", NodeSpec(content: "text*")),
        ("text", NodeSpec()),
    ], marks: [], topNode: "doc")
    let doc = try schema.node("doc", [:], content: Fragment.from([
        try schema.node("paragraph", [:], content: Fragment.empty),
    ]))
    try expect(doc.type.schema === schema, "a node's type should reach the schema that built it")
    try expect(doc.child(0).type.schema === schema)
}

test("text positions are grapheme-cluster offsets") {
    // A position counts Characters, not scalars and not bytes, so slicing by
    // index has to land where slicing an `Array(text)` would. These strings are
    // the ones where those three disagree: a combining mark, regional indicator
    // pairs, ZWJ sequences with a skin tone, a CRLF (one Character, two line
    // endings), an Indic cluster, and a Prepend scalar in front of ASCII.
    let samples = ["e\u{0301}cole", "\u{1F1EF}\u{1F1F5}\u{1F1FA}\u{1F1F8}ab",
                   "\u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F467}x\u{1F468}\u{1F3FD}\u{200D}\u{1F680}y",
                   "a\r\nb\r\nc", "\u{0600}*x", "a\u{03C0}\u{65E5}z"]
    for s in samples {
        let chars = Array(s)
        try expectEqual(B.t(s).nodeSize, chars.count, "size of \(s.debugDescription)")
        for from in 0...chars.count {
            for to in from...chars.count {
                try expectEqual(B.t(s).cut(from, to).text ?? "", String(chars[from..<to]),
                                "cut(\(from),\(to)) of \(s.debugDescription)")
                let doc = B.doc(B.p(s))
                // +1 for the paragraph's opening token.
                try expectEqual(doc.textBetween(from + 1, to + 1), String(chars[from..<to]),
                                "textBetween(\(from),\(to)) of \(s.debugDescription)")
                let slice = doc.slice(from + 1, to + 1)
                try expectEqual(slice.content.textBetween(0, slice.content.size),
                                String(chars[from..<to]),
                                "slice(\(from),\(to)) of \(s.debugDescription)")
            }
        }
    }
}

registerBench()

registerAttributeValueTests()
registerStorageIdentityTests()

TestSuite.main("DocumentModelTests", collector.all)

import Foundation
import DocumentModel
import DocumentTransform
import TestHarness

// The second half of prosemirror-transform/test/test-trans.ts: the `replace`
// cases that need the Fitter to drop, open, or wrap unplaceable content, and
// the `replaceRange` / `replaceRangeWith` / `deleteRange` / `insert` /
// node-mark / attribute suites, none of which had been ported. Several run
// against schemas upstream builds on the fly (a heading-then-body document, an
// optional title, fixed cell content, an isolating block); those are built by
// hand below.
//
// Skipped: `replaceRange` "keeps defining context when it doesn't match the
// parent markup" (needs `definingForContent` / `definingAsContext`, which the
// Swift `NodeSpec` doesn't have) and `removeNodeMark` with a `MarkType` (a
// known gap, see docs/upstream-versions.md).

/// Doc equality plus the two round trips every transform must survive:
/// inverting its steps restores the input, and its steps decode from JSON to
/// the same result.
private func verify(_ tr: Transform, _ before: Node, _ expect: Node, _ schema: Schema) throws {
    try expectEqual(tr.doc, expect)
    let inv = Transform(tr.doc)
    for i in stride(from: tr.steps.count - 1, through: 0, by: -1) {
        try inv.step(tr.steps[i].invert(tr.docs[i]))
    }
    try expectEqual(inv.doc, before, "inverting the steps should restore the input")
    let again = Transform(before)
    for s in tr.steps { try again.step(decodeStep(schema, s.toJSON())) }
    try expectEqual(again.doc, expect, "steps should survive JSON")
}

private func verify(_ tr: Transform, _ before: TaggedNode, _ expect: TaggedNode) throws {
    try verify(tr, before.node, expect.node, basicSchema)
    for (name, from) in before.tags where expect.tags[name] != nil {
        try expectEqual(tr.mapping.map(from, 1), expect.tags[name]!, "tag <\(name)>")
    }
}

private func tagOpt(_ t: TaggedNode, _ name: String) -> Int? { t.tags[name] }

// MARK: - Schemas upstream builds inline

/// The node and mark specs `basicSchema` is built from (prosemirror-test-builder's
/// basic + list schema), for the variants below.
private let basicNodes: [(String, NodeSpec)] = [
    ("doc", NodeSpec(content: "block+")),
    ("paragraph", NodeSpec(content: "inline*", group: "block")),
    ("blockquote", NodeSpec(content: "block+", group: "block", defining: true)),
    ("horizontal_rule", NodeSpec(group: "block")),
    ("heading", NodeSpec(content: "inline*", group: "block",
                         attrs: ["level": AttributeSpec(default: .int(1))], defining: true)),
    ("code_block", NodeSpec(content: "text*", marks: "", group: "block", code: true, defining: true)),
    ("text", NodeSpec(group: "inline")),
    ("image", NodeSpec(group: "inline", inline: true,
                       attrs: ["src": AttributeSpec(), "alt": AttributeSpec(default: .null), "title": AttributeSpec(default: .null)])),
    ("hard_break", NodeSpec(group: "inline", inline: true)),
    ("ordered_list", NodeSpec(content: "list_item+", group: "block", attrs: ["order": AttributeSpec(default: .int(1))])),
    ("bullet_list", NodeSpec(content: "list_item+", group: "block")),
    ("list_item", NodeSpec(content: "paragraph block*", defining: true)),
]
private let basicMarks: [(String, MarkSpec)] = [
    ("link", MarkSpec(attrs: ["href": AttributeSpec(), "title": AttributeSpec(default: .null)], inclusive: false)),
    ("em", MarkSpec()),
    ("strong", MarkSpec()),
    ("code", MarkSpec()),
]

/// The basic schema with marks allowed on the top-level blocks.
private let markedBlockSchema: Schema = {
    var nodes = basicNodes
    nodes[0] = ("doc", NodeSpec(content: "block+", marks: "_"))
    return try! Schema(nodes: nodes, marks: basicMarks, topNode: "doc")
}()

/// A document that is a heading followed by a body of blocks.
private let headingBodySchema: Schema = {
    var nodes = basicNodes
    nodes[0] = ("doc", NodeSpec(content: "heading body"))
    nodes.append(("body", NodeSpec(content: "block+")))
    return try! Schema(nodes: nodes, marks: basicMarks, topNode: "doc")
}()

/// A document with an optional title before its blocks.
private let titleSchema: Schema = {
    var nodes = basicNodes
    nodes[0] = ("doc", NodeSpec(content: "title? block*"))
    nodes.append(("title", NodeSpec(content: "text*")))
    return try! Schema(nodes: nodes, marks: basicMarks, topNode: "doc")
}()

/// The basic schema plus an isolating block.
private let isolatingSchema: Schema = {
    var nodes = basicNodes
    nodes.append(("iso", NodeSpec(content: "block+", group: "block", isolating: true)))
    return try! Schema(nodes: nodes, marks: basicMarks, topNode: "doc")
}()

private func n(_ s: Schema, _ type: String, _ attrs: Attrs = [:], _ content: [Node] = []) -> Node {
    try! s.node(type, attrs, content: Fragment.from(content))
}
private func n(_ s: Schema, _ type: String, _ text: String) -> Node {
    try! s.node(type, [:], content: Fragment.from([s.text(text)]))
}

// Builders for the heading-body schema.
private func hbDoc(_ heading: Node, _ body: Node) -> Node { n(headingBodySchema, "doc", [:], [heading, body]) }
private func hbH(_ text: String = "") -> Node {
    let hb = headingBodySchema
    return try! hb.node("heading", ["level": .int(1)], content: text.isEmpty ? .empty : Fragment.from([hb.text(text)]))
}
private func hbP(_ text: String = "") -> Node {
    let hb = headingBodySchema
    return try! hb.node("paragraph", [:], content: text.isEmpty ? .empty : Fragment.from([hb.text(text)]))
}
private func hbB(_ blocks: Node...) -> Node { n(headingBodySchema, "body", [:], blocks) }

func registerPMReplaceRangeTests() {
    // MARK: replace (continued)

    func repl(_ name: String, _ d: TaggedNode, _ source: TaggedNode?, _ e: TaggedNode) {
        test("PM replace: \(name)") {
            let slice = source.map { $0.node.slice(tag($0, "a"), tag($0, "b")) } ?? Slice.empty
            let tr = Transform(d.node)
            try tr.replace(tag(d, "a"), tagOpt(d, "b") ?? tag(d, "a"), slice)
            try verify(tr, d, e)
        }
    }
    func replSlice(_ name: String, _ d: TaggedNode, _ slice: Slice, _ e: TaggedNode) {
        test("PM replace: \(name)") {
            let tr = Transform(d.node)
            try tr.replace(tag(d, "a"), tagOpt(d, "b") ?? tag(d, "a"), slice)
            try verify(tr, d, e)
        }
    }

    repl("accepts lopsided regions",
         doc(blockquote(p("b<a>c"), p("d<b>e"), p("f"))),
         doc(blockquote(p("x<a>y")), p("z<b>")),
         doc(blockquote(p("b<a>y")), p("z<b>e"), blockquote(p("f"))))
    repl("can close nested parent nodes",
         doc(blockquote(blockquote(p("one"), p("tw<a>o"), p("t<b>hree<3>"), p("four<4>")))),
         doc(ol(li(p("hello<a>world")), li(p("bye"))), p("ne<b>xt")),
         doc(blockquote(blockquote(p("one"), p("tw<a>world"), ol(li(p("bye"))), p("ne<b>hree<3>"), p("four<4>")))))
    repl("will close open nodes to the right",
         doc(p("x"), "<a>"),
         doc("<a>", ul(li(p("a")), li("<b>", p("b")))),
         doc(p("x"), ul(li(p("a")), li(p())), "<a>"))
    repl("can delete the whole document",
         doc("<a>", h1("hi"), p("you"), "<b>"), nil, doc(p()))
    repl("preserves an empty parent to the left",
         doc(blockquote("<a>", p("hi")), p("b<b>x")),
         doc(p("<a>hi<b>")),
         doc(blockquote(p("hix"))))
    repl("drops an empty parent to the right",
         doc(p("x<a>hi"), blockquote(p("yy"), "<b>"), p("c")),
         doc(p("<a>hi<b>")),
         doc(p("xhi"), p("c")))
    repl("drops an empty node at the start of the slice",
         doc(p("<a>x")),
         doc(blockquote(p("hi"), "<a>"), p("b<b>")),
         doc(p(), p("bx")))
    repl("drops an empty node at the end of the slice",
         doc(p("<a>x")),
         doc(p("b<a>"), blockquote("<b>", p("hi"))),
         doc(p(), blockquote(p()), p("x")))
    replSlice("does nothing when given an unfittable slice",
              p("<a>x"),
              Slice(content: Fragment.from([blockquote().node, hr().node]), openStart: 0, openEnd: 0),
              p("x"))
    repl("doesn't drop content when things only fit at the top level",
         doc(p("foo"), "<a>", p("bar<b>")),
         ol(li(p("<a>a")), li(p("b<b>"))),
         doc(p("foo"), p("a"), ol(li(p("b")))))
    replSlice("preserves openEnd when top isn't placed",
              doc(ul(li(p("ab<a>cd")), li(p("ef<b>gh")))),
              doc(ul(li(p("ABCD")), li(p("EFGH")))).node.slice(5, 13, includeParents: true),
              doc(ul(li(p("abCD")), li(p("EFgh")))))
    repl("will auto-close a list item when it fits in a list",
         doc(ul(li(p("foo")), "<a>", li(p("bar")))),
         ul(li(p("a<a>bc")), li(p("de<b>f"))),
         doc(ul(li(p("foo")), li(p("bc")), li(p("de")), li(p("bar")))))
    replSlice("finds the proper openEnd value when unwrapping a deep slice",
              doc("<a>", p(), "<b>"),
              doc(blockquote(blockquote(blockquote(p("hi"))))).node.slice(3, 6, includeParents: true),
              doc(p("hi")))

    test("PM replace: preserves marks on block nodes") {
        let s = markedBlockSchema
        let d = n(s, "doc", [:], [
            try s.node("paragraph", [:], content: Fragment.from([s.text("hey")]), marks: [s.mark("em")]),
            try s.node("paragraph", [:], content: Fragment.from([s.text("ok")]), marks: [s.mark("strong")]),
        ])
        let tr = Transform(d)
        try tr.replace(2, 7, d.slice(2, 7))
        try expectEqual(tr.doc, d)
    }
    test("PM replace: preserves marks on open slice block nodes") {
        let s = markedBlockSchema
        let d = n(s, "doc", [:], [n(s, "paragraph", "a")])
        let source = n(s, "doc", [:], [
            try s.node("paragraph", [:], content: Fragment.from([s.text("b")]), marks: [s.mark("em")]),
        ])
        let tr = Transform(d)
        try tr.replace(3, 3, source.slice(1, 3))
        try expectEqual(tr.doc.childCount, 2)
        try expectEqual(tr.doc.lastChild?.marks.count, 1)
    }

    // A heading, then a body: every replacement has to keep that shape.
    let hb = headingBodySchema
    test("PM replace: can unwrap a paragraph when replacing into a strict schema") {
        let d = hbDoc(hbH("Head"), hbB(hbP("Content")))
        let tr = Transform(d)
        try tr.replace(0, d.content.size, d.slice(7, 16))
        try verify(tr, d, hbDoc(hbH("Content"), hbB(hbP())), hb)
    }
    test("PM replace: can unwrap a body after a placed node") {
        let d = hbDoc(hbH("Head"), hbB(hbP("Content")))
        let tr = Transform(d)
        try tr.replace(7, 7, d.slice(0, d.content.size))
        try verify(tr, d, hbDoc(hbH("Head"), hbB(hbH("Head"), hbP("Content"), hbP("Content"))), hb)
    }
    test("PM replace: can wrap a paragraph in a body, even when it's not the first node") {
        let d = hbDoc(hbH("Head"), hbB(hbP("One"), hbP("Two")))
        let tr = Transform(d)
        try tr.replace(0, d.content.size, d.slice(8, 16))
        try verify(tr, d, hbDoc(hbH("One"), hbB(hbP("Two"))), hb)
    }
    test("PM replace: can split a fragment and place its children in different parents") {
        let d = hbDoc(hbH("Head"), hbB(hbH("One"), hbP("Two")))
        let tr = Transform(d)
        try tr.replace(0, d.content.size, d.slice(7, 17))
        try verify(tr, d, hbDoc(hbH("One"), hbB(hbP("Two"))), hb)
    }
    test("PM replace: will insert filler nodes before a node when necessary") {
        let d = hbDoc(hbH("Head"), hbB(hbP("One")))
        let tr = Transform(d)
        try tr.replace(0, d.content.size, d.slice(6, d.content.size))
        try verify(tr, d, hbDoc(hbH(), hbB(hbP("One"))), hb)
    }

    let ts = titleSchema
    test("PM replace: doesn't fail when moving text would solve an unsatisfied content constraint") {
        let d = n(ts, "doc", [:], [n(ts, "title", "hi")])
        let list = n(ts, "bullet_list", [:], [
            n(ts, "list_item", [:], [n(ts, "paragraph", "one")]),
            n(ts, "list_item", [:], [n(ts, "paragraph", "two")]),
        ])
        let tr = Transform(d)
        try tr.replace(1, 1, list.slice(2, 12))
        try expect(tr.steps.count > 0)
        try tr.doc.check()
    }
    test("PM replace: doesn't fail when pasting a half-open slice with a title and a code block into an empty title") {
        let d = n(ts, "doc", [:], [n(ts, "title")])
        let source = n(ts, "doc", [:], [n(ts, "title", "title"), n(ts, "code_block", "two")])
        let tr = Transform(d)
        try tr.replace(1, 1, source.slice(1))
        try expect(tr.steps.count > 0)
        try tr.doc.check()
    }
    test("PM replace: doesn't fail when pasting a half-open slice with a heading and a code block into an empty title") {
        let d = n(ts, "doc", [:], [n(ts, "title")])
        let source = n(ts, "doc", [:], [
            n(ts, "heading", ["level": .int(1)], [ts.text("heading")]),
            n(ts, "code_block", "code"),
        ])
        let tr = Transform(d)
        try tr.replace(1, 1, source.slice(1))
        try expect(tr.steps.count > 0)
        try tr.doc.check()
    }

    test("PM replace: can handle replacing in nodes with fixed content") {
        let s = try Schema(nodes: [
            ("doc", NodeSpec(content: "block+")),
            ("a", NodeSpec(content: "inline*")),
            ("b", NodeSpec(content: "inline*")),
            ("block", NodeSpec(content: "a b")),
            ("text", NodeSpec(group: "inline")),
        ])
        let d = n(s, "doc", [:], [n(s, "block", [:], [n(s, "a", "aa"), n(s, "b", "bb")])])
        let from = 3, to = d.content.size
        let tr = Transform(d)
        try tr.replace(from, to, d.slice(from, to))
        try expectEqual(tr.doc, d)
    }

    test("PM replace: keeps isolating nodes together") {
        let s = isolatingSchema
        let d = n(s, "doc", [:], [n(s, "paragraph", "one")])
        let iso = Fragment.from(n(s, "iso", [:], [n(s, "paragraph", "two")]))
        let open = Transform(d)
        try open.replace(2, 3, Slice(content: iso, openStart: 2, openEnd: 0))
        try expectEqual(open.doc, n(s, "doc", [:], [
            n(s, "paragraph", "o"),
            n(s, "iso", [:], [n(s, "paragraph", "two")]),
            n(s, "paragraph", "e"),
        ]))
        let closed = Transform(d)
        try closed.replace(2, 3, Slice(content: iso, openStart: 2, openEnd: 2))
        try expectEqual(closed.doc, n(s, "doc", [:], [n(s, "paragraph", "otwoe")]))
    }

    // MARK: replaceRange

    func rr(_ name: String, _ d: TaggedNode, _ source: TaggedNode?, _ e: TaggedNode) {
        test("PM replaceRange: \(name)") {
            let slice = source.map { $0.node.slice(tag($0, "a"), tag($0, "b"), includeParents: true) } ?? Slice.empty
            let tr = Transform(d.node)
            try tr.replaceRange(tag(d, "a"), tagOpt(d, "b") ?? tag(d, "a"), slice)
            try verify(tr, d, e)
        }
    }
    rr("replaces inline content", doc(p("foo<a>b<b>ar")), p("<a>xx<b>"), doc(p("foo<a>xx<b>ar")))
    rr("replaces an empty paragraph with a heading", doc(p("<a>")), doc(h1("<a>text<b>")), doc(h1("text")))
    rr("replaces a fully selected paragraph with a heading", doc(p("<a>abc<b>")), doc(h1("<a>text<b>")), doc(h1("text")))
    rr("recreates a list when overwriting a paragraph", doc(p("<a>")), doc(ul(li(p("<a>foobar<b>")))), doc(ul(li(p("foobar")))))
    rr("drops context when it doesn't fit", doc(ul(li(p("<a>")), li(p("b")))), doc(h1("<a>h<b>")), doc(ul(li(p("h<a>")), li(p("b")))))
    rr("can replace a node when endpoints are in different children",
       doc(p("a"), ul(li(p("<a>b")), li(p("c"), blockquote(p("d<b>")))), p("e")),
       doc(h1("<a>x<b>")),
       doc(p("a"), h1("x"), p("e")))
    rr("keeps defining context when inserting at the start of a textblock",
       doc(p("<a>foo")),
       doc(ul(li(p("<a>one")), li(p("two<b>")))),
       doc(ul(li(p("one")), li(p("twofoo")))))
    rr("drops defining context when it matches the parent structure",
       doc(blockquote(p("<a>"))), doc(blockquote(p("<a>one<b>"))), doc(blockquote(p("one"))))
    rr("drops defining context when it matches the parent structure in a nested context",
       doc(ul(li(p("list1"), blockquote(p("<a>"))))),
       doc(blockquote(p("<a>one<b>"))),
       doc(ul(li(p("list1"), blockquote(p("one"))))))
    rr("drops defining context when it matches the parent structure in a deep nested context",
       doc(ul(li(p("list1"), ul(li(p("list2"), blockquote(p("<a>"))))))),
       doc(blockquote(p("<a>one<b>"))),
       doc(ul(li(p("list1"), ul(li(p("list2"), blockquote(p("one"))))))))
    rr("closes open nodes at the start",
       doc("<a>", p("abc"), "<b>"),
       doc(ul(li("<a>")), p("def"), "<b>"),
       doc(ul(li(p())), p("def")))

    // MARK: replaceRangeWith

    func rrw(_ name: String, _ d: TaggedNode, _ node: TaggedNode, _ e: TaggedNode) {
        test("PM replaceRangeWith: \(name)") {
            let tr = Transform(d.node)
            try tr.replaceRangeWith(tag(d, "a"), tagOpt(d, "b") ?? tag(d, "a"), node.node)
            try verify(tr, d, e)
        }
    }
    rrw("can insert an inline node", doc(p("fo<a>o")), img(), doc(p("fo", img(), "<a>o")))
    rrw("can replace content with an inline node", doc(p("<a>fo<b>o")), img(), doc(p("<a>", img(), "o")))
    rrw("can replace a block node with an inline node", doc("<a>", blockquote(p("a")), "<b>"), img(), doc(p(img())))
    rrw("can replace a block node with a block node", doc("<a>", blockquote(p("a")), "<b>"), hr(), doc(hr()))
    rrw("can insert a block quote in the middle of text", doc(p("foo<a>bar")), hr(), doc(p("foo"), hr(), p("bar")))
    rrw("can replace empty parents with a block node", doc(blockquote(p("<a>"))), hr(), doc(blockquote(hr())))
    rrw("can move an inserted block forward out of parent nodes", doc(h1("foo<a>")), hr(), doc(h1("foo"), hr()))
    rrw("can move an inserted block backward out of parent nodes",
        doc(p("a"), blockquote(p("<a>b"))), hr(), doc(p("a"), blockquote(hr(), p("b"))))

    // MARK: deleteRange

    func del(_ name: String, _ d: TaggedNode, _ e: TaggedNode) {
        test("PM deleteRange: \(name)") {
            let tr = Transform(d.node)
            try tr.deleteRange(tag(d, "a"), tagOpt(d, "b") ?? tag(d, "a"))
            try verify(tr, d, e)
        }
    }
    del("deletes the given range", doc(p("fo<a>o"), p("b<b>ar")), doc(p("fo<a><b>ar")))
    del("deletes empty parent nodes",
        doc(blockquote(ul(li("<a>", p("foo"), "<b>")), p("x"))),
        doc(blockquote("<a><b>", p("x"))))
    del("doesn't delete parent nodes that can be empty", doc(p("<a>foo<b>")), doc(p("<a><b>")))
    del("is okay with deleting empty ranges", doc(p("<a><b>")), doc(p("<a><b>")))
    del("will delete a whole covered node even if selection ends are in different nodes",
        doc(ul(li(p("<a>foo")), li(p("bar<b>"))), p("hi")), doc(p("hi")))
    del("leaves wrapping textblock when deleting all text in it", doc(p("a"), p("<a>b<b>")), doc(p("a"), p()))
    del("expands to cover the whole parent node",
        doc(p("a"), blockquote(blockquote(p("<a>foo")), p("bar<b>")), p("b")),
        doc(p("a"), p("b")))
    del("expands to cover the whole document",
        doc(h1("<a>foo"), p("bar"), blockquote(p("baz<b>"))), doc(p()))
    del("doesn't expand beyond same-depth textblocks",
        doc(h1("<a>foo"), p("bar"), p("baz<b>")), doc(h1()))
    del("deletes the open token when deleting from start to past end of block",
        doc(h1("<a>foo"), p("b<b>ar")), doc(p("ar")))
    del("doesn't delete the open token when the range end is at end of its own block",
        doc(p("one"), h1("<a>two"), blockquote(p("three<b>")), p("four")),
        doc(p("one"), h1(), p("four")))
    del("doesn't break text-joining by inappropriate expansion",
        doc(ol(li(p("<a>One"), ol(li(p("Tw<b>o")))))), doc(ol(li(p("o")))))
    del("will delete entire blocks when deleting from the start of one textblock to another",
        doc(blockquote(ol(li(p("a")), li(p("<a>b")), li(p("c")))), p("x"), p("<b>y")),
        doc(blockquote(ol(li(p("a")))), p("y")))

    // MARK: insert

    func ins(_ name: String, _ d: TaggedNode, _ nodes: [Node], _ e: TaggedNode) {
        test("PM insert: \(name)") {
            let tr = Transform(d.node)
            try tr.insert(tag(d, "a"), Fragment.from(nodes))
            try verify(tr, d, e)
        }
    }
    ins("can insert a break", doc(p("hello<a>there")), [br().node], doc(p("hello", br(), "<a>there")))
    ins("can insert an empty paragraph at the top", doc(p("one"), "<a>", p("two<2>")), [p().node], doc(p("one"), p(), "<a>", p("two<2>")))
    ins("can insert two block nodes", doc(p("one"), "<a>", p("two<2>")), [p("hi").node, hr().node],
        doc(p("one"), p("hi"), hr(), "<a>", p("two<2>")))
    ins("can insert at the end of a blockquote", doc(blockquote(p("he<before>y"), "<a>"), p("after<after>")), [p().node],
        doc(blockquote(p("he<before>y"), p()), p("after<after>")))
    ins("can insert at the start of a blockquote", doc(blockquote("<a>", p("he<1>y")), p("after<2>")), [p().node],
        doc(blockquote(p(), "<a>", p("he<1>y")), p("after<2>")))
    ins("will wrap a node with the suitable parent", doc(p("foo<a>bar")), [basicSchema.nodes["list_item"]!.createAndFill()!],
        doc(p("foo"), ol(li(p())), p("bar")))

    // MARK: addNodeMark / removeNodeMark / setNodeAttribute / setDocAttribute

    func addNM(_ name: String, _ d: TaggedNode, _ mark: Mark, _ e: TaggedNode) {
        test("PM addNodeMark: \(name)") {
            let tr = Transform(d.node)
            try tr.addNodeMark(tag(d, "a"), mark)
            try verify(tr, d, e)
        }
    }
    addNM("adds a mark", doc(p("<a>", img())), basicSchema.mark("em"), doc(p("<a>", em(img()))))
    addNM("doesn't duplicate a mark", doc(p("<a>", em(img()))), basicSchema.mark("em"), doc(p("<a>", em(img()))))
    addNM("replaces a mark", doc(p("<a>", a(img()))), basicSchema.mark("link", ["href": .string("x")]),
          doc(p("<a>", a(img(), href: "x"))))

    func rmNM(_ name: String, _ d: TaggedNode, _ mark: Mark, _ e: TaggedNode) {
        test("PM removeNodeMark: \(name)") {
            let tr = Transform(d.node)
            try tr.removeNodeMark(tag(d, "a"), mark)
            try verify(tr, d, e)
        }
    }
    rmNM("removes a mark", doc(p("<a>", em(img()))), basicSchema.mark("em"), doc(p("<a>", img())))
    rmNM("doesn't do anything when there is no mark", doc(p("<a>", img())), basicSchema.mark("em"), doc(p("<a>", img())))
    rmNM("can remove a mark from multiple marks", doc(p("<a>", em(a(img())))), basicSchema.mark("em"), doc(p("<a>", a(img()))))

    test("PM setNodeAttribute: sets an attribute") {
        let d = doc("<a>", h1("a")), e = doc("<a>", h2("a"))
        let tr = Transform(d.node)
        try tr.setNodeAttribute(tag(d, "a"), "level", .int(2))
        try verify(tr, d, e)
    }
    test("PM setDocAttribute: sets an attribute") {
        let s = try Schema(nodes: [
            ("doc", NodeSpec(content: "text*", attrs: ["meta": AttributeSpec(default: .null)])),
            ("text", NodeSpec()),
        ])
        let d = try s.node("doc")
        let tr = Transform(d)
        try tr.setDocAttribute("meta", .string("hello"))
        try verify(tr, d, try s.node("doc", ["meta": .string("hello")]), s)
    }

    // MARK: The failure paths the ports above don't reach

    test("Transform.wrap: a wrapper that can't hold the next one is rejected") {
        // A list item can't be the content of a paragraph, so wrapping a
        // paragraph in (paragraph, list_item) can't form valid content.
        let d = doc(p("<a>x")).node
        let tr = Transform(d)
        let r = d.resolve(1)
        let range = r.blockRange()!
        try expectThrows {
            try tr.wrap(range, [NodeTypeWithAttrs(basicSchema.nodes["paragraph"]!),
                                NodeTypeWithAttrs(basicSchema.nodes["list_item"]!)])
        }
        try expectEqual(tr.doc, d, "a rejected wrap leaves the document alone")
    }
    test("Transform.setNodeMarkup: a type that can't hold the node's content is rejected") {
        // A code block holds text only, so a paragraph with an image can't
        // become one.
        let d = doc(p("a", img())).node
        let tr = Transform(d)
        try expectThrows { try tr.setNodeMarkup(0, basicSchema.nodes["code_block"]!) }
        try expectEqual(tr.doc, d)
    }
    test("Transform.removeAllMarks: strips every mark in the range") {
        let d = doc(p("<a>", em("one "), strong("two"), "<b>")), e = doc(p("one two"))
        let tr = Transform(d.node)
        try tr.removeAllMarks(tag(d, "a"), tag(d, "b"))
        try verify(tr, d, e)
    }
    test("TransformError: describes what failed") {
        let error = TransformError.failed("no such position")
        try expect("\(error)".contains("no such position"), "got \("\(error)")")
    }
    test("ReplaceAroundStep: a structural gap-replace refuses to overwrite content") {
        // Wrapping p("a") in a blockquote is structural: from..gapFrom and
        // gapTo..to must be empty. Claiming the text inside as part of the
        // replaced structure fails instead of eating it.
        let d = doc(p("ab")).node
        let wrap = Slice(content: Fragment.from(blockquote().node), openStart: 0, openEnd: 0)
        let bad = ReplaceAroundStep(0, 4, 2, 3, wrap, 1, structure: true)
        try expectNotNil(bad.apply(d).failed)
        let good = ReplaceAroundStep(0, 4, 0, 4, wrap, 1, structure: true)
        try expectEqual(good.apply(d).doc, doc(blockquote(p("ab"))).node)
    }
    test("ReplaceAroundStep: a gap that isn't flat fails") {
        // The gap 2..5 starts inside the first paragraph and ends inside the
        // second, so it can't be lifted out as one flat fragment.
        let d = doc(p("ab"), p("cd")).node
        let wrap = Slice(content: Fragment.from(blockquote().node), openStart: 0, openEnd: 0)
        let step = ReplaceAroundStep(0, 8, 2, 6, wrap, 1)
        try expectNotNil(step.apply(d).failed)
    }
    test("ReplaceStep: a structural replace refuses to overwrite content") {
        let d = doc(p("ab"), p("cd")).node
        let step = ReplaceStep(0, 4, .empty, structure: true)
        try expectNotNil(step.apply(d).failed)
        try expectNil(ReplaceStep(0, 4, .empty).apply(d).failed) // the same range is fine as a plain replace
    }
    test("ReplaceStep JSON: malformed input throws rather than guessing") {
        try expectThrows { _ = try decodeStep(basicSchema, ["stepType": .string("replace"), "from": .string("x")]) }
        try expectThrows { _ = try decodeStep(basicSchema, ["stepType": .string("replaceAround"), "from": .int(0)]) }
        // An insert offset outside the slice is rejected at decode time.
        try expectThrows {
            _ = try decodeStep(basicSchema, [
                "stepType": .string("replaceAround"), "from": .int(0), "to": .int(4),
                "gapFrom": .int(0), "gapTo": .int(4), "insert": .int(99),
                "slice": .object(["content": .array([.object(blockquote().node.toJSON())])]),
            ])
        }
    }
    test("StepRegistry.register: a custom step type decodes through the registry") {
        StepRegistry.register("replaceAlias") { schema, json in
            var copy = json
            copy["stepType"] = .string("replace")
            return try decodeStep(schema, copy)
        }
        let step = ReplaceStep(1, 1, Slice(content: Fragment.from(basicSchema.text("x")), openStart: 0, openEnd: 0))
        var json = step.toJSON()
        json["stepType"] = .string("replaceAlias")
        let decoded = try decodeStep(basicSchema, json)
        try expectEqual(decoded.apply(doc(p("ab")).node).doc, doc(p("xab")).node)
    }
    test("Mapping.appendMapping: keeps the appended mapping's mirrors") {
        // A delete mirrored by its inverse maps a position through unchanged
        // only when the mirror survives being appended to another mapping.
        let inner = Mapping()
        inner.appendMap(StepMap([2, 4, 0]))
        inner.appendMap(StepMap([2, 0, 4]), 0)
        let outer = Mapping()
        outer.appendMap(StepMap([0, 0, 1]))
        outer.appendMapping(inner)
        try expectEqual(outer.maps.count, 3)
        try expectEqual(outer.getMirror(2), 1)
        try expectEqual(outer.getMirror(1), 2)
        try expectEqual(outer.map(5), 6)
    }
    test("DocAttrStep: getMap is the empty map") {
        let step = DocAttrStep("meta", .null)
        try expectEqual(step.getMap().map(7), 7)
    }
}

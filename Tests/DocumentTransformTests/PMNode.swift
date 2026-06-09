import Foundation
import DocumentModel
import TestHarness

// Ported from prosemirror-model/test/test-node.ts — cut, nodesBetween,
// textContent, check, Fragment.from, and toJSON round-trips.

func registerPMNodeTests() {
    // MARK: cut
    func cutT(_ name: String, _ d: TaggedNode, _ expect: TaggedNode) {
        test("PM cut: \(name)") { try expectEqual(d.node.cut(d.tags["a"] ?? 0, d.tags["b"]), expect.node) }
    }
    cutT("extracts a full block", doc(p("foo"), "<a>", p("bar"), "<b>", p("baz")), doc(p("bar")))
    cutT("cuts text", doc(p("0"), p("foo<a>bar<b>baz"), p("2")), doc(p("bar")))
    cutT("cuts deeply", doc(blockquote(ul(li(p("a"), p("b<a>c")), li(p("d")), "<b>", li(p("e"))), p("3"))), doc(blockquote(ul(li(p("c")), li(p("d"))))))
    cutT("works from the left", doc(blockquote(p("foo<b>bar"))), doc(blockquote(p("foo"))))
    cutT("works to the right", doc(blockquote(p("foo<a>bar"))), doc(blockquote(p("bar"))))
    cutT("preserves marks", doc(p("foo", em("ba<a>r", img(), strong("baz"), br()), "qu<b>ux", code("xyz"))), doc(p(em("r", img(), strong("baz"), br()), "qu")))

    // MARK: nodesBetween
    func between(_ name: String, _ d: TaggedNode, _ nodes: [String]) {
        test("PM nodesBetween: \(name)") {
            var seq: [String] = []
            d.node.nodesBetween(tag(d, "a"), tag(d, "b"), { node, _, _, _ in
                seq.append(node.isText ? (node.text ?? "") : node.type.name)
                return true
            })
            try expectEqual(seq, nodes)
        }
    }
    between("iterates over text", doc(p("foo<a>bar<b>baz")), ["paragraph", "foobarbaz"])
    between("descends multiple levels", doc(blockquote(ul(li(p("f<a>oo")), p("b"), "<b>"), p("c"))), ["blockquote", "bullet_list", "list_item", "paragraph", "foo", "paragraph", "b"])
    between("iterates over inline nodes", doc(p(em("x"), "f<a>oo", em("bar", img(), strong("baz"), br()), "quux", code("xy<b>z"))), ["paragraph", "foo", "bar", "image", "baz", "hard_break", "quux", "xyz"])

    // MARK: textContent
    test("PM textContent: whole doc") { try expectEqual(doc(p("foo")).node.textContent, "foo") }
    test("PM textContent: text node") { try expectEqual(basicSchema.text("foo").textContent, "foo") }
    test("PM textContent: nested element") { try expectEqual(doc(ul(li(p("hi")), li(p(em("a"), "b")))).node.textContent, "hiab") }

    // MARK: check
    test("PM check: notices invalid content") { try expectThrows({ try doc(li("x")).node.check() }) }
    test("PM check: notices marks in wrong places") {
        let para = try! basicSchema.node("paragraph", [:], content: .empty, marks: [basicSchema.mark("em")])
        let d = try! basicSchema.node("doc", [:], content: Fragment.from([para]))
        try expectThrows({ try d.check() })
    }
    test("PM check: notices incorrect sets of marks") {
        try expectThrows({ try basicSchema.text("a", [basicSchema.mark("em"), basicSchema.mark("em")]).check() })
    }
    // NOTE: PM also has "notices wrong attribute types" (image {src: true}), but that
    // relies on per-attribute `validate` declarations (e.g. validate: "string"), a
    // schema feature ProseKit's AttributeSpec doesn't model — so check() can't catch it.

    // MARK: Fragment.from
    test("PM from: wraps a single node") {
        try expectEqual(doc(p()).node.copy(content: Fragment.from(try! basicSchema.node("paragraph"))), doc(p()).node)
    }
    test("PM from: wraps an array") {
        try expectEqual(p(br(), "foo").node.copy(content: Fragment.from([try! basicSchema.node("hard_break"), basicSchema.text("foo")])), p(br(), "foo").node)
    }
    test("PM from: preserves a fragment") {
        try expectEqual(doc(p("foo")).node.copy(content: doc(p("foo")).node.content), doc(p("foo")).node)
    }
    test("PM from: accepts null") {
        try expectEqual(p().node.copy(content: Fragment.empty), p().node)
    }
    test("PM from: joins adjacent text") {
        try expectEqual(p("ab").node.copy(content: Fragment.from([basicSchema.text("a"), basicSchema.text("b")])), p("ab").node)
    }

    // MARK: toJSON round-trip
    func roundTrip(_ name: String, _ d: TaggedNode) {
        test("PM toJSON: \(name)") { try expectEqual(basicSchema.nodeFromJSON(d.node.toJSON()), d.node) }
    }
    roundTrip("can serialize a simple node", doc(p("foo")))
    roundTrip("can serialize marks", doc(p("foo", em("bar", strong("baz")), " ", a("x"))))
    roundTrip("can serialize inline leaf nodes", doc(p("foo", em(img(), "bar"))))
    roundTrip("can serialize block leaf nodes", doc(p("a"), hr(), p("b"), p()))
    roundTrip("can serialize nested nodes", doc(blockquote(ul(li(p("a"), p("b")), li(p(img()))), p("c")), p("d")))
}

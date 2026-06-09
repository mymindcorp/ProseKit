import Foundation
import DocumentModel
import TestHarness

// Ported from prosemirror-model/test/test-replace.ts — Node.replace with slices
// of varying open depths (the core replace algorithm). Uses the PMBuilder.

func registerPMReplaceTests() {
    func rpl(_ name: String, _ d: TaggedNode, _ insert: TaggedNode?, _ e: TaggedNode) {
        test("PM Node.replace: \(name)") {
            let slice = insert.map { $0.node.slice(tag($0, "a"), tag($0, "b")) } ?? Slice.empty
            try expectEqual(d.node.replace(tag(d, "a"), tag(d, "b"), slice), e.node)
        }
    }
    func bad(_ name: String, _ d: TaggedNode, _ insert: TaggedNode?) {
        test("PM Node.replace rejects: \(name)") {
            let slice = insert.map { $0.node.slice(tag($0, "a"), tag($0, "b")) } ?? Slice.empty
            try expectThrows({ _ = try d.node.replace(tag(d, "a"), tag(d, "b"), slice) })
        }
    }

    rpl("joins on delete", doc(p("on<a>e"), p("t<b>wo")), nil, doc(p("onwo")))
    rpl("merges matching blocks", doc(p("on<a>e"), p("t<b>wo")), doc(p("xx<a>xx"), p("yy<b>yy")), doc(p("onxx"), p("yywo")))
    rpl("merges when adding text", doc(p("on<a>e"), p("t<b>wo")), doc(p("<a>H<b>")), doc(p("onHwo")))
    rpl("can insert text", doc(p("before"), p("on<a><b>e"), p("after")), doc(p("<a>H<b>")), doc(p("before"), p("onHe"), p("after")))
    rpl("doesn't merge non-matching blocks", doc(p("on<a>e"), p("t<b>wo")), doc(h1("<a>H<b>")), doc(p("onHwo")))
    rpl("can merge a nested node", doc(blockquote(blockquote(p("on<a>e"), p("t<b>wo")))), doc(p("<a>H<b>")), doc(blockquote(blockquote(p("onHwo")))))
    rpl("can replace within a block", doc(blockquote(p("a<a>bc<b>d"))), doc(p("x<a>y<b>z")), doc(blockquote(p("ayd"))))
    rpl("can insert a lopsided slice",
        doc(blockquote(blockquote(p("on<a>e"), p("two"), "<b>", p("three")))),
        doc(blockquote(p("aa<a>aa"), p("bb"), p("cc"), "<b>", p("dd"))),
        doc(blockquote(blockquote(p("onaa"), p("bb"), p("cc"), p("three")))))
    rpl("can insert a deep, lopsided slice",
        doc(blockquote(blockquote(p("on<a>e"), p("two"), p("three")), "<b>", p("x"))),
        doc(blockquote(p("aa<a>aa"), p("bb"), p("cc")), "<b>", p("dd")),
        doc(blockquote(blockquote(p("onaa"), p("bb"), p("cc")), p("x"))))
    rpl("can merge multiple levels",
        doc(blockquote(blockquote(p("hell<a>o"))), blockquote(blockquote(p("<b>a")))), nil,
        doc(blockquote(blockquote(p("hella")))))
    rpl("can merge multiple levels while inserting",
        doc(blockquote(blockquote(p("hell<a>o"))), blockquote(blockquote(p("<b>a")))), doc(p("<a>i<b>")),
        doc(blockquote(blockquote(p("hellia")))))
    rpl("can insert a split", doc(p("foo<a><b>bar")), doc(p("<a>x"), p("y<b>")), doc(p("foox"), p("ybar")))
    rpl("can insert a deep split", doc(blockquote(p("foo<a>x<b>bar"))), doc(blockquote(p("<a>x")), blockquote(p("y<b>"))), doc(blockquote(p("foox")), blockquote(p("ybar"))))
    rpl("can add a split one level up", doc(blockquote(p("foo<a>u"), p("v<b>bar"))), doc(blockquote(p("<a>x")), blockquote(p("y<b>"))), doc(blockquote(p("foox")), blockquote(p("ybar"))))
    rpl("keeps the node type of the left node", doc(h1("foo<a>bar"), "<b>"), doc(p("foo<a>baz"), "<b>"), doc(h1("foobaz")))
    rpl("keeps the node type even when empty", doc(h1("<a>bar"), "<b>"), doc(p("foo<a>baz"), "<b>"), doc(h1("baz")))

    bad("doesn't allow the left side to be too deep", doc(p("<a><b>")), doc(blockquote(p("<a>")), "<b>"))
    bad("doesn't allow a depth mismatch", doc(p("<a><b>")), doc("<a>", p("<b>")))
    bad("rejects a bad fit", doc("<a><b>"), doc(p("<a>foo<b>")))
    bad("rejects unjoinable content", doc(ul(li(p("a")), "<a>"), "<b>"), doc(p("foo", "<a>"), "<b>"))
    bad("rejects an unjoinable delete", doc(blockquote(p("a"), "<a>"), ul("<b>", li(p("b")))), nil)
    bad("check content validity", doc(blockquote("<a>", p("hi")), "<b>"), doc(blockquote("hi", "<a>"), "<b>"))
}

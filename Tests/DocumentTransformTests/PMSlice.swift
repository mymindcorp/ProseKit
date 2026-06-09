import Foundation
import DocumentModel
import TestHarness

// Ported from prosemirror-model/test/test-slice.ts — Node.slice and the open
// depths it computes.

func registerPMSliceTests() {
    func t(_ name: String, _ d: TaggedNode, _ expect: TaggedNode, _ openStart: Int, _ openEnd: Int) {
        test("PM slice: \(name)") {
            let slice = d.node.slice(d.tags["a"] ?? 0, d.tags["b"])
            try expectEqual(slice.content, expect.node.content)
            try expectEqual(slice.openStart, openStart)
            try expectEqual(slice.openEnd, openEnd)
        }
    }
    t("can cut half a paragraph", doc(p("hello<b> world")), doc(p("hello")), 0, 1)
    t("can cut to the end of a paragraph", doc(p("hello<b>")), doc(p("hello")), 0, 1)
    t("leaves off extra content", doc(p("hello<b> world"), p("rest")), doc(p("hello")), 0, 1)
    t("preserves styles", doc(p("hello ", em("WOR<b>LD"))), doc(p("hello ", em("WOR"))), 0, 1)
    t("can cut multiple blocks", doc(p("a"), p("b<b>")), doc(p("a"), p("b")), 0, 1)
    t("can cut to a top-level position", doc(p("a"), "<b>", p("b")), doc(p("a")), 0, 0)
    t("can cut to a deep position", doc(blockquote(ul(li(p("a")), li(p("b<b>"))))), doc(blockquote(ul(li(p("a")), li(p("b"))))), 0, 4)
    t("can cut everything after a position", doc(p("hello<a> world")), doc(p(" world")), 1, 0)
    t("can cut from the start of a textblock", doc(p("<a>hello")), doc(p("hello")), 1, 0)
    t("leaves off extra content before", doc(p("foo"), p("bar<a>baz")), doc(p("baz")), 1, 0)
    t("preserves styles after cut", doc(p("a sentence with an ", em("emphasized ", a("li<a>nk")), " in it")), doc(p(em(a("nk")), " in it")), 1, 0)
    t("preserves styles started after cut", doc(p("a ", em("sentence"), " wi<a>th ", em("text"), " in it")), doc(p("th ", em("text"), " in it")), 1, 0)
    t("can cut from a top-level position", doc(p("a"), "<a>", p("b")), doc(p("b")), 0, 0)
    t("can cut from a deep position", doc(blockquote(ul(li(p("a")), li(p("<a>b"))))), doc(blockquote(ul(li(p("b"))))), 4, 0)
    t("can cut part of a text node", doc(p("hell<a>o wo<b>rld")), p("o wo"), 0, 0)
    t("can cut across paragraphs", doc(p("on<a>e"), p("t<b>wo")), doc(p("e"), p("t")), 1, 1)
    t("can cut part of marked text", doc(p("here's noth<a>ing and ", em("here's e<b>m"))), p("ing and ", em("here's e")), 0, 0)
    t("can cut across different depths", doc(ul(li(p("hello")), li(p("wo<a>rld")), li(p("x"))), p(em("bo<b>o"))), doc(ul(li(p("rld")), li(p("x"))), p(em("bo"))), 3, 1)
    t("can cut between deeply nested nodes", doc(blockquote(p("foo<a>bar"), ul(li(p("a")), li(p("b"), "<b>", p("c"))), p("d"))), blockquote(p("bar"), ul(li(p("a")), li(p("b")))), 1, 2)

    test("PM slice: can include parents") {
        let d = doc(blockquote(p("fo<a>o"), p("bar<b>")))
        let slice = d.node.slice(tag(d, "a"), tag(d, "b"), includeParents: true)
        try expectEqual(slice.content, Fragment.from([blockquote(p("o"), p("bar")).node]))
        try expectEqual(slice.openStart, 2)
        try expectEqual(slice.openEnd, 2)
    }
}

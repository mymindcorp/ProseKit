import Foundation
import DocumentModel
import TestHarness

// Ported from prosemirror-model/test/test-diff.ts — Fragment.findDiffStart /
// findDiffEnd, the primitives behind minimal replace-step generation.

func registerPMDiffTests() {
    func start(_ name: String, _ a: TaggedNode, _ b: TaggedNode) {
        test("PM findDiffStart: \(name)") { try expectEqual(a.node.content.findDiffStart(b.node.content), a.tags["a"]) }
    }
    func end(_ name: String, _ a: TaggedNode, _ b: TaggedNode) {
        test("PM findDiffEnd: \(name)") { try expectEqual(a.node.content.findDiffEnd(b.node.content)?.a, a.tags["a"]) }
    }

    // findDiffStart
    start("returns null for identical nodes",
          doc(p("a", em("b")), p("hello"), blockquote(h1("bye"))),
          doc(p("a", em("b")), p("hello"), blockquote(h1("bye"))))
    start("notices when one node is longer",
          doc(p("a", em("b")), p("hello"), blockquote(h1("bye")), "<a>"),
          doc(p("a", em("b")), p("hello"), blockquote(h1("bye")), p("oops")))
    start("notices when one node is shorter",
          doc(p("a", em("b")), p("hello"), blockquote(h1("bye")), "<a>", p("oops")),
          doc(p("a", em("b")), p("hello"), blockquote(h1("bye"))))
    start("notices differing marks", doc(p("a<a>", em("b"))), doc(p("a", strong("b"))))
    start("stops at longer text", doc(p("foo<a>bar", em("b"))), doc(p("foo", em("b"))))
    start("stops at a different character", doc(p("foo<a>bar")), doc(p("foocar")))
    start("stops at a different node type", doc(p("a"), "<a>", p("b")), doc(p("a"), h1("b")))
    start("works when the difference is at the start", doc("<a>", p("b")), doc(h1("b")))
    start("notices a different attribute", doc(p("a"), "<a>", h1("foo")), doc(p("a"), h2("foo")))

    // findDiffEnd
    end("returns null when there is no difference",
        doc(p("a", em("b")), p("hello"), blockquote(h1("bye"))),
        doc(p("a", em("b")), p("hello"), blockquote(h1("bye"))))
    end("notices when the second doc is longer",
        doc("<a>", p("a", em("b")), p("hello"), blockquote(h1("bye"))),
        doc(p("oops"), p("a", em("b")), p("hello"), blockquote(h1("bye"))))
    end("notices when the second doc is shorter",
        doc(p("oops"), "<a>", p("a", em("b")), p("hello"), blockquote(h1("bye"))),
        doc(p("a", em("b")), p("hello"), blockquote(h1("bye"))))
    end("notices different styles", doc(p("a", em("b"), "<a>c")), doc(p("a", strong("b"), "c")))
    end("spots longer text", doc(p("bar<a>foo", em("b"))), doc(p("foo", em("b"))))
    end("spots different text", doc(p("foob<a>ar")), doc(p("foocar")))
    end("notices different nodes", doc(p("a"), "<a>", p("b")), doc(h1("a"), p("b")))
    end("notices a difference at the end", doc(p("b"), "<a>"), doc(h1("b")))
    end("handles a similar start", doc("<a>", p("hello")), doc(p("hey"), p("hello")))
}

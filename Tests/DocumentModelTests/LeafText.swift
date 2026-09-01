import Foundation
import DocumentModel
import TestHarness

// Ported from the `textBetween` and `leafText` cases in prosemirror-model's
// test-node.ts. `leafText` is what a mention, a footnote reference or a math
// node reads as when the document is flattened to text — for search, for the
// clipboard, and for input rules looking at what sits before the cursor.

private let contactSchema: Schema = {
    try! Schema(nodes: [
        ("doc", NodeSpec(content: "paragraph+")),
        ("paragraph", NodeSpec(content: "(text | contact)*")),
        ("text", NodeSpec()),
        ("contact", NodeSpec(
            inline: true,
            attrs: ["name": AttributeSpec(), "email": AttributeSpec()],
            leafText: { node in
                "\(node.attrs["name"]?.stringValue ?? "") <\(node.attrs["email"]?.stringValue ?? "")>"
            })),
    ], marks: [], topNode: "doc")
}()

private func contact(_ name: String, _ email: String) throws -> Node {
    try contactSchema.nodes["contact"]!.createChecked(["name": .string(name), "email": .string(email)])
}

private func helloDoc(_ contact: Node) throws -> Node {
    try contactSchema.nodes["doc"]!.createChecked([:], content: Fragment.from([
        try contactSchema.nodes["paragraph"]!.createChecked([:], content: Fragment.from([
            contactSchema.text("Hello "), contact,
        ])),
    ]))
}

func registerLeafTextTests() {
    test("textBetween: the leafText argument stands in for every leaf") {
        let d = B.doc(B.p(B.t("foo"), B.img("x"), B.br()))
        try expectEqual(d.textBetween(0, d.content.size, blockSeparator: "", leafText: "<leaf>"), "foo<leaf><leaf>")
        // Without it, a leaf with nothing to say contributes nothing.
        try expectEqual(d.textBetween(0, d.content.size, blockSeparator: ""), "foo")
    }

    test("textBetween: a leaf's spec leafText is its text") {
        let d = try helloDoc(try contact("Alice", "alice@example.com"))
        try expectEqual(d.textBetween(0, d.content.size), "Hello Alice <alice@example.com>")
    }

    test("textBetween: the leafText argument overrides a leaf's own") {
        let d = try helloDoc(try contact("Alice", "alice@example.com"))
        try expectEqual(d.textBetween(0, d.content.size, blockSeparator: "", leafText: "<anonymous>"), "Hello <anonymous>")
    }

    test("textContent: a leaf with leafText reads as it, alone and in its parent") {
        let bob = try contact("Bob", "bob@example.com")
        try expectEqual(bob.textContent, "Bob <bob@example.com>")
        let d = try helloDoc(bob)
        try expectEqual(d.child(0).textContent, "Hello Bob <bob@example.com>")
        try expectEqual(d.textContent, "Hello Bob <bob@example.com>")
    }

    test("textBetween: an empty paragraph still opens a line") {
        let d = B.doc(B.p("one"), B.p(), B.p("two"))
        try expectEqual(d.textBetween(0, 12, blockSeparator: "\n"), "one\n\ntwo")
    }

    test("textBetween: a block leaf opens a line only when it has text") {
        let d = B.doc(B.p("one"), B.hr(), B.hr(), B.p("two"))
        try expectEqual(d.textBetween(0, 12, blockSeparator: "\n", leafText: "---"), "one\n---\n---\ntwo")
        try expectEqual(d.textBetween(0, 12, blockSeparator: "\n"), "one\ntwo")
    }
}

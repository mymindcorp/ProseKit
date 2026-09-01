import Foundation
import DocumentModel
import TestHarness

// The model's job is as much to refuse an invalid document as to build a valid
// one. These pin the doors it used to leave open: a mark missing a required
// attribute, a text node with no text, "checked" content nobody checked the
// marks of, and schemas upstream would refuse to compile.

private func build(_ nodes: [(String, NodeSpec)], marks: [(String, MarkSpec)] = []) throws(ModelError) -> Schema {
    try Schema(nodes: nodes, marks: marks, topNode: "doc")
}

func registerValidationTests() {
    // MARK: Marks with required attributes

    test("Mark.fromJSON: a required attribute that is missing is an error") {
        // `link` requires `href`. Falling back to the defaults here built a
        // link with no href that only `check()` would ever notice.
        try expectThrows { _ = try Mark.fromJSON(B.schema, ["type": "link"]) }
        try expectThrows { _ = try Mark.fromJSON(B.schema, ["type": "link", "attrs": ["title": "t"]]) }
        // Given, it loads, and the optional attribute takes its default.
        let mark = try Mark.fromJSON(B.schema, ["type": "link", "attrs": ["href": "https://x"]])
        try expectEqual(mark.attrs, ["href": "https://x", "title": .null])
    }

    test("Node.fromJSON: a mark missing a required attribute fails the whole load") {
        let json: [String: AttributeValue] = ["type": "doc", "content": [
            ["type": "paragraph", "content": [["type": "text", "text": "x", "marks": [["type": "link"]]]]],
        ]]
        try expectThrows { _ = try Node.fromJSON(B.schema, json) }
    }

    test("check: a mark missing a required attribute is invalid") {
        // `Mark.init` is the one door left open, for code that builds marks by
        // hand; `check()` is what catches what comes through it.
        let bare = Mark(type: B.schema.marks["link"]!, attrs: [:])
        try expectThrows { try B.doc(B.p(B.schema.text("x", [bare]))).check() }
    }

    test("MarkType.create: an optional attribute not given takes its default") {
        let link = B.schema.mark("link", ["href": "https://x"])
        try expectEqual(link.attrs["href"], "https://x")
        try expectEqual(link.attrs["title"], .null)
        // Attributes the type does not declare are dropped, as they are for nodes.
        try expectNil(B.schema.mark("link", ["href": "https://x", "bogus": 1]).attrs["bogus"])
    }

    // MARK: Empty text

    test("Node.fromJSON: an empty text node is rejected") {
        // A node of size zero sits between two positions without occupying
        // one. This used to load, pass `check()`, and compare unequal to the
        // same document rebuilt.
        let json: [String: AttributeValue] = ["type": "doc", "content": [
            ["type": "paragraph", "content": [
                ["type": "text", "text": "ab"],
                ["type": "text", "text": "", "marks": [["type": "bold"]]],
                ["type": "text", "text": "cd"],
            ]],
        ]]
        try expectThrows { _ = try Node.fromJSON(B.schema, json) }
        // An empty paragraph is spelled with no content, and still loads.
        let empty = try Node.fromJSON(B.schema, ["type": "doc", "content": [["type": "paragraph"]]])
        try expectEqual(empty, B.doc(B.p()))
    }

    // MARK: createChecked

    test("createChecked: content the node's mark set forbids is rejected") {
        let codeBlock = B.schema.nodes["codeBlock"]!   // marks: ""
        try expectThrows { _ = try codeBlock.createChecked([:], content: Fragment.from(B.strong("x"))) }
        let plain = try codeBlock.createChecked([:], content: Fragment.from(B.t("x")))
        try plain.check()
        // The content expression is still checked too.
        try expectThrows { _ = try codeBlock.createChecked([:], content: Fragment.from(B.p("x"))) }
    }

    // MARK: Schema compilation

    // A block leaf that cannot be generated: filling content never makes one
    // up, because it has no way to choose a `src`.
    let image = ("image", NodeSpec(attrs: ["src": AttributeSpec()]))
    let paragraph = ("paragraph", NodeSpec(content: "text*"))
    let text = ("text", NodeSpec())

    test("schema: a required position only a non-generatable node can fill is rejected") {
        // `createAndFill` would come back nil at runtime for either of these.
        try expectThrows { _ = try build([("doc", NodeSpec(content: "image+")), image, text]) }
        try expectThrows { _ = try build([("doc", NodeSpec(content: "paragraph image")), paragraph, image, text]) }
        try expectThrows { _ = try build([("doc", NodeSpec(content: "text+")), text]) }
        // Optional, the position can be left empty, and that is fine.
        _ = try build([("doc", NodeSpec(content: "image*")), image, text])
        _ = try build([("doc", NodeSpec(content: "paragraph image?")), paragraph, image, text])
        _ = try build([("doc", NodeSpec(content: "(paragraph | image)+")), paragraph, image, text])
    }

    test("schema: mixing inline and block content in one expression is rejected") {
        // Whether a node holds inline content is read off the first edge of
        // its match, so a mixed expression would answer by accident of order.
        try expectThrows { _ = try build([("doc", NodeSpec(content: "paragraph text*")), paragraph, text]) }
        try expectThrows { _ = try build([("doc", NodeSpec(content: "(paragraph | text)*")), paragraph, text]) }
    }

    test("schema: a name cannot be both a node and a mark") {
        try expectThrows {
            _ = try build([("doc", NodeSpec(content: "paragraph+")), paragraph, text], marks: [("paragraph", MarkSpec())])
        }
    }

    test("schema: a text type is required, and takes no attributes") {
        try expectThrows { _ = try build([("doc", NodeSpec(content: "paragraph+")), ("paragraph", NodeSpec())]) }
        try expectThrows {
            _ = try build([("doc", NodeSpec(content: "paragraph+")), paragraph,
                           ("text", NodeSpec(attrs: ["x": AttributeSpec(default: 1)]))])
        }
    }

    test("schema: a range whose upper bound is below its lower is rejected") {
        try expectThrows { _ = try build([("doc", NodeSpec(content: "paragraph{2,1}")), paragraph, text]) }
        _ = try build([("doc", NodeSpec(content: "paragraph{1,2}")), paragraph, text])
        _ = try build([("doc", NodeSpec(content: "paragraph{2}")), paragraph, text])
    }
}

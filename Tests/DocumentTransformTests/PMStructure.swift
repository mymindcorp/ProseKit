import Foundation
import DocumentModel
import DocumentTransform
import TestHarness

// Ported from prosemirror-transform/test/test-structure.ts — canSplit,
// liftTarget, findWrapping, and the Fitter-driven `replace` cases, on
// ProseMirror's rich "sections/figures/quotes" schema.

private let pmSchema: Schema = {
    let nodes: [(String, NodeSpec)] = [
        ("doc", NodeSpec(content: "head? block* sect* closing?")),
        ("para", NodeSpec(content: "text*", group: "block")),
        ("head", NodeSpec(content: "text*", marks: "")),
        ("figure", NodeSpec(content: "caption figureimage", group: "block")),
        ("quote", NodeSpec(content: "block+", group: "block")),
        ("figureimage", NodeSpec()),
        ("caption", NodeSpec(content: "text*", marks: "")),
        ("sect", NodeSpec(content: "head block* sect*")),
        ("closing", NodeSpec(content: "text*")),
        ("text", NodeSpec(group: "inline")),
        ("fixed", NodeSpec(content: "head para closing", group: "block")),
    ]
    return try! Schema(nodes: nodes, marks: [("em", MarkSpec())], topNode: "doc")
}()

private func pn(_ name: String, _ content: Node...) -> Node {
    try! pmSchema.node(name, [:], content: Fragment.from(content))
}
private func pt(_ s: String) -> Node { pmSchema.text(s) }

// Positions are from prosemirror-transform's own annotations of this doc.
private let pmDoc = pn("doc",                                  // 0
    pn("head", pt("Head")),                                   // 6
    pn("para", pt("Intro")),                                  // 13
    pn("sect",                                                // 14
        pn("head", pt("Section head")),                       // 28
        pn("sect",                                            // 29
            pn("head", pt("Subsection head")),               // 46
            pn("para", pt("Subtext")),                       // 55
            pn("figure",                                     // 56
                pn("caption", pt("Figure caption")),         // 72
                pn("figureimage")),                          // 74
            pn("quote", pn("para", pt("!"))))),              // 81
    pn("sect",                                                // 82
        pn("head", pt("S2")),                                // 86
        pn("para", pt("Yes"))),                              // 92
    pn("closing", pt("fin")))                                 // 97

private func pmRange(_ pos: Int, _ end: Int? = nil) -> NodeRange? {
    pmDoc.resolve(pos).blockRange(end.map { pmDoc.resolve($0) })
}

private func types(_ after: String?) -> [NodeTypeWithAttrs?]? {
    after.map { [NodeTypeWithAttrs(pmSchema.nodes[$0]!)] }
}

func registerPMStructureTests() {
    // MARK: canSplit
    func splitYes(_ name: String, _ pos: Int, _ depth: Int = 1, _ after: String? = nil) {
        test("PM canSplit: \(name)") { try expect(canSplit(pmDoc, pos, depth, types(after))) }
    }
    func splitNo(_ name: String, _ pos: Int, _ depth: Int = 1, _ after: String? = nil) {
        test("PM canSplit: \(name)") { try expect(!canSplit(pmDoc, pos, depth, types(after))) }
    }
    splitNo("can't at start", 0)
    splitNo("can't in head", 3)
    splitYes("can by making head a para", 3, 1, "para")
    splitNo("can't on top level", 6)
    splitYes("can in regular para", 8)
    splitNo("can't at start of section", 14)
    splitNo("can't in section head", 17)
    splitYes("can if also splitting the section", 17, 2)
    splitYes("can if making the remaining head a para", 18, 1, "para")
    splitNo("can't after the section head", 46)
    splitYes("can in the first section para", 48)
    splitNo("can't in the figure caption", 60)
    splitNo("can't if it also splits the figure", 62, 2)
    splitNo("can't after the figure caption", 72)
    splitYes("can in the first para in a quote", 76)
    splitYes("can if it also splits the quote", 77, 2)
    splitNo("can't at the end of the document", 97)

    test("PM canSplit: split-off content must fit the given node type") {
        let s = try! Schema(nodes: [
            ("doc", NodeSpec(content: "chapter+")),
            ("title", NodeSpec(content: "text*")),
            ("chapter", NodeSpec(content: "title scene+")),
            ("scene", NodeSpec(content: "para+")),
            ("para", NodeSpec(content: "text*")),
            ("text", NodeSpec(group: "inline")),
        ], marks: [], topNode: "doc")
        let doc = try! s.node("doc", [:], content: Fragment.from([
            try! s.node("chapter", [:], content: Fragment.from([
                try! s.node("title", [:], content: Fragment.from([s.text("title")])),
                try! s.node("scene", [:], content: Fragment.from([
                    try! s.node("para", [:], content: Fragment.from([s.text("scene")])),
                ])),
            ])),
        ]))
        try expect(!canSplit(doc, 4, 1, [NodeTypeWithAttrs(s.nodes["scene"]!)]))
    }

    // MARK: liftTarget
    func liftYes(_ name: String, _ pos: Int) {
        test("PM liftTarget: \(name)") { try expect(pmRange(pos).flatMap { liftTarget($0) } != nil) }
    }
    func liftNo(_ name: String, _ pos: Int) {
        test("PM liftTarget: \(name)") { try expect(pmRange(pos).flatMap { liftTarget($0) } == nil) }
    }
    liftNo("can't at the start of the doc", 0)
    liftNo("can't in the heading", 3)
    liftNo("can't in a subsection para", 52)
    liftNo("can't in a figure caption", 70)
    liftYes("can from a quote", 76)
    liftNo("can't in a section head", 86)

    test("PM liftTarget: notices unliftable content around it") {
        let s = try! Schema(nodes: [
            ("doc", NodeSpec(content: "section+")),
            ("section", NodeSpec(content: "heading? p+")),
            ("heading", NodeSpec(content: "p+")),
            ("p", NodeSpec(content: "text*")),
            ("text", NodeSpec(group: "inline")),
        ], marks: [], topNode: "doc")
        let p = try! s.node("p", [:], content: Fragment.from([s.text("A")]))
        let d = try! s.node("doc", [:], content: Fragment.from([
            try! s.node("section", [:], content: Fragment.from([
                try! s.node("heading", [:], content: Fragment.from([p, p, p])), p,
            ])),
        ]))
        try expect(liftTarget(d.resolve(3).blockRange()!) == nil) // p before the required heading
        try expect(liftTarget(d.resolve(6).blockRange()!) == nil)
        try expect(liftTarget(d.resolve(3).blockRange(d.resolve(6))!) == nil)
        try expectEqual(liftTarget(d.resolve(9).blockRange()!), 1) // last para can lift after the heading
    }

    // MARK: findWrapping
    func wrapYes(_ name: String, _ pos: Int, _ end: Int, _ type: String) {
        test("PM findWrapping: \(name)") {
            try expect(pmRange(pos, end).flatMap { findWrappingForRange($0, pmSchema.nodes[type]!) } != nil)
        }
    }
    func wrapNo(_ name: String, _ pos: Int, _ end: Int, _ type: String) {
        test("PM findWrapping: \(name)") {
            let wrapping = pmRange(pos, end).flatMap { findWrappingForRange($0, pmSchema.nodes[type]!) }
            try expect(wrapping == nil)
        }
    }
    wrapYes("can wrap the whole doc in a section", 0, 92, "sect")
    wrapNo("can't wrap a head before a para in a section", 4, 4, "sect")
    wrapYes("can wrap a top paragraph in a quote", 8, 8, "quote")
    wrapNo("can't wrap a section head in a quote", 18, 18, "quote")
    wrapYes("can wrap a figure in a quote", 55, 74, "quote")
    wrapNo("can't wrap a head in a figure", 90, 90, "figure")

    // MARK: Transform.replace (the structure-fitting Fitter)
    func repl(_ name: String, _ doc: Node, _ from: Int, _ to: Int, _ content: Node?, _ openStart: Int, _ openEnd: Int, _ result: Node) {
        test("PM replace: \(name)") {
            let slice = content.map { Slice(content: $0.content, openStart: openStart, openEnd: openEnd) } ?? Slice.empty
            let tr = Transform(doc)
            try tr.replace(from, to, slice)
            try expectEqual(tr.doc, result)
        }
    }
    repl("automatically adds a heading to a section",
         pn("doc", pn("sect", pn("head", pt("foo")), pn("para", pt("bar")))),
         6, 6, pn("doc", pn("sect"), pn("sect")), 1, 1,
         pn("doc", pn("sect", pn("head", pt("foo"))), pn("sect", pn("head"), pn("para", pt("bar")))))
    repl("suppresses impossible inputs",
         pn("doc", pn("para", pt("a")), pn("para", pt("b"))),
         3, 3, pn("doc", pn("closing", pt("."))), 0, 0,
         pn("doc", pn("para", pt("a")), pn("para", pt("b"))))
    repl("adds necessary nodes to the left",
         pn("doc", pn("sect", pn("head", pt("foo")), pn("para", pt("bar")))),
         1, 3, pn("doc", pn("sect"), pn("sect", pn("head", pt("hi")))), 1, 2,
         pn("doc", pn("sect", pn("head")), pn("sect", pn("head", pt("hioo")), pn("para", pt("bar")))))
    repl("adds a caption to a figure",
         pn("doc"), 0, 0, pn("doc", pn("figure", pn("figureimage"))), 1, 0,
         pn("doc", pn("figure", pn("caption"), pn("figureimage"))))
    repl("adds an image to a figure",
         pn("doc"), 0, 0, pn("doc", pn("figure", pn("caption"))), 0, 1,
         pn("doc", pn("figure", pn("caption"), pn("figureimage"))))
    repl("can join figures",
         pn("doc", pn("figure", pn("caption"), pn("figureimage")), pn("figure", pn("caption"), pn("figureimage"))),
         3, 8, nil, 0, 0,
         pn("doc", pn("figure", pn("caption"), pn("figureimage"))))
    repl("adds necessary nodes to a parent node",
         pn("doc", pn("sect", pn("head"), pn("figure", pn("caption"), pn("figureimage")))),
         7, 9, pn("doc", pn("para", pt("hi"))), 0, 0,
         pn("doc", pn("sect", pn("head"), pn("figure", pn("caption"), pn("figureimage")), pn("para", pt("hi")))))
}


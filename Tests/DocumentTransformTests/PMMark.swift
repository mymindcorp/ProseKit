import Foundation
import DocumentModel
import TestHarness

// Ported from prosemirror-model/test/test-mark.ts — Mark.sameSet/eq/addToSet/
// removeFromSet (rank ordering + excludes) and ResolvedPos.marks().

private let em_ = basicSchema.mark("em")
private let strongMark = basicSchema.mark("strong")
private let codeMark = basicSchema.mark("code")
private func linkMark(_ href: String, _ title: String? = nil) -> Mark {
    basicSchema.mark("link", title == nil ? ["href": .string(href)] : ["href": .string(href), "title": .string(title!)])
}

// A schema exercising mark groups and the `excludes` rules.
private let customSchema: Schema = {
    try! Schema(nodes: [
        ("doc", NodeSpec(content: "paragraph+")),
        ("paragraph", NodeSpec(content: "text*")),
        ("text", NodeSpec(group: "inline")),
    ], marks: [
        ("remark", MarkSpec(attrs: ["id": AttributeSpec()], inclusive: false, excludes: "")),
        ("user", MarkSpec(attrs: ["id": AttributeSpec()], excludes: "_")),
        ("strong", MarkSpec(excludes: "em-group")),
        ("em", MarkSpec(group: "em-group")),
    ], topNode: "doc")
}()
private let remark1 = customSchema.mark("remark", ["id": .int(1)])
private let remark2 = customSchema.mark("remark", ["id": .int(2)])
private let user1 = customSchema.mark("user", ["id": .int(1)])
private let user2 = customSchema.mark("user", ["id": .int(2)])
private let customEm = customSchema.mark("em")
private let customStrong = customSchema.mark("strong")

func registerPMMarkTests() {
    func same(_ name: String, _ a: [Mark], _ b: [Mark]) { test("PM Mark.sameSet: \(name)") { try expect(Mark.sameSet(a, b)) } }
    func notSame(_ name: String, _ a: [Mark], _ b: [Mark]) { test("PM Mark.sameSet: \(name)") { try expect(!Mark.sameSet(a, b)) } }

    // sameSet
    same("two empty sets", [], [])
    same("simple identical sets", [em_, strongMark], [em_, strongMark])
    notSame("different sets", [em_, strongMark], [em_, codeMark])
    notSame("set size differs", [em_, strongMark], [em_, strongMark, codeMark])
    same("identical links in set", [linkMark("http://foo"), codeMark], [linkMark("http://foo"), codeMark])
    notSame("different links in set", [linkMark("http://foo"), codeMark], [linkMark("http://bar"), codeMark])

    // eq
    test("PM Mark.eq: identical links are the same") { try expect(linkMark("http://foo").eq(linkMark("http://foo"))) }
    test("PM Mark.eq: different links differ") { try expect(!linkMark("http://foo").eq(linkMark("http://bar"))) }
    test("PM Mark.eq: links with different titles differ") { try expect(!linkMark("http://foo", "A").eq(linkMark("http://foo", "B"))) }

    // addToSet
    func add(_ name: String, _ result: [Mark], _ expected: [Mark]) { test("PM addToSet: \(name)") { try expect(Mark.sameSet(result, expected)) } }
    add("can add to the empty set", em_.addToSet([]), [em_])
    add("is a no-op when the added thing is in set", em_.addToSet([em_]), [em_])
    add("adds marks with lower rank before others", em_.addToSet([strongMark]), [em_, strongMark])
    add("adds marks with higher rank after others", strongMark.addToSet([em_]), [em_, strongMark])
    add("replaces different marks with new attributes", linkMark("http://bar").addToSet([linkMark("http://foo"), em_]), [linkMark("http://bar"), em_])
    add("does nothing when adding an existing link", linkMark("http://foo").addToSet([em_, linkMark("http://foo")]), [em_, linkMark("http://foo")])
    add("puts code marks at the end", codeMark.addToSet([em_, strongMark, linkMark("http://foo")]), [em_, strongMark, linkMark("http://foo"), codeMark])
    add("puts marks with middle rank in the middle", strongMark.addToSet([em_, codeMark]), [em_, strongMark, codeMark])
    add("allows nonexclusive instances of marks with the same type", remark2.addToSet([remark1]), [remark1, remark2])
    add("doesn't duplicate identical instances of nonexclusive marks", remark1.addToSet([remark1]), [remark1])
    add("clears all others when adding a globally-excluding mark", user1.addToSet([remark1, customEm]), [user1])
    add("does not allow adding another mark to a globally-excluding mark", customEm.addToSet([user1]), [user1])
    add("does overwrite a globally-excluding mark when adding another instance", user2.addToSet([user1]), [user2])
    add("doesn't add anything when another mark excludes the added mark", customEm.addToSet([remark1, customStrong]), [remark1, customStrong])
    add("remove excluded marks when adding a mark", customStrong.addToSet([remark1, customEm]), [remark1, customStrong])

    // removeFromSet
    func rem(_ name: String, _ result: [Mark], _ expected: [Mark]) { test("PM removeFromSet: \(name)") { try expect(Mark.sameSet(result, expected)) } }
    rem("is a no-op for the empty set", em_.removeFromSet([]), [])
    rem("can remove the last mark from a set", em_.removeFromSet([em_]), [])
    rem("is a no-op when the mark isn't in the set", strongMark.removeFromSet([em_]), [em_])
    rem("can remove a mark with attributes", linkMark("http://foo").removeFromSet([linkMark("http://foo")]), [])
    rem("doesn't remove a mark when its attrs differ", linkMark("http://foo", "title").removeFromSet([linkMark("http://foo")]), [linkMark("http://foo")])

    // ResolvedPos.marks()
    func isAt(_ name: String, _ d: TaggedNode, _ mark: Mark, _ result: Bool) {
        test("PM ResolvedPos.marks: \(name)") { try expect(mark.isInSet(d.node.resolve(tag(d, "a")).marks()) == result) }
    }
    isAt("recognizes a mark exists inside marked text", doc(p(em("fo<a>o"))), em_, true)
    isAt("recognizes a mark doesn't exist in non-marked text", doc(p(em("fo<a>o"))), strongMark, false)
    isAt("considers a mark active after the mark", doc(p(em("hi"), "<a> there")), em_, true)
    isAt("considers a mark inactive before the mark", doc(p("one <a>", em("two"))), em_, false)
    isAt("considers a mark active at the start of the textblock", doc(p(em("<a>one"))), em_, true)
    isAt("notices that attributes differ", doc(p(a("li<a>nk"))), linkMark("http://baz"), false)

    // non-inclusive marks on a manually-built custom document
    let customDoc = try! customSchema.node("doc", [:], content: Fragment.from([
        try! customSchema.node("paragraph", [:], content: Fragment.from([
            customSchema.text("one", [remark1, customStrong]), customSchema.text("two"),
        ])),
        try! customSchema.node("paragraph", [:], content: Fragment.from([
            customSchema.text("one"), customSchema.text("two", [remark1]), customSchema.text("three", [remark1]),
        ])),
        try! customSchema.node("paragraph", [:], content: Fragment.from([
            customSchema.text("one", [remark2]), customSchema.text("two", [remark1]),
        ])),
    ]))
    func customMarks(_ name: String, _ pos: Int, _ expected: [Mark]) {
        test("PM ResolvedPos.marks: \(name)") { try expect(Mark.sameSet(customDoc.resolve(pos).marks(), expected)) }
    }
    customMarks("omits non-inclusive marks at end of mark", 4, [customStrong])
    customMarks("includes non-inclusive marks inside a text node", 3, [remark1, customStrong])
    customMarks("omits non-inclusive marks at the end of a line", 20, [])
    customMarks("includes non-inclusive marks between two marked nodes", 15, [remark1])
    customMarks("excludes non-inclusive marks at a point where mark attrs change", 25, [])
}

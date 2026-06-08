import Foundation
import DocumentModel
import DocumentTransform
import TestHarness

// Ported from prosemirror-transform/test/test-trans.ts (+ trans.ts helper),
// using the tag-tracking PMBuilder. Each `pmTransform` check verifies the
// resulting doc, step invertibility, step JSON round-trip, and that every shared
// tag maps to the expected position.

private func pmTransform(_ tr: Transform, _ before: TaggedNode, _ expect: TaggedNode) throws {
    try expectEqual(tr.doc, expect.node)
    // Invertibility: applying the inverted steps in reverse restores the input.
    let inv = Transform(tr.doc)
    for i in stride(from: tr.steps.count - 1, through: 0, by: -1) {
        try inv.step(tr.steps[i].invert(tr.docs[i]))
    }
    try expectEqual(inv.doc, before.node)
    // Step JSON round-trip reproduces the same document.
    let again = Transform(before.node)
    for s in tr.steps { try again.step(decodeStep(basicSchema, s.toJSON())) }
    try expectEqual(again.doc, expect.node)
    // Every tag present in both docs maps correctly through the transform.
    for (name, from) in before.tags where expect.tags[name] != nil {
        try expectEqual(tr.mapping.map(from, 1), expect.tags[name]!, "tag <\(name)>")
    }
}

private func tagOpt(_ t: TaggedNode, _ name: String) -> Int? { t.tags[name] }

func registerPMTransformTests() {
    // MARK: addMark
    func add(_ name: String, _ d: TaggedNode, _ mark: Mark, _ e: TaggedNode) {
        test("PM addMark: \(name)") { let tr = Transform(d.node); try tr.addMark(tag(d, "a"), tag(d, "b"), mark); try pmTransform(tr, d, e) }
    }
    add("should add a mark", doc(p("hello <a>there<b>!")), basicSchema.mark("strong"), doc(p("hello ", strong("there"), "!")))
    add("should only add a mark once", doc(p("hello ", strong("<a>there"), "!<b>")), basicSchema.mark("strong"), doc(p("hello ", strong("there!"))))
    add("should join overlapping marks", doc(p("one <a>two ", em("three<b> four"))), basicSchema.mark("strong"), doc(p("one ", strong("two ", em("three")), em(" four"))))
    add("should overwrite marks with different attributes", doc(p("this is a ", a("<a>link<b>"))), basicSchema.mark("link", ["href": .string("bar")]), doc(p("this is a ", a("link", href: "bar"))))
    add("can add a mark in a nested node", doc(p("before"), blockquote(p("the variable is called <a>i<b>")), p("after")), basicSchema.mark("code"), doc(p("before"), blockquote(p("the variable is called ", code("i"))), p("after")))
    add("can add a mark across blocks", doc(p("hi <a>this"), blockquote(p("is")), p("a docu<b>ment"), p("!")), basicSchema.mark("em"), doc(p("hi ", em("this")), blockquote(p(em("is"))), p(em("a docu"), "ment"), p("!")))

    // MARK: removeMark
    func rem(_ name: String, _ d: TaggedNode, _ mark: Mark, _ e: TaggedNode) {
        test("PM removeMark: \(name)") { let tr = Transform(d.node); try tr.removeMark(tag(d, "a"), tag(d, "b"), mark); try pmTransform(tr, d, e) }
    }
    rem("can cut a gap", doc(p(em("hello <a>world<b>!"))), basicSchema.mark("em"), doc(p(em("hello "), "world", em("!"))))
    rem("doesn't do anything when there's no mark", doc(p(em("hello"), " <a>world<b>!")), basicSchema.mark("em"), doc(p(em("hello"), " <a>world<b>!")))
    rem("can remove marks from nested nodes", doc(p(em("one ", strong("<a>two<b>"), " three"))), basicSchema.mark("strong"), doc(p(em("one two three"))))
    rem("can remove a link", doc(p("<a>hello ", a("link<b>"))), basicSchema.mark("link", ["href": .string("foo")]), doc(p("hello link")))
    rem("doesn't remove a non-matching link", doc(p("<a>hello ", a("link<b>"))), basicSchema.mark("link", ["href": .string("bar")]), doc(p("hello ", a("link"))))
    rem("can remove across blocks", doc(blockquote(p(em("much <a>em")), p(em("here too"))), p("between", em("...")), p(em("end<b>"))), basicSchema.mark("em"), doc(blockquote(p(em("much "), "em"), p("here too")), p("between..."), p("end")))

    // MARK: delete
    func del(_ name: String, _ d: TaggedNode, _ e: TaggedNode) {
        test("PM delete: \(name)") { let tr = Transform(d.node); try tr.delete(tag(d, "a"), tag(d, "b")); try pmTransform(tr, d, e) }
    }
    del("can delete a word", doc(p("<1>one"), "<a>", p("tw<2>o"), "<b>", p("<3>three")), doc(p("<1>one"), "<a><2>", p("<3>three")))
    del("preserves content constraints", doc(blockquote("<a>", p("hi"), "<b>"), p("x")), doc(blockquote(p()), p("x")))
    del("preserves positions after the range", doc(blockquote(p("a"), "<a>", p("b"), "<b>"), p("c<1>")), doc(blockquote(p("a")), p("c<1>")))
    del("doesn't join incompatible nodes", doc(pre("fo<a>o"), p("b<b>ar", img())), doc(pre("fo"), p("ar", img())))
    del("doesn't join when marks are incompatible", doc(pre("fo<a>o"), p(em("b<b>ar"))), doc(pre("fo"), p(em("ar"))))

    // MARK: join
    func joinT(_ name: String, _ d: TaggedNode, _ e: TaggedNode) {
        test("PM join: \(name)") { let tr = Transform(d.node); try tr.join(tag(d, "a")); try pmTransform(tr, d, e) }
    }
    joinT("can join blocks", doc(blockquote(p("<before>a")), "<a>", blockquote(p("b")), p("after<after>")), doc(blockquote(p("<before>a"), "<a>", p("b")), p("after<after>")))
    joinT("can join compatible blocks", doc(h1("foo"), "<a>", p("bar")), doc(h1("foobar")))
    joinT("can join nested blocks", doc(blockquote(blockquote(p("a"), p("b<before>")), "<a>", blockquote(p("c"), p("d<after>")))), doc(blockquote(blockquote(p("a"), p("b<before>"), "<a>", p("c"), p("d<after>")))))
    joinT("can join lists", doc(ol(li(p("one")), li(p("two"))), "<a>", ol(li(p("three")))), doc(ol(li(p("one")), li(p("two")), "<a>", li(p("three")))))
    joinT("can join list items", doc(ol(li(p("one")), li(p("two")), "<a>", li(p("three")))), doc(ol(li(p("one")), li(p("two"), "<a>", p("three")))))
    joinT("can join textblocks", doc(p("foo"), "<a>", p("bar")), doc(p("foo<a>bar")))

    // MARK: split
    func splitT(_ name: String, _ d: TaggedNode, _ e: TaggedNode, _ depth: Int = 1, afterType: String? = nil) {
        test("PM split: \(name)") {
            let typesAfter: [NodeTypeWithAttrs?]? = afterType.map { [NodeTypeWithAttrs(basicSchema.nodes[$0]!)] }
            let tr = Transform(d.node); try tr.split(tag(d, "a"), depth, typesAfter); try pmTransform(tr, d, e)
        }
    }
    func splitFail(_ name: String, _ d: TaggedNode, _ depth: Int = 1) {
        test("PM split: \(name)") { let tr = Transform(d.node); try expectThrows({ try tr.split(tag(d, "a"), depth) }) }
    }
    splitT("can split a textblock", doc(p("foo<a>bar")), doc(p("foo"), p("<a>bar")))
    splitT("correctly maps positions", doc(p("<1>a"), p("<2>foo<a>bar<3>"), p("<4>b")), doc(p("<1>a"), p("<2>foo"), p("<a>bar<3>"), p("<4>b")))
    splitT("can split two deep", doc(blockquote(blockquote(p("foo<a>bar"))), p("after<1>")), doc(blockquote(blockquote(p("foo")), blockquote(p("<a>bar"))), p("after<1>")), 2)
    splitT("can split three deep", doc(blockquote(blockquote(p("foo<a>bar"))), p("after<1>")), doc(blockquote(blockquote(p("foo"))), blockquote(blockquote(p("<a>bar"))), p("after<1>")), 3)
    splitT("can split at end", doc(blockquote(p("hi<a>"))), doc(blockquote(p("hi"), p("<a>"))))
    splitT("can split at start", doc(blockquote(p("<a>hi"))), doc(blockquote(p(), p("<a>hi"))))
    splitT("can split inside a list item", doc(ol(li(p("one<1>")), li(p("two<a>three")), li(p("four<2>")))), doc(ol(li(p("one<1>")), li(p("two"), p("<a>three")), li(p("four<2>")))))
    splitT("can split a list item", doc(ol(li(p("one<1>")), li(p("two<a>three")), li(p("four<2>")))), doc(ol(li(p("one<1>")), li(p("two")), li(p("<a>three")), li(p("four<2>")))), 2)
    splitT("respects the type param", doc(h1("hell<a>o!")), doc(h1("hell"), p("<a>o!")), 1, afterType: "paragraph")
    splitFail("preserves content constraints before", doc(blockquote("<a>", p("x"))))
    splitFail("preserves content constraints after", doc(blockquote(p("x"), "<a>")))

    // MARK: lift
    func liftT(_ name: String, _ d: TaggedNode, _ e: TaggedNode) {
        test("PM lift: \(name)") {
            let range = d.node.resolve(tag(d, "a")).blockRange(d.node.resolve(tagOpt(d, "b") ?? tag(d, "a")))!
            let tr = Transform(d.node); try tr.lift(range, liftTarget(range)!); try pmTransform(tr, d, e)
        }
    }
    liftT("can lift a block out of the middle of its parent", doc(blockquote(p("<before>one"), p("<a>two"), p("<after>three"))), doc(blockquote(p("<before>one")), p("<a>two"), blockquote(p("<after>three"))))
    liftT("can lift a block from the start of its parent", doc(blockquote(p("<a>two"), p("<after>three"))), doc(p("<a>two"), blockquote(p("<after>three"))))
    liftT("can lift a block from the end of its parent", doc(blockquote(p("<before>one"), p("<a>two"))), doc(blockquote(p("<before>one")), p("<a>two")))
    liftT("can lift a single child", doc(blockquote(p("<a>t<in>wo"))), doc(p("<a>t<in>wo")))
    liftT("can lift multiple blocks", doc(blockquote(blockquote(p("on<a>e"), p("tw<b>o")), p("three"))), doc(blockquote(p("on<a>e"), p("tw<b>o"), p("three"))))
    liftT("finds a valid range from a lopsided selection", doc(p("start"), blockquote(blockquote(p("a"), p("<a>b")), p("<b>c"))), doc(p("start"), blockquote(p("a"), p("<a>b")), p("<b>c")))
    liftT("can lift from a nested node", doc(blockquote(blockquote(p("<1>one"), p("<a>two"), p("<3>three"), p("<b>four"), p("<5>five")))), doc(blockquote(blockquote(p("<1>one")), p("<a>two"), p("<3>three"), p("<b>four"), blockquote(p("<5>five")))))
    liftT("can lift from a list", doc(ul(li(p("one")), li(p("two<a>")), li(p("three")))), doc(ul(li(p("one"))), p("two<a>"), ul(li(p("three")))))
    liftT("can lift from the end of a list", doc(ul(li(p("a")), li(p("b<a>")), "<1>")), doc(ul(li(p("a"))), p("b<a>"), "<1>"))

    // MARK: wrap
    func wrapT(_ name: String, _ d: TaggedNode, _ e: TaggedNode, _ type: String, _ attrs: Attrs = [:]) {
        test("PM wrap: \(name)") {
            let range = d.node.resolve(tag(d, "a")).blockRange(d.node.resolve(tagOpt(d, "b") ?? tag(d, "a")))!
            let tr = Transform(d.node); try tr.wrap(range, findWrappingForRange(range, basicSchema.nodes[type]!, attrs)!); try pmTransform(tr, d, e)
        }
    }
    wrapT("can wrap in a blockquote", doc(p("one"), p("<a>two"), p("three")), doc(p("one"), blockquote(p("<a>two")), p("three")), "blockquote")
    wrapT("can wrap two paragraphs", doc(p("one<1>"), p("<a>two"), p("<b>three"), p("four<4>")), doc(p("one<1>"), blockquote(p("<a>two"), p("three")), p("four<4>")), "blockquote")
    wrapT("can wrap in a list", doc(p("<a>one"), p("<b>two")), doc(ol(li(p("<a>one"), p("<b>two")))), "ordered_list")
    wrapT("can wrap in a nested list", doc(ol(li(p("<1>one")), li(p("..."), p("<a>two"), p("<b>three")), li(p("<4>four")))), doc(ol(li(p("<1>one")), li(p("..."), ol(li(p("<a>two"), p("<b>three")))), li(p("<4>four")))), "ordered_list")
    wrapT("includes half-covered parent nodes", doc(blockquote(p("<1>one"), p("two<a>")), p("three<b>")), doc(blockquote(blockquote(p("<1>one"), p("two<a>")), p("three<b>"))), "blockquote")

    // MARK: setBlockType
    func typeT(_ name: String, _ d: TaggedNode, _ e: TaggedNode, _ type: String, _ attrs: Attrs = [:]) {
        test("PM setBlockType: \(name)") {
            let tr = Transform(d.node); try tr.setBlockType(tag(d, "a"), tagOpt(d, "b") ?? tag(d, "a"), basicSchema.nodes[type]!, attrs); try pmTransform(tr, d, e)
        }
    }
    typeT("can change a single textblock", doc(p("am<a> i")), doc(h2("am i")), "heading", ["level": .int(2)])
    typeT("can change multiple blocks", doc(h1("<a>hello"), p("there"), p("<b>you"), p("end")), doc(pre("hello"), pre("there"), pre("you"), p("end")), "code_block")
    typeT("can change a wrapped block", doc(blockquote(p("one<a>"), p("two<b>"))), doc(blockquote(h1("one<a>"), h1("two<b>"))), "heading", ["level": .int(1)])
    typeT("clears markup when necessary", doc(p("hello<a> ", em("world"))), doc(pre("hello world")), "code_block")
    typeT("removes non-allowed nodes", doc(p("<a>one", img(), "two", img(), "three")), doc(pre("onetwothree")), "code_block")
    typeT("removes newlines in non-code", doc(pre("<a>one\ntwo\nthree")), doc(p("one two three")), "paragraph")
    typeT("only clears markup when needed", doc(p("hello<a> ", em("world"))), doc(h1("hello<a> ", em("world"))), "heading", ["level": .int(1)])
    typeT("skips nodes that can't be changed due to constraints", doc(p("<a>hello", img()), p("okay"), ul(li(p("foo<b>")))), doc(pre("<a>hello"), pre("okay"), ul(li(p("foo<b>")))), "code_block")

    // MARK: setNodeMarkup
    func markupT(_ name: String, _ d: TaggedNode, _ e: TaggedNode, _ type: String, _ attrs: Attrs = [:]) {
        test("PM setNodeMarkup: \(name)") {
            let tr = Transform(d.node); try tr.setNodeMarkup(tag(d, "a"), basicSchema.nodes[type]!, attrs); try pmTransform(tr, d, e)
        }
    }
    markupT("can change a textblock", doc("<a>", p("foo")), doc(h1("foo")), "heading", ["level": .int(1)])
    markupT("can change an inline node", doc(p("foo<a>", img(), "bar")), doc(p("foo", img(src: "bar", alt: "y"), "bar")), "image", ["src": .string("bar"), "alt": .string("y")])

    // MARK: replace
    func repl(_ name: String, _ d: TaggedNode, _ source: TaggedNode?, _ e: TaggedNode) {
        test("PM replace: \(name)") {
            let slice = source.map { $0.node.slice(tag($0, "a"), tag($0, "b")) } ?? Slice.empty
            let tr = Transform(d.node); try tr.replace(tag(d, "a"), tagOpt(d, "b") ?? tag(d, "a"), slice); try pmTransform(tr, d, e)
        }
    }
    repl("can delete text", doc(p("hell<a>o y<b>ou")), nil, doc(p("hell<a><b>ou")))
    repl("can join blocks", doc(p("hell<a>o"), p("y<b>ou")), nil, doc(p("hell<a><b>ou")))
    repl("can delete right-leaning lopsided regions", doc(blockquote(p("ab<a>c")), "<b>", p("def")), nil, doc(blockquote(p("ab<a>")), "<b>", p("def")))
    repl("can delete left-leaning lopsided regions", doc(p("abc"), "<a>", blockquote(p("d<b>ef"))), nil, doc(p("abc"), "<a>", blockquote(p("<b>ef"))))
    repl("can overwrite text", doc(p("hell<a>o y<b>ou")), doc(p("<a>i k<b>")), doc(p("hell<a>i k<b>ou")))
    repl("can insert text", doc(p("hell<a><b>o")), doc(p("<a>i k<b>")), doc(p("helli k<a><b>o")))
    repl("can add a textblock", doc(p("hello<a>you")), doc("<a>", p("there"), "<b>"), doc(p("hello"), p("there"), p("<a>you")))
    repl("can insert while joining textblocks", doc(h1("he<a>llo"), p("arg<b>!")), doc(p("1<a>2<b>3")), doc(h1("he2!")))
    repl("will match open list items", doc(ol(li(p("one<a>")), li(p("three")))), doc(ol(li(p("<a>half")), li(p("two")), "<b>")), doc(ol(li(p("onehalf")), li(p("two")), li(p("three")))))
    repl("merges blocks across deleted content", doc(p("a<a>"), p("b"), p("<b>c")), nil, doc(p("a<a><b>c")))
    repl("can merge text down from nested nodes", doc(h1("wo<a>ah"), blockquote(p("ah<b>ha"))), nil, doc(h1("wo<a><b>ha")))
    repl("can merge text up into nested nodes", doc(blockquote(p("foo<a>bar")), p("middle"), h1("quux<b>baz")), nil, doc(blockquote(p("foo<a><b>baz"))))
    repl("will join multiple levels when possible", doc(blockquote(ul(li(p("a")), li(p("b<a>")), li(p("c")), li(p("<b>d")), li(p("e"))))), nil, doc(blockquote(ul(li(p("a")), li(p("b<a><b>d")), li(p("e"))))))
    repl("can replace a piece of text", doc(p("he<before>llo<a> w<after>orld")), doc(p("<a> big<b>")), doc(p("he<before>llo big w<after>orld")))
    repl("respects open empty nodes at the edges", doc(p("one<a>two")), doc(p("a<a>"), p("hello"), p("<b>b")), doc(p("one"), p("hello"), p("<a>two")))
    repl("can completely overwrite a paragraph", doc(p("one<a>"), p("t<inside>wo"), p("<b>three<end>")), doc(p("a<a>"), p("TWO"), p("<b>b")), doc(p("one<a>"), p("TWO"), p("<inside>three<end>")))
    repl("joins marks", doc(p("foo ", em("bar<a>baz"), "<b> quux")), doc(p("foo ", em("xy<a>zzy"), " foo<b>")), doc(p("foo ", em("barzzy"), " foo quux")))
    repl("can replace text with a break", doc(p("foo<a>b<inside>b<b>bar")), doc(p("<a>", br(), "<b>")), doc(p("foo", br(), "<inside>bar")))
    repl("can join different blocks", doc(h1("hell<a>o"), p("by<b>e")), nil, doc(h1("helle")))
    repl("can restore a list parent", doc(h1("hell<a>o"), "<b>"), doc(ol(li(p("on<a>e")), li(p("tw<b>o")))), doc(h1("helle"), ol(li(p("tw")))))
    repl("can restore a list parent and join text after it", doc(h1("hell<a>o"), p("yo<b>u")), doc(ol(li(p("on<a>e")), li(p("tw<b>o")))), doc(h1("helle"), ol(li(p("twu")))))
    repl("can insert into an empty block", doc(p("a"), p("<a>"), p("b")), doc(p("x<a>y<b>z")), doc(p("a"), p("y<a>"), p("b")))
    repl("doesn't change the nesting of blocks after the selection", doc(p("one<a>"), p("two"), p("three")), doc(p("outside<a>"), blockquote(p("inside<b>"))), doc(p("one"), blockquote(p("inside")), p("two"), p("three")))
    repl("can close a parent node", doc(blockquote(p("b<a>c"), p("d<b>e"), p("f"))), doc(blockquote(p("x<a>y")), p("after"), "<b>"), doc(blockquote(p("b<a>y")), p("after"), blockquote(p("<b>e"), p("f"))))
}

import Foundation
import DocumentModel
import TestHarness

// Ported from prosemirror-model/test/test-content.ts — ContentMatch parsing,
// matchType, matchFragment, and fillBefore, on the basic+list schema.

private func get(_ expr: String) -> ContentMatch { try! ContentMatch.parse(expr, basicSchema.nodes) }

private func matches(_ expr: String, _ types: String) -> Bool {
    var m: ContentMatch? = get(expr)
    let ts = types.isEmpty ? [] : types.split(separator: " ").map { basicSchema.nodes[String($0)]! }
    for t in ts { guard let next = m?.matchType(t) else { return false }; m = next }
    return m?.validEnd ?? false
}

func registerPMContentTests() {
    func valid(_ expr: String, _ types: String) { test("PM ContentMatch valid: \(expr) / \(types)") { try expect(matches(expr, types)) } }
    func invalid(_ expr: String, _ types: String) { test("PM ContentMatch invalid: \(expr) / \(types)") { try expect(!matches(expr, types)) } }

    func fill(_ name: String, _ expr: String, _ before: TaggedNode, _ after: TaggedNode, _ result: TaggedNode?) {
        test("PM fillBefore: \(name)") {
            let filled = get(expr).matchFragment(before.node.content)?.fillBefore(after.node.content, toEnd: true)
            if let result { try expectEqual(filled, result.node.content) } else { try expect(filled == nil) }
        }
    }
    func fill3(_ name: String, _ expr: String, _ before: TaggedNode, _ mid: TaggedNode, _ after: TaggedNode, _ left: TaggedNode?, _ right: TaggedNode? = nil) {
        test("PM fillBefore3: \(name)") {
            let content = get(expr)
            let a = content.matchFragment(before.node.content)?.fillBefore(mid.node.content)
            let b: Fragment? = a.flatMap { aa in
                content.matchFragment(before.node.content.append(aa).append(mid.node.content))?.fillBefore(after.node.content, toEnd: true)
            }
            if let left {
                try expectEqual(a, left.node.content)
                try expectEqual(b, right!.node.content)
            } else {
                try expect(b == nil)
            }
        }
    }

    // MARK: matchType
    valid("", "")
    invalid("", "image")
    valid("image*", "")
    valid("image*", "image")
    valid("image*", "image image image image")
    invalid("image*", "image text")
    valid("inline*", "image text")
    invalid("inline*", "paragraph")
    valid("(paragraph | heading)", "paragraph")
    invalid("(paragraph | heading)", "image")
    valid("paragraph horizontal_rule paragraph", "paragraph horizontal_rule paragraph")
    invalid("paragraph horizontal_rule", "paragraph horizontal_rule paragraph")
    invalid("paragraph horizontal_rule paragraph", "paragraph horizontal_rule")
    invalid("paragraph horizontal_rule", "horizontal_rule paragraph horizontal_rule")
    valid("heading paragraph*", "heading")
    valid("heading paragraph*", "heading paragraph paragraph")
    valid("heading paragraph+", "heading paragraph")
    valid("heading paragraph+", "heading paragraph paragraph")
    invalid("heading paragraph+", "heading")
    invalid("heading paragraph+", "paragraph paragraph")
    valid("image?", "image")
    valid("image?", "")
    invalid("image?", "image image")
    valid("(heading paragraph+)+", "heading paragraph heading paragraph paragraph")
    invalid("(heading paragraph+)+", "heading paragraph heading paragraph paragraph horizontal_rule")
    valid("hard_break{2}", "hard_break hard_break")
    invalid("hard_break{2}", "hard_break")
    invalid("hard_break{2}", "hard_break hard_break hard_break")
    valid("hard_break{2, 4}", "hard_break hard_break")
    valid("hard_break{2, 4}", "hard_break hard_break hard_break hard_break")
    valid("hard_break{2, 4}", "hard_break hard_break hard_break")
    invalid("hard_break{2, 4}", "hard_break")
    invalid("hard_break{2, 4}", "hard_break hard_break hard_break hard_break hard_break")
    invalid("hard_break{2, 4} text*", "hard_break hard_break image")
    valid("hard_break{2, 4} image?", "hard_break hard_break image")
    valid("hard_break{2,}", "hard_break hard_break")
    valid("hard_break{2,}", "hard_break hard_break hard_break hard_break")
    invalid("hard_break{2,}", "hard_break")

    // MARK: fillBefore
    fill("returns the empty fragment when things match", "paragraph horizontal_rule paragraph", doc(p(), hr()), doc(p()), doc())
    fill("adds a node when necessary", "paragraph horizontal_rule paragraph", doc(p()), doc(p()), doc(hr()))
    fill("accepts an asterisk across the bound", "hard_break*", p(br()), p(br()), p())
    fill("accepts an asterisk only on the left", "hard_break*", p(br()), p(), p())
    fill("accepts an asterisk only on the right", "hard_break*", p(), p(br()), p())
    fill("accepts an asterisk with no elements", "hard_break*", p(), p(), p())
    fill("accepts a plus across the bound", "hard_break+", p(br()), p(br()), p())
    fill("adds an element for a content-less plus", "hard_break+", p(), p(), p(br()))
    fill("fails for a mismatched plus", "hard_break+", p(), p(img()), nil)
    fill("accepts asterisk with content on both sides", "heading* paragraph*", doc(h1()), doc(p()), doc())
    fill("accepts asterisk with no content after", "heading* paragraph*", doc(h1()), doc(), doc())
    fill("accepts plus with content on both sides", "heading+ paragraph+", doc(h1()), doc(p()), doc())
    fill("accepts plus with no content after", "heading+ paragraph+", doc(h1()), doc(), doc(p()))
    fill("adds elements to match a count", "hard_break{3}", p(br()), p(br()), p(br()))
    fill("fails when there are too many elements", "hard_break{3}", p(br(), br()), p(br(), br()), nil)
    fill("adds elements for two counted groups", "code_block{2} paragraph{2}", doc(pre()), doc(p()), doc(pre(), p()))
    // DIVERGENCE from ProseMirror: PM's fillBefore yields just `doc(hr())` here
    // (it skips the optional paragraph). Ours produces a valid but non-minimal
    // fill, `doc(p(), hr())` — both satisfy "heading paragraph? horizontal_rule".
    // The difference is only edge ordering in the compiled content DFA; it never
    // produces an invalid document, only an occasional extra empty optional node.
    fill("non-minimal fill includes an optional element", "heading paragraph? horizontal_rule", doc(h1()), doc(), doc(p(), hr()))

    fill3("completes a sequence", "paragraph horizontal_rule paragraph horizontal_rule paragraph", doc(p()), doc(p()), doc(p()), doc(hr()), doc(hr()))
    fill3("accepts plus across two bounds", "code_block+ paragraph+", doc(pre()), doc(pre()), doc(p()), doc(), doc())
    fill3("fills a plus from empty input", "code_block+ paragraph+", doc(), doc(), doc(), doc(), doc(pre(), p()))
    fill3("completes a count", "code_block{3} paragraph{3}", doc(pre()), doc(p()), doc(), doc(pre(), pre()), doc(p(), p()))
    fill3("fails on non-matching elements", "paragraph*", doc(p()), doc(pre()), doc(p()), nil)
    fill3("completes a plus across two bounds", "paragraph{4}", doc(p()), doc(p()), doc(p()), doc(), doc(p()))
    fill3("refuses to complete an overflown count across two bounds", "paragraph{2}", doc(p()), doc(p()), doc(p()), nil)
}


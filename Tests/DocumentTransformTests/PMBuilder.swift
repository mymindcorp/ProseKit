import Foundation
import DocumentModel

// A Swift port of `prosemirror-test-builder`: the basic + list schema, and a
// document builder that tracks `<a>`/`<b>`/`<c>` position markers (tags) exactly
// like ProseMirror's, so its transform/replace/selection test suites can be
// ported verbatim. (See prosemirror-test-builder/src/build.ts.)

let basicSchema: Schema = {
    let nodes: [(String, NodeSpec)] = [
        ("doc", NodeSpec(content: "block+")),
        ("paragraph", NodeSpec(content: "inline*", group: "block")),
        ("blockquote", NodeSpec(content: "block+", group: "block", defining: true)),
        ("horizontal_rule", NodeSpec(group: "block")),
        ("heading", NodeSpec(content: "inline*", group: "block",
                             attrs: ["level": AttributeSpec(default: .int(1))], defining: true)),
        ("code_block", NodeSpec(content: "text*", marks: "", group: "block", code: true, defining: true)),
        ("text", NodeSpec(group: "inline")),
        ("image", NodeSpec(group: "inline", inline: true,
                           attrs: ["src": AttributeSpec(), "alt": AttributeSpec(default: .null), "title": AttributeSpec(default: .null)])),
        ("hard_break", NodeSpec(group: "inline", inline: true)),
        // addListNodes(..., "paragraph block*", "block")
        ("ordered_list", NodeSpec(content: "list_item+", group: "block", attrs: ["order": AttributeSpec(default: .int(1))])),
        ("bullet_list", NodeSpec(content: "list_item+", group: "block")),
        ("list_item", NodeSpec(content: "paragraph block*", defining: true)),
    ]
    let marks: [(String, MarkSpec)] = [
        ("link", MarkSpec(attrs: ["href": AttributeSpec(), "title": AttributeSpec(default: .null)], inclusive: false)),
        ("em", MarkSpec()),
        ("strong", MarkSpec()),
        ("code", MarkSpec()),
    ]
    return try! Schema(nodes: nodes, marks: marks, topNode: "doc")
}()

/// A node + its tag positions. `tag(node, "a")` reads a position back.
struct TaggedNode {
    let node: Node
    let tags: [String: Int]
}
func tag(_ t: TaggedNode, _ name: String) -> Int {
    guard let v = t.tags[name] else { fatalError("missing tag <\(name)>") }
    return v
}

/// A builder child: a string (possibly with `<tag>` markers) or a built fragment.
struct PMChild: ExpressibleByStringLiteral {
    enum Kind { case string(String); case frag([Node], [String: Int], _ enter: Bool) }
    let kind: Kind
    init(stringLiteral s: String) { kind = .string(s) }
    fileprivate init(_ kind: Kind) { self.kind = kind }
}

private func flatten(_ children: [PMChild], _ f: (Node) -> Node) -> (nodes: [Node], tags: [String: Int]) {
    var nodes: [Node] = []
    var tags: [String: Int] = [:]
    var pos = 0
    for child in children {
        switch child.kind {
        case let .string(s):
            let arr = Array(s)
            var out = ""
            var k = 0
            while k < arr.count {
                if arr[k] == "<", let gt = arr[(k + 1)...].firstIndex(of: ">"), gt > k + 1,
                   arr[(k + 1)..<gt].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                    tags[String(arr[(k + 1)..<gt])] = pos
                    k = gt + 1
                } else {
                    out.append(arr[k]); pos += 1; k += 1
                }
            }
            if !out.isEmpty { nodes.append(f(basicSchema.text(out))) }
        case let .frag(childNodes, childTags, enter):
            for (id, p) in childTags { tags[id] = p + (enter ? 1 : 0) + pos }
            for n in childNodes {
                let node = f(n)
                pos += node.nodeSize
                nodes.append(node)
            }
        }
    }
    return (nodes, tags)
}

private func buildBlock(_ name: String, _ attrs: Attrs, _ children: [PMChild]) -> (Node, [String: Int]) {
    let (nodes, tags) = flatten(children) { $0 }
    return (try! basicSchema.node(name, attrs, content: Fragment.from(nodes)), tags)
}

private func block(_ name: String, _ attrs: Attrs, _ children: [PMChild]) -> PMChild {
    let (node, tags) = buildBlock(name, attrs, children)
    return PMChild(.frag([node], tags, true))
}

private func markBuilder(_ name: String, _ attrs: Attrs, _ children: [PMChild]) -> PMChild {
    let m = basicSchema.mark(name, attrs)
    let (nodes, tags) = flatten(children) { n in
        let set = m.addToSet(n.marks)
        return set.count > n.marks.count ? n.mark(set) : n
    }
    return PMChild(.frag(nodes, tags, false))
}

// MARK: - Builders (prosemirror-test-builder aliases)

func doc(_ c: PMChild...) -> TaggedNode { let (n, t) = buildBlock("doc", [:], c); return TaggedNode(node: n, tags: t) }
func p(_ c: PMChild...) -> PMChild { block("paragraph", [:], c) }
func blockquote(_ c: PMChild...) -> PMChild { block("blockquote", [:], c) }
func pre(_ c: PMChild...) -> PMChild { block("code_block", [:], c) }
func h1(_ c: PMChild...) -> PMChild { block("heading", ["level": .int(1)], c) }
func h2(_ c: PMChild...) -> PMChild { block("heading", ["level": .int(2)], c) }
func h3(_ c: PMChild...) -> PMChild { block("heading", ["level": .int(3)], c) }
func ul(_ c: PMChild...) -> PMChild { block("bullet_list", [:], c) }
func ol(_ c: PMChild...) -> PMChild { block("ordered_list", [:], c) }
func li(_ c: PMChild...) -> PMChild { block("list_item", [:], c) }
func hr() -> PMChild { block("horizontal_rule", [:], []) }
func img(src: String = "img.png", alt: String? = nil) -> PMChild {
    var attrs: Attrs = ["src": .string(src)]
    if let alt { attrs["alt"] = .string(alt) }
    return block("image", attrs, [])
}
func br() -> PMChild { block("hard_break", [:], []) }
func em(_ c: PMChild...) -> PMChild { markBuilder("em", [:], c) }
func strong(_ c: PMChild...) -> PMChild { markBuilder("strong", [:], c) }
func code(_ c: PMChild...) -> PMChild { markBuilder("code", [:], c) }
func a(_ c: PMChild..., href: String = "foo") -> PMChild { markBuilder("link", ["href": .string(href)], c) }

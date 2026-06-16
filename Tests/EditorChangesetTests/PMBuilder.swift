import Foundation
import DocumentModel

// A Swift port of `prosemirror-test-builder`: the basic + list schema, and a
// document builder that tracks `<a>`/`<b>`/`<c>` position markers (tags) exactly
// like ProseMirror's, so its transform/replace/selection/content test suites can
// be ported verbatim. (See prosemirror-test-builder/src/build.ts.)

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

/// A builder child: a string (with optional `<tag>` markers), a built block node,
/// or a flat run of mark-wrapped nodes.
protocol PMContentChild {}
extension String: PMContentChild {}

/// A built node + the document positions of its tags. Also usable as a child.
struct TaggedNode: PMContentChild {
    let node: Node
    let tags: [String: Int]
}
/// A flat run of nodes produced by a mark builder.
struct MarkFrag: PMContentChild {
    let nodes: [Node]
    let tags: [String: Int]
}

func tag(_ t: TaggedNode, _ name: String) -> Int {
    guard let v = t.tags[name] else { fatalError("missing tag <\(name)>") }
    return v
}

private func flatten(_ children: [any PMContentChild], _ f: (Node) -> Node) -> (nodes: [Node], tags: [String: Int]) {
    var nodes: [Node] = []
    var tags: [String: Int] = [:]
    var pos = 0
    for child in children {
        switch child {
        case let s as String:
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
        case let t as TaggedNode: // a block node — its inner tags are 1 (the open token) deeper
            for (id, p) in t.tags { tags[id] = p + 1 + pos }
            let node = f(t.node); pos += node.nodeSize; nodes.append(node)
        case let mf as MarkFrag: // a flat run — same depth
            for (id, p) in mf.tags { tags[id] = p + pos }
            for n in mf.nodes { let node = f(n); pos += node.nodeSize; nodes.append(node) }
        default: break
        }
    }
    return (nodes, tags)
}

private func block(_ name: String, _ attrs: Attrs, _ children: [any PMContentChild]) -> TaggedNode {
    let (nodes, tags) = flatten(children) { $0 }
    return TaggedNode(node: try! basicSchema.node(name, attrs, content: Fragment.from(nodes)), tags: tags)
}

private func markBuilder(_ name: String, _ attrs: Attrs, _ children: [any PMContentChild]) -> MarkFrag {
    let m = basicSchema.mark(name, attrs)
    let (nodes, tags) = flatten(children) { n in
        let set = m.addToSet(n.marks)
        return set.count > n.marks.count ? n.mark(set) : n
    }
    return MarkFrag(nodes: nodes, tags: tags)
}

// MARK: - Builders (prosemirror-test-builder aliases)

func doc(_ c: any PMContentChild...) -> TaggedNode { block("doc", [:], c) }
func p(_ c: any PMContentChild...) -> TaggedNode { block("paragraph", [:], c) }
func blockquote(_ c: any PMContentChild...) -> TaggedNode { block("blockquote", [:], c) }
func pre(_ c: any PMContentChild...) -> TaggedNode { block("code_block", [:], c) }
func h1(_ c: any PMContentChild...) -> TaggedNode { block("heading", ["level": .int(1)], c) }
func h2(_ c: any PMContentChild...) -> TaggedNode { block("heading", ["level": .int(2)], c) }
func h3(_ c: any PMContentChild...) -> TaggedNode { block("heading", ["level": .int(3)], c) }
func ul(_ c: any PMContentChild...) -> TaggedNode { block("bullet_list", [:], c) }
func ol(_ c: any PMContentChild...) -> TaggedNode { block("ordered_list", [:], c) }
func li(_ c: any PMContentChild...) -> TaggedNode { block("list_item", [:], c) }
func hr() -> TaggedNode { block("horizontal_rule", [:], []) }
func br() -> TaggedNode { block("hard_break", [:], []) }
func img(src: String = "img.png", alt: String? = nil) -> TaggedNode {
    var attrs: Attrs = ["src": .string(src)]
    if let alt { attrs["alt"] = .string(alt) }
    return block("image", attrs, [])
}
func em(_ c: any PMContentChild...) -> MarkFrag { markBuilder("em", [:], c) }
func strong(_ c: any PMContentChild...) -> MarkFrag { markBuilder("strong", [:], c) }
func code(_ c: any PMContentChild...) -> MarkFrag { markBuilder("code", [:], c) }
func a(_ c: any PMContentChild..., href: String = "foo") -> MarkFrag { markBuilder("link", ["href": .string(href)], c) }

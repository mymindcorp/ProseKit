import Foundation
import DocumentModel
import TestHarness

// Ported from prosemirror-model/test/test-resolve.ts — ResolvedPos structure
// (depth/node/start/end/before/after/parentOffset/nodeBefore/nodeAfter) and
// posAtIndex.

private struct Ref { let node: Node; let start: Int; let end: Int }
private enum Side { case none; case text(String); case node(Node) }
private struct Exp { let depths: [Ref]; let parentOffset: Int; let before: Side; let after: Side }

func registerPMResolveTests() {
    let testDoc = doc(p("ab"), blockquote(p(em("cd"), "ef"))).node
    let dRef = Ref(node: testDoc, start: 0, end: 12)
    let p1 = Ref(node: testDoc.child(0), start: 1, end: 3)
    let blk = Ref(node: testDoc.child(1), start: 5, end: 11)
    let p2 = Ref(node: blk.node.child(0), start: 6, end: 10)

    let table: [Int: Exp] = [
        0: Exp(depths: [dRef], parentOffset: 0, before: .none, after: .node(p1.node)),
        1: Exp(depths: [dRef, p1], parentOffset: 0, before: .none, after: .text("ab")),
        2: Exp(depths: [dRef, p1], parentOffset: 1, before: .text("a"), after: .text("b")),
        3: Exp(depths: [dRef, p1], parentOffset: 2, before: .text("ab"), after: .none),
        4: Exp(depths: [dRef], parentOffset: 4, before: .node(p1.node), after: .node(blk.node)),
        5: Exp(depths: [dRef, blk], parentOffset: 0, before: .none, after: .node(p2.node)),
        6: Exp(depths: [dRef, blk, p2], parentOffset: 0, before: .none, after: .text("cd")),
        7: Exp(depths: [dRef, blk, p2], parentOffset: 1, before: .text("c"), after: .text("d")),
        8: Exp(depths: [dRef, blk, p2], parentOffset: 2, before: .text("cd"), after: .text("ef")),
        9: Exp(depths: [dRef, blk, p2], parentOffset: 3, before: .text("e"), after: .text("f")),
        10: Exp(depths: [dRef, blk, p2], parentOffset: 4, before: .text("ef"), after: .none),
        11: Exp(depths: [dRef, blk], parentOffset: 6, before: .node(p2.node), after: .none),
        12: Exp(depths: [dRef], parentOffset: 12, before: .node(blk.node), after: .none),
    ]

    test("PM resolve: reflects the document structure") {
        for pos in 0...testDoc.content.size {
            let r = testDoc.resolve(pos)
            let e = table[pos]!
            try expectEqual(r.depth, e.depths.count - 1, "depth@\(pos)")
            for i in 0..<e.depths.count {
                try expect(r.node(i) == e.depths[i].node, "node(\(i))@\(pos)")
                try expectEqual(r.start(i), e.depths[i].start, "start(\(i))@\(pos)")
                try expectEqual(r.end(i), e.depths[i].end, "end(\(i))@\(pos)")
                if i > 0 {
                    try expectEqual(r.before(i), e.depths[i].start - 1, "before(\(i))@\(pos)")
                    try expectEqual(r.after(i), e.depths[i].end + 1, "after(\(i))@\(pos)")
                }
            }
            try expectEqual(r.parentOffset, e.parentOffset, "parentOffset@\(pos)")
            switch e.before {
            case .none: try expect(r.nodeBefore == nil, "nodeBefore nil@\(pos)")
            case let .text(s): try expectEqual(r.nodeBefore?.textContent, s, "nodeBefore text@\(pos)")
            case let .node(n): try expect(r.nodeBefore == n, "nodeBefore node@\(pos)")
            }
            switch e.after {
            case .none: try expect(r.nodeAfter == nil, "nodeAfter nil@\(pos)")
            case let .text(s): try expectEqual(r.nodeAfter?.textContent, s, "nodeAfter text@\(pos)")
            case let .node(n): try expect(r.nodeAfter == n, "nodeAfter node@\(pos)")
            }
        }
    }

    test("PM resolve: has a working posAtIndex method") {
        let d = doc(blockquote(p("one"), blockquote(p("two ", em("three")), p("four")))).node
        let pThree = d.resolve(12) // Start of em("three")
        try expectEqual(pThree.posAtIndex(0), 8)
        try expectEqual(pThree.posAtIndex(1), 12)
        try expectEqual(pThree.posAtIndex(2), 17)
        try expectEqual(pThree.posAtIndex(0, 2), 7)
        try expectEqual(pThree.posAtIndex(1, 2), 18)
        try expectEqual(pThree.posAtIndex(2, 2), 24)
        try expectEqual(pThree.posAtIndex(0, 1), 1)
        try expectEqual(pThree.posAtIndex(1, 1), 6)
        try expectEqual(pThree.posAtIndex(2, 1), 25)
        try expectEqual(pThree.posAtIndex(0, 0), 0)
        try expectEqual(pThree.posAtIndex(1, 0), 26)
    }
}

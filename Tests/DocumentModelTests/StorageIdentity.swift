import Foundation
import DocumentModel
import TestHarness

// `Node.copy(content:)` and `Fragment.replaceChild` skip rebuilding when the
// content they are handed is the content they already have. Upstream tests that
// with a JavaScript `==`, which compares references; the port used Swift's `==`,
// which compares structurally and so walked both subtrees to decide whether to
// avoid one array copy.
//
// They now compare storage instead. That answers a narrower question — sharing
// storage proves equality, not sharing it proves nothing — so the check can now
// say "rebuild" where it used to say "reuse". These hold the results to being
// the same either way, since that is the whole claim: only the work changes.

func registerStorageIdentityTests() {
    // Cuts and joins pass along a length they already know rather than counting
    // the result, and every document position rests on that length. The strings
    // are the ones where characters and scalars part company.
    let trickyText = ["abc", "a\r", "\nb", "e\u{301}x", "\u{301}y", "🇺", "🇸🇬🇧", "x🇺", "👩", "\u{200D}💻z",
                      "👩\u{200D}💻", "漢字", "é", "\u{0600}", "\u{0600}q", "क", "\u{94D}ष", "abc🙂def"]

    test("text cuts: every cut holds the characters it says, and knows their count") {
        for string in trickyText {
            let node = B.t(string)
            let chars = Array(string)
            for lo in 0..<chars.count {
                for hi in (lo + 1)...chars.count {
                    let cut = node.cut(lo, hi)
                    try expectEqual(cut.text, String(chars[lo..<hi]), "\(string.debugDescription) \(lo)..<\(hi)")
                    try expectEqual(cut.nodeSize, hi - lo, "\(string.debugDescription) \(lo)..<\(hi)")
                    try expectEqual(cut.nodeSize, cut.text?.count)
                    let fragment = Fragment.from(node).cut(lo, hi)
                    try expectEqual(fragment.size, hi - lo)
                    try expectEqual(fragment.textBetween(0, hi - lo), String(chars[lo..<hi]))
                }
            }
        }
    }

    test("text joins: a joined node's size is its real character count") {
        for left in trickyText {
            for right in trickyText {
                let joined = Fragment.from(B.t(left)).append(Fragment.from(B.t(right)))
                let whole = left + right
                try expectEqual(joined.size, whole.count, "\(left.debugDescription) + \(right.debugDescription)")
                try expectEqual(joined.child(0).nodeSize, whole.count)
                try expectEqual(Fragment.from([B.t(left), B.t(right)]).size, whole.count)
            }
        }
    }

    test("copies of a node compare equal, and differ once anything does") {
        let node = B.p("hello")
        let copy = node
        try expect(copy == node)
        try expectEqual(copy.hashValue, node.hashValue)
        try expect(B.p("hello") == node, "equal in value, separate in storage")
        try expect(B.p("hellp") != node)
    }

    test("changedDescendants: visits only what an edit rebuilt") {
        let old = B.doc(B.p("a"), B.p("b"), B.p("c"))
        var visited: [String] = []
        func record(_ node: Node, _ pos: Int) -> Bool {
            visited.append("\(node.type.name)@\(pos)")
            return true
        }
        // One child replaced: the siblings keep their storage and are skipped.
        let edited = old.copy(content: old.content.replaceChild(1, B.p("bb")))
        edited.changedDescendants(since: old, record)
        try expectEqual(visited, ["paragraph@3", "text@4"])

        // A child inserted in front shifts the rest, which are still found.
        visited = []
        let inserted = old.copy(content: Fragment.from([B.p("new")] + (0..<old.childCount).map { old.child($0) }))
        inserted.changedDescendants(since: old, record)
        try expectEqual(visited, ["paragraph@0", "text@1"])

        // Nothing changed, nothing visited; returning false stops the descent.
        visited = []
        old.changedDescendants(since: old, record)
        try expectEqual(visited, [])
        edited.changedDescendants(since: old) { node, pos in visited.append("\(node.type.name)@\(pos)"); return false }
        try expectEqual(visited, ["paragraph@3"])
    }

    test("copy: passing back the same content returns the same node") {
        let node = B.p("hello")
        try expect(node.copy(content: node.content) == node)
        try expectEqual(node.copy(content: node.content).content.size, node.content.size)
    }

    test("copy: no content at all returns the node itself") {
        let node = B.p("hello")
        try expectEqual(node.copy(), node)
    }

    test("copy: rebuilt-but-equal content gives an equal node") {
        let node = B.p("hello")
        // A fragment with the same children, built fresh — equal in value,
        // separate in storage, which is the case that used to be walked.
        let rebuilt = Fragment.from((0..<node.childCount).map { node.child($0) })
        let copied = node.copy(content: rebuilt)
        try expectEqual(copied, node)
        try expectEqual(copied.type.name, node.type.name)
        try expectEqual(copied.attrs, node.attrs)
        try expectEqual(copied.marks, node.marks)
        try expectEqual(copied.textContent, node.textContent)
    }

    test("copy: different content gives a different node") {
        let node = B.p("hello")
        let changed = node.copy(content: Fragment.from(B.t("goodbye")))
        try expect(changed != node)
        try expectEqual(changed.textContent, "goodbye")
    }

    test("replaceChild: the same child leaves the fragment equal") {
        let doc = B.doc(B.p("a"), B.p("b"), B.p("c"))
        let same = doc.content.replaceChild(1, doc.child(1))
        try expectEqual(same, doc.content)
        try expectEqual(same.size, doc.content.size)
    }

    test("replaceChild: an equal-but-rebuilt child leaves the fragment equal") {
        let doc = B.doc(B.p("a"), B.p("b"), B.p("c"))
        let rebuilt = B.p("b")
        try expectEqual(rebuilt, doc.child(1))
        let replaced = doc.content.replaceChild(1, rebuilt)
        try expectEqual(replaced, doc.content)
        try expectEqual(replaced.size, doc.content.size)
        try expectEqual(replaced.child(1).textContent, "b")
    }

    test("replaceChild: a different child changes the fragment and its size") {
        let doc = B.doc(B.p("a"), B.p("b"), B.p("c"))
        let replaced = doc.content.replaceChild(1, B.p("longer"))
        try expect(replaced != doc.content)
        try expectEqual(replaced.child(1).textContent, "longer")
        try expectEqual(replaced.size, doc.content.size + 5)
    }

    // The operations built on top of these are where a wrong answer would show:
    // every replace closes each level with `copy`, and marking a range rebuilds
    // one child per block.
    test("storage identity: edits through replace are unchanged") {
        let doc = B.doc(B.p("one"), B.p("two"), B.p("three"))
        // Position 2 is inside the first paragraph; 5 would be the boundary
        // between blocks, where loose text isn't valid content.
        let inserted = try doc.replace(2, 2, Slice(content: Fragment.from(B.t("X")), openStart: 0, openEnd: 0))
        try expectEqual(inserted.textContent, "oXnetwothree")
        try expectEqual(inserted.childCount, 3)
        try inserted.check()

        let deleted = try doc.replace(1, 4, Slice.empty)
        try expectEqual(deleted.textContent, "twothree")
        try deleted.check()

        // Replacing a range with content equal to what was there gives the
        // document back unchanged — the case the identity check has to get
        // right rather than merely fast.
        let same = try doc.replace(1, 4, Slice(content: Fragment.from(B.t("one")), openStart: 0, openEnd: 0))
        try expectEqual(same, doc)
    }

    test("storage identity: a document survives a round of edits intact") {
        var doc = B.doc(B.p("alpha"), B.p("beta"), B.p("gamma"))
        let original = doc
        // Insert then delete the same text at the same place, block by block.
        var pos = 1
        for i in 0..<doc.childCount {
            let insert = Slice(content: Fragment.from(B.t("zz")), openStart: 0, openEnd: 0)
            doc = try doc.replace(pos, pos, insert)
            doc = try doc.replace(pos, pos + 2, Slice.empty)
            pos += original.child(i).nodeSize
        }
        try expectEqual(doc, original)
        try doc.check()
    }
}

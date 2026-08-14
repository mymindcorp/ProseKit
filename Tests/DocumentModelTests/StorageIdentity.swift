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

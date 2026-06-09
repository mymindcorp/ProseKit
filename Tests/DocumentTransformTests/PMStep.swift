import Foundation
import DocumentModel
import DocumentTransform
import TestHarness

// Ported from prosemirror-transform/test/test-step.ts — Step.merge.

private let stepDoc = doc(p("foobar")).node

private func mkStep(_ from: Int, _ to: Int, _ val: String?) -> Step {
    switch val {
    case "+em": return AddMarkStep(from, to, basicSchema.mark("em"))
    case "-em": return RemoveMarkStep(from, to, basicSchema.mark("em"))
    case let v?: return ReplaceStep(from, to, Slice(content: Fragment.from(basicSchema.text(v)), openStart: 0, openEnd: 0))
    case nil: return ReplaceStep(from, to, .empty)
    }
}

func registerPMStepTests() {
    func yes(_ name: String, _ f1: Int, _ t1: Int, _ v1: String?, _ f2: Int, _ t2: Int, _ v2: String?) {
        test("PM Step merge: \(name)") {
            let step1 = mkStep(f1, t1, v1), step2 = mkStep(f2, t2, v2)
            guard let merged = step1.merge(step2) else { try expect(false, "expected steps to merge"); return }
            let viaMerged = merged.apply(stepDoc).doc
            let viaBoth = step2.apply(step1.apply(stepDoc).doc!).doc
            try expectEqual(viaMerged, viaBoth)
        }
    }
    func no(_ name: String, _ f1: Int, _ t1: Int, _ v1: String?, _ f2: Int, _ t2: Int, _ v2: String?) {
        test("PM Step merge: \(name)") {
            try expect(mkStep(f1, t1, v1).merge(mkStep(f2, t2, v2)) == nil)
        }
    }

    yes("merges typing changes", 2, 2, "a", 3, 3, "b")
    yes("merges inverse typing", 2, 2, "a", 2, 2, "b")
    no("doesn't merge separated typing", 2, 2, "a", 4, 4, "b")
    no("doesn't merge inverted separated typing", 3, 3, "a", 2, 2, "b")
    yes("merges adjacent backspaces", 3, 4, nil, 2, 3, nil)
    yes("merges adjacent deletes", 2, 3, nil, 2, 3, nil)
    no("doesn't merge separate backspaces", 1, 2, nil, 2, 3, nil)
    yes("merges backspace and type", 2, 3, nil, 2, 2, "x")
    yes("merges longer adjacent inserts", 2, 2, "quux", 6, 6, "baz")
    yes("merges inverted longer inserts", 2, 2, "quux", 2, 2, "baz")
    yes("merges longer deletes", 2, 5, nil, 2, 4, nil)
    yes("merges inverted longer deletes", 4, 6, nil, 2, 4, nil)
    yes("merges overwrites", 3, 4, "x", 4, 5, "y")
    yes("merges adding adjacent styles", 1, 2, "+em", 2, 4, "+em")
    yes("merges adding overlapping styles", 1, 3, "+em", 2, 4, "+em")
    no("doesn't merge separate styles", 1, 2, "+em", 3, 4, "+em")
    yes("merges removing adjacent styles", 1, 2, "-em", 2, 4, "-em")
    yes("merges removing overlapping styles", 1, 3, "-em", 2, 4, "-em")
    no("doesn't merge removing separate styles", 1, 2, "-em", 3, 4, "-em")
}

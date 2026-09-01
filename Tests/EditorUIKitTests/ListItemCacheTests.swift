#if canImport(UIKit)
import XCTest
import UIKit
import DocumentModel
import SchemaKit
@testable import EditorUIKit

/// A list is one top-level child, so the incremental build's per-child reuse
/// cannot help inside it: every keystroke in a list used to lay out every item.
/// Items are now cached in local coordinates and re-emitted where they next
/// sit. The cache is only worth having if what comes out of it is exactly what
/// a cold layout produces, so a cold layout is the oracle throughout.
@MainActor
final class ListItemCacheTests: XCTestCase {
    private let width: CGFloat = 362
    private let words = Array(repeating: "lorem ipsum dolor sit amet", count: 4).joined(separator: " ")

    private func listDoc(_ s: Schema, kind: String, items texts: [String]) -> Node {
        let itemType = kind == "taskList" ? "taskItem" : "listItem"
        let items = texts.enumerated().map { i, t -> Node in
            let p = try! s.node("paragraph", [:], content: Fragment.from([s.text(t)]))
            let attrs: Attrs = kind == "taskList" ? ["checked": .bool(i % 3 == 0)] : [:]
            return try! s.node(itemType, attrs, content: Fragment.from([p]))
        }
        return try! s.node("doc", [:], content: Fragment.from([
            try! s.node(kind, [:], content: Fragment.from(items))]))
    }

    /// Everything a reader could see or tap, flattened for comparison.
    private func fingerprint(_ l: DocumentLayout) -> String {
        var out: [String] = []
        for b in l.blocks {
            out.append("B\(b.contentStart)-\(b.contentEnd)@\(Int(b.frame.minY)),\(Int(b.frame.minX)) \(b.attributed.string)")
        }
        for d in l.decorations {
            switch d {
            case let .text(s, p, _): out.append("T\(s)@\(Int(p.y)),\(Int(p.x))")
            case let .fill(r, _): out.append("F@\(Int(r.minY))")
            default: out.append("D")
            }
        }
        for c in l.checkboxes { out.append("C\(c.pos)@\(Int(c.rect.minY)) \(c.checked)") }
        out.append("H\(Int(l.height))")
        return out.joined(separator: "\n")
    }

    private func cold(_ doc: Node) -> DocumentLayout {
        DocumentLayout(doc: doc, width: width, theme: DocumentTheme())
    }

    private func item(_ s: Schema, kind: String, _ text: String, checked: Bool = false) -> Node {
        let p = try! s.node("paragraph", [:], content: Fragment.from([s.text(text)]))
        let attrs: Attrs = kind == "taskList" ? ["checked": .bool(checked)] : [:]
        return try! s.node(kind == "taskList" ? "taskItem" : "listItem", attrs, content: Fragment.from([p]))
    }

    private func doc(_ s: Schema, kind: String, _ items: [Node]) -> Node {
        try! s.node("doc", [:], content: Fragment.from([try! s.node(kind, [:], content: Fragment.from(items))]))
    }

    func testEditingOneItemReproducesAColdLayoutExactly() {
        let s = try! Editor(extensions: fullKit()).schema
        for kind in ["bulletList", "orderedList", "taskList"] {
            let cache = TextBlockLayoutCache()
            var items = (0 ..< 12).map { item(s, kind: kind, "Item \($0): \(words)", checked: $0 % 3 == 0) }
            var warm = DocumentLayout(doc: doc(s, kind: kind, items), width: width, theme: DocumentTheme(), blockCache: cache)
            XCTAssertEqual(fingerprint(warm), fingerprint(cold(doc(s, kind: kind, items))), "\(kind): first layout")

            // Each edit touches only the items it names — the rest keep their
            // nodes, as they do under a transaction, so the cache is *hit* for
            // them and its rebase is what is being checked. A keystroke in the
            // middle, then an item inserted at the top — which moves every item
            // down and, in an ordered list, renumbers every marker — then one
            // deleted, then an edit that changes an item's line count so
            // everything below it shifts by a line.
            let edits: [(inout [Node]) -> Void] = [
                { $0[5] = self.item(s, kind: kind, "Item 5 x: \(self.words)") },
                { $0.insert(self.item(s, kind: kind, "Item new: \(self.words)"), at: 0) },
                { $0.remove(at: 3) },
                { $0[2] = self.item(s, kind: kind, "Item 2: \(self.words) \(self.words) \(self.words)") },
                { $0[7] = self.item(s, kind: kind, "short", checked: true) },
            ]
            for (i, edit) in edits.enumerated() {
                edit(&items)
                let d = doc(s, kind: kind, items)
                warm = DocumentLayout(doc: d, width: width, theme: DocumentTheme(), blockCache: cache, previous: warm)
                XCTAssertGreaterThan(cache.debugItemCount, 0, "\(kind): items should be cached")
                XCTAssertEqual(fingerprint(warm), fingerprint(cold(d)), "\(kind): edit \(i)")
            }
        }
    }

    func testAToggledTaskItemIsNotServedTheUncheckedLayout() {
        // `checked` lives in the item's attrs, which are part of the key, so a
        // toggle must miss the cache: its content is typeset struck through.
        let s = try! Editor(extensions: fullKit()).schema
        let cache = TextBlockLayoutCache()
        func doc(_ checked: Bool) -> Node {
            let p = try! s.node("paragraph", [:], content: Fragment.from([s.text("todo")]))
            return try! s.node("doc", [:], content: Fragment.from([
                try! s.node("taskList", [:], content: Fragment.from([
                    try! s.node("taskItem", ["checked": .bool(checked)], content: Fragment.from([p]))]))]))
        }
        let before = DocumentLayout(doc: doc(false), width: width, theme: DocumentTheme(), blockCache: cache)
        let after = DocumentLayout(doc: doc(true), width: width, theme: DocumentTheme(),
                                   blockCache: cache, previous: before)
        XCTAssertEqual(fingerprint(after), fingerprint(cold(doc(true))))
        XCTAssertEqual(after.checkboxes.first?.checked, true)
    }

    func testAKeystrokeInALongListReusesEveryOtherItem() {
        // The property, counted rather than timed: after a keystroke in one
        // item, every other item is served from the cache. Two *different*
        // edits in a row, because laying out the same document twice lets the
        // top-level build reuse the whole list without touching a single item
        // — which is what an earlier draft of this test measured, at 0.04 ms.
        let s = try! Editor(extensions: fullKit()).schema
        let n = 1500
        var items = (0 ..< n).map { item(s, kind: "bulletList", "Item \($0): \(words)") }
        let cache = TextBlockLayoutCache()
        var layout = DocumentLayout(doc: doc(s, kind: "bulletList", items), width: width, theme: DocumentTheme(), blockCache: cache)
        XCTAssertEqual(cache.debugItemCount, n)

        var timings: [Double] = []
        for round in 0 ..< 4 {
            items[2] = item(s, kind: "bulletList", "Item 2 edit \(round): \(words)")
            let hitsBefore = cache.debugItemHits
            let t = CFAbsoluteTimeGetCurrent()
            layout = DocumentLayout(doc: doc(s, kind: "bulletList", items), width: width, theme: DocumentTheme(),
                                    blockCache: cache, previous: layout)
            timings.append((CFAbsoluteTimeGetCurrent() - t) * 1000)
            XCTAssertEqual(cache.debugItemHits - hitsBefore, n - 1,
                           "round \(round): every item but the edited one should be reused")
        }
        print(unsafe "LISTKEY \(n) items, keystroke in item 2, warm: \(String(format: "%.2f", timings.min()!))ms")
    }
}
#endif

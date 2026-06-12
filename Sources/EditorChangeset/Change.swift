import DocumentModel

// A port of prosemirror-changeset's change.ts: Span (a run of change metadata)
// and Change (a replaced range with deleted/inserted spans), including the
// parallel-walk merge of two change lists.
//
// `Data` is the per-span metadata (an author id, a step group, …). Combining
// uses a `(Data, Data) -> Data?` closure — nil means "not compatible, keep the
// spans separate" (upstream returns null).

/// Stores metadata for a part of a change.
public struct Span<Data> {
    /// The length of this span.
    public let length: Int
    /// The data associated with this span.
    public let data: Data

    public init(_ length: Int, _ data: Data) {
        self.length = length
        self.data = data
    }

    func cut(_ length: Int) -> Span<Data> {
        length == self.length ? self : Span(length, data)
    }

    static func slice(_ spans: [Span<Data>], _ from: Int, _ to: Int) -> [Span<Data>] {
        if from == to { return [] }
        if from == 0 && to == len(spans) { return spans }
        var result: [Span<Data>] = []
        var i = 0, off = 0
        while off < to {
            let span = spans[i]
            let end = off + span.length
            let overlap = min(to, end) - max(from, off)
            if overlap > 0 { result.append(span.cut(overlap)) }
            off = end
            i += 1
        }
        return result
    }

    static func join(_ a: [Span<Data>], _ b: [Span<Data>], _ combine: (Data, Data) -> Data?) -> [Span<Data>] {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        guard let combined = combine(a[a.count - 1].data, b[0].data) else { return a + b }
        var result = Array(a[0..<(a.count - 1)])
        result.append(Span(a[a.count - 1].length + b[0].length, combined))
        result.append(contentsOf: b[1...])
        return result
    }

    static func len(_ spans: [Span<Data>]) -> Int {
        spans.reduce(0) { $0 + $1.length }
    }
}

/// A replaced range with metadata associated with it.
public struct Change<Data> {
    /// The start of the range deleted/replaced in the old document.
    public let fromA: Int
    /// The end of the range in the old document.
    public let toA: Int
    /// The start of the range inserted in the new document.
    public let fromB: Int
    /// The end of the range in the new document.
    public let toB: Int
    /// Data for the deleted content; span lengths add up to `toA - fromA`.
    public let deleted: [Span<Data>]
    /// Data for the inserted content; span lengths add up to `toB - fromB`.
    public let inserted: [Span<Data>]

    public init(_ fromA: Int, _ toA: Int, _ fromB: Int, _ toB: Int,
                _ deleted: [Span<Data>], _ inserted: [Span<Data>]) {
        self.fromA = fromA
        self.toA = toA
        self.fromB = fromB
        self.toB = toB
        self.deleted = deleted
        self.inserted = inserted
    }

    var lenA: Int { toA - fromA }
    var lenB: Int { toB - fromB }

    func slice(_ startA: Int, _ endA: Int, _ startB: Int, _ endB: Int) -> Change<Data> {
        if startA == 0, startB == 0, endA == toA - fromA, endB == toB - fromB { return self }
        return Change(fromA + startA, fromA + endA, fromB + startB, fromB + endB,
                      Span.slice(deleted, startA, endA), Span.slice(inserted, startB, endB))
    }

    /// Merge two change lists (the end document of `x` is the start document
    /// of `y`) into one spanning the start of `x` to the end of `y`.
    public static func merge(_ x: [Change<Data>], _ y: [Change<Data>],
                             _ combine: (Data, Data) -> Data?) -> [Change<Data>] {
        if x.isEmpty { return y }
        if y.isEmpty { return x }

        var result: [Change<Data>] = []
        // Iterate over both sets in parallel, using the middle coordinate
        // system (B in x, A in y) to synchronize.
        var iX = 0, iY = 0
        var curX: Change<Data>? = x[0]
        var curY: Change<Data>? = y[0]
        func advanceX() {
            iX += 1
            curX = iX < x.count ? x[iX] : nil
        }
        func advanceY() {
            iY += 1
            curY = iY < y.count ? y[iY] : nil
        }
        while true {
            if curX == nil, curY == nil {
                return result
            } else if let cx = curX, curY == nil || cx.toB < curY!.fromA {
                // curX entirely in front of curY
                let off = iY > 0 ? y[iY - 1].toB - y[iY - 1].toA : 0
                result.append(off == 0 ? cx :
                    Change(cx.fromA, cx.toA, cx.fromB + off, cx.toB + off, cx.deleted, cx.inserted))
                advanceX()
            } else if let cy = curY, curX == nil || cy.toA < curX!.fromB {
                // curY entirely in front of curX
                let off = iX > 0 ? x[iX - 1].toB - x[iX - 1].toA : 0
                result.append(off == 0 ? cy :
                    Change(cy.fromA - off, cy.toA - off, cy.fromB, cy.toB, cy.deleted, cy.inserted))
                advanceY()
            } else {
                // Touching: deletions from the old set and insertions from the
                // new are kept. Middle-document area covered by x but not y is
                // insertion from x; covered by y but not x is deletion from y.
                var pos = min(curX!.fromB, curY!.fromA)
                let fromA = min(curX!.fromA, curY!.fromA - (iX > 0 ? x[iX - 1].toB - x[iX - 1].toA : 0))
                var toA = fromA
                let fromB = min(curY!.fromB, curX!.fromB + (iY > 0 ? y[iY - 1].toB - y[iY - 1].toA : 0))
                var toB = fromB
                var deleted: [Span<Data>] = []
                var inserted: [Span<Data>] = []
                // Prevents appending the ins/del range of the same Change twice.
                var enteredX = false, enteredY = false

                // Any number of further ranges might touch this group.
                while true {
                    let big = 200_000_000
                    let nextX = curX == nil ? big : (pos >= curX!.fromB ? curX!.toB : curX!.fromB)
                    let nextY = curY == nil ? big : (pos >= curY!.fromA ? curY!.toA : curY!.fromA)
                    let next = min(nextX, nextY)
                    let inX = curX != nil && pos >= curX!.fromB
                    let inY = curY != nil && pos >= curY!.fromA
                    if !inX && !inY { break }
                    if inX, pos == curX!.fromB, !enteredX {
                        deleted = Span.join(deleted, curX!.deleted, combine)
                        toA += curX!.lenA
                        enteredX = true
                    }
                    if inX, !inY {
                        inserted = Span.join(inserted, Span.slice(curX!.inserted, pos - curX!.fromB, next - curX!.fromB), combine)
                        toB += next - pos
                    }
                    if inY, pos == curY!.fromA, !enteredY {
                        inserted = Span.join(inserted, curY!.inserted, combine)
                        toB += curY!.lenB
                        enteredY = true
                    }
                    if inY, !inX {
                        deleted = Span.join(deleted, Span.slice(curY!.deleted, pos - curY!.fromA, next - curY!.fromA), combine)
                        toA += next - pos
                    }
                    if inX, next == curX!.toB {
                        advanceX()
                        enteredX = false
                    }
                    if inY, next == curY!.toA {
                        advanceY()
                        enteredY = false
                    }
                    pos = next
                }
                if fromA < toA || fromB < toB {
                    result.append(Change(fromA, toA, fromB, toB, deleted, inserted))
                }
            }
        }
    }
}

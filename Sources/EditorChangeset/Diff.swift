import DocumentModel

// A port of prosemirror-changeset's diff.ts: document tokenization and Myers'
// diff over token streams. Tokens are per document POSITION, which in this
// model means one token per Character (the JS original tokenizes per UTF-16
// unit; positions differ but the algorithm is identical).

/// A document token: a character (with the marks it carried at encode time
/// available to custom encoders), a node-open, or a node-close.
public enum ChangeToken: Equatable, Sendable {
    case char(Character)
    case open(String)
    case close(Int)
    /// For custom encoders that need their own token space.
    case custom(String)
}

/// Determines how document tokens are encoded and compared when diffing.
/// Both hooks may run a lot; keep them cheap.
public struct ChangesetTokenEncoder: Sendable {
    public let encodeCharacter: @Sendable (Character, [Mark]) -> ChangeToken
    public let encodeNodeStart: @Sendable (Node) -> ChangeToken
    public let encodeNodeEnd: @Sendable (Node) -> ChangeToken
    public let compareTokens: @Sendable (ChangeToken, ChangeToken) -> Bool

    public init(encodeCharacter: @escaping @Sendable (Character, [Mark]) -> ChangeToken,
                encodeNodeStart: @escaping @Sendable (Node) -> ChangeToken,
                encodeNodeEnd: @escaping @Sendable (Node) -> ChangeToken,
                compareTokens: @escaping @Sendable (ChangeToken, ChangeToken) -> Bool) {
        self.encodeCharacter = encodeCharacter
        self.encodeNodeStart = encodeNodeStart
        self.encodeNodeEnd = encodeNodeEnd
        self.compareTokens = compareTokens
    }

    /// The default encoder: characters compare by character, node opens by
    /// name, closes by schema order — marks and attributes are ignored.
    public static let `default` = ChangesetTokenEncoder(
        encodeCharacter: { ch, _ in .char(ch) },
        encodeNodeStart: { node in .open(node.type.name) },
        encodeNodeEnd: { node in .close(-(node.type.schemaOrder + 1)) },
        compareTokens: { $0 == $1 })
}

/// Convert the given range of a fragment to tokens.
private func tokens(_ frag: Fragment, _ encoder: ChangesetTokenEncoder,
                    _ start: Int, _ end: Int, _ target: inout [ChangeToken]) {
    var off = 0
    for i in 0..<frag.childCount {
        let child = frag.child(i)
        let endOff = off + child.nodeSize
        let from = max(off, start), to = min(endOff, end)
        if from < to {
            if child.isText {
                let chars = Array(child.text ?? "")
                for j in from..<to { target.append(encoder.encodeCharacter(chars[j - off], child.marks)) }
            } else if child.isLeaf {
                target.append(encoder.encodeNodeStart(child))
            } else {
                if from == off { target.append(encoder.encodeNodeStart(child)) }
                tokens(child.content, encoder, max(off + 1, from) - off - 1, min(endOff - 1, to) - off - 1, &target)
                if to == endOff { target.append(encoder.encodeNodeEnd(child)) }
            }
        }
        off = endOff
    }
}

/// Refuse to compute diffs bigger than this (a runaway-computation guard).
private let maxDiffSize = 5000

/// The minimum length of an unchanged range not at the start/end of the
/// compared content: higher for bigger replacements, so a paragraph rewrite
/// doesn't become a soup of coincidentally identical letters.
private func minUnchanged(_ sizeA: Int, _ sizeB: Int) -> Int {
    min(15, max(2, max(sizeA, sizeB) / 10))
}

public func computeDiff<Data>(_ fragA: Fragment, _ fragB: Fragment, _ range: Change<Data>,
                              _ encoder: ChangesetTokenEncoder = .default) -> [Change<Data>] {
    var tokA: [ChangeToken] = []
    tokens(fragA, encoder, range.fromA, range.toA, &tokA)
    var tokB: [ChangeToken] = []
    tokens(fragB, encoder, range.fromB, range.toB, &tokB)

    // Scan from both sides to cheaply eliminate work.
    let cmp = encoder.compareTokens
    var start = 0
    var endA = tokA.count, endB = tokB.count
    while start < tokA.count, start < tokB.count, cmp(tokA[start], tokB[start]) { start += 1 }
    if start == tokA.count, start == tokB.count { return [] }
    while endA > start, endB > start, cmp(tokA[endA - 1], tokB[endB - 1]) {
        endA -= 1
        endB -= 1
    }
    // Simple, or too big to cheaply compute: the remaining region is the diff.
    if endA == start || endB == start || (endA == endB && endA == start + 1) {
        return [range.slice(start, endA, start, endB)]
    }

    // Myers' diff (https://neil.fraser.name/writing/diff/myers.pdf).
    let lenA = endA - start, lenB = endB - start
    let maxSize = min(maxDiffSize, lenA + lenB)
    let off = maxSize + 1
    var history: [[Int]] = []
    var frontier = [Int](repeating: -1, count: off * 2)

    // JS reads frontier[-1] as undefined at the lower diagonal edge, making
    // `next < prev` false; Int.min reproduces that comparison behavior.
    func at(_ arr: [Int], _ i: Int) -> Int { i >= 0 ? arr[i] : Int.min }

    var size = 0
    while size <= maxSize {
        var diag = -size
        while diag <= size {
            let next = at(frontier, diag + 1 + maxSize), prev = at(frontier, diag - 1 + maxSize)
            var x = next < prev ? prev : next + 1
            var y = x + diag
            while x < lenA, y < lenB, cmp(tokA[start + x], tokB[start + y]) {
                x += 1
                y += 1
            }
            frontier[diag + maxSize] = x
            if x >= lenA, y >= lenB {
                // Trace back through the history to build the changed ranges,
                // back to front, merging ones less than minSpan apart.
                var diff: [Change<Data>] = []
                let minSpan = minUnchanged(endA - start, endB - start)
                var fromA = -1, toA = -1, fromB = -1, toB = -1
                var curDiag = diag
                func add(_ fA: Int, _ tA: Int, _ fB: Int, _ tB: Int) {
                    if fromA > -1, fromA < tA + minSpan {
                        fromA = fA
                        fromB = fB
                    } else {
                        if fromA > -1 { diff.append(range.slice(fromA, toA, fromB, toB)) }
                        fromA = fA; toA = tA
                        fromB = fB; toB = tB
                    }
                }
                var i = size - 1
                while i >= 0 {
                    let next = at(frontier, curDiag + 1 + maxSize), prev = at(frontier, curDiag - 1 + maxSize)
                    if next < prev { // deletion
                        curDiag -= 1
                        let x2 = prev + start
                        let y2 = x2 + curDiag
                        add(x2, x2, y2, y2 + 1)
                    } else { // insertion
                        curDiag += 1
                        let x2 = next + start
                        let y2 = x2 + curDiag
                        add(x2, x2 + 1, y2, y2)
                    }
                    frontier = history[i >> 1]
                    i -= 1
                }
                if fromA > -1 { diff.append(range.slice(fromA, toA, fromB, toB)) }
                return diff.reversed()
            }
            diag += 2
        }
        // Only either odd or even diagonals are read from each frontier, so
        // copy them every other iteration.
        if size % 2 == 0 { history.append(frontier) }
        size += 1
    }
    // Maximum work done; return a change spanning the entire range.
    return [range.slice(start, endA, start, endB)]
}

import DocumentModel

// A port of prosemirror-changeset's simplify.ts: presentation-level cleanup of
// change lists — replacements inside a word expand to cover the whole word,
// and nearby changes merge (single-character replacements excepted).

/// Faithful to upstream's `isLetter`, including its quirky ASCII range
/// (79...122 counts `O…z` plus `[\]^_`` as word characters).
private func isLetterChar(_ ch: Character?) -> Bool {
    guard let ch, let scalar = ch.unicodeScalars.first else { return false }
    let code = scalar.value
    if code < 128 {
        return (code >= 48 && code <= 57) || (code >= 65 && code <= 90) || (code >= 79 && code <= 122)
    }
    return ch.isLetter || ch.isNumber
}

/// One character per document position in [start, end): text characters, with
/// non-text tokens as spaces so they don't count as word parts.
private func getText(_ frag: Fragment, _ start: Int, _ end: Int) -> [Character] {
    var out: [Character] = []
    func convert(_ frag: Fragment, _ start: Int, _ end: Int) {
        var off = 0
        for i in 0..<frag.childCount {
            let child = frag.child(i)
            let endOff = off + child.nodeSize
            let from = max(off, start), to = min(endOff, end)
            if from < to {
                if child.isText {
                    let chars = Array(child.text ?? "")
                    out.append(contentsOf: chars[max(0, start - off)..<min(chars.count, end - off)])
                } else if child.isLeaf {
                    out.append(" ")
                } else {
                    if from == off { out.append(" ") }
                    convert(child.content, max(0, from - off - 1), min(child.content.size, end - off))
                    if to == endOff { out.append(" ") }
                }
            }
            off = endOff
        }
    }
    convert(frag, start, end)
    return out
}

/// Changes this close together (in positions) are candidates for merging.
private let maxSimplifyDistance = 30

/// Simplify a set of changes for presentation: when both insertions and
/// deletions occur inside one word, expand the change to cover the whole
/// word(s) in the new document. Single-character replacements are kept.
public func simplifyChanges<Data: Equatable>(_ changes: [Change<Data>], _ doc: Node) -> [Change<Data>] {
    var result: [Change<Data>] = []
    var i = 0
    while i < changes.count {
        var end = changes[i].toB
        let start = i
        while i < changes.count - 1, changes[i + 1].fromB <= end + maxSimplifyDistance {
            i += 1
            end = changes[i].toB
        }
        simplifyAdjacentChanges(changes, start, i + 1, doc, &result)
        i += 1
    }
    return result
}

private func simplifyAdjacentChanges<Data: Equatable>(_ changes: [Change<Data>], _ from: Int, _ to: Int,
                                           _ doc: Node, _ target: inout [Change<Data>]) {
    let start = max(0, changes[from].fromB - maxSimplifyDistance)
    let end = min(doc.content.size, changes[to - 1].toB + maxSimplifyDistance)
    let text = getText(doc.content, start, end)
    func charAt(_ pos: Int) -> Character? {
        let idx = pos - start
        return idx >= 0 && idx < text.count ? text[idx] : nil
    }

    var i = from
    while i < to {
        let startI = i
        var last = changes[i]
        var deleted = last.lenA, inserted = last.lenB
        while i < to - 1 {
            let next = changes[i + 1]
            var boundary = false
            var prevLetter = last.toB == end ? false : isLetterChar(charAt(last.toB - 1))
            var pos = last.toB
            while !boundary, pos < next.fromB {
                let nextLetter = pos == end ? false : isLetterChar(charAt(pos))
                if (!prevLetter || !nextLetter), pos != changes[startI].fromB { boundary = true }
                prevLetter = nextLetter
                pos += 1
            }
            if boundary { break }
            deleted += next.lenA
            inserted += next.lenB
            last = next
            i += 1
        }

        if inserted > 0, deleted > 0, !(inserted == 1 && deleted == 1) {
            var fromB = changes[startI].fromB
            var toB = changes[i].toB
            if fromB < end, isLetterChar(charAt(fromB)) {
                while fromB > start, isLetterChar(charAt(fromB - 1)) { fromB -= 1 }
            }
            if toB > start, isLetterChar(charAt(toB - 1)) {
                while toB < end, isLetterChar(charAt(toB)) { toB += 1 }
            }
            let joined = fillChange(Array(changes[startI...i]), fromB, toB)
            if let last = target.last, last.toA == joined.fromA {
                target[target.count - 1] = Change(last.fromA, joined.toA, last.fromB, joined.toB,
                                                  last.deleted + joined.deleted, last.inserted + joined.inserted)
            } else {
                target.append(joined)
            }
        } else {
            for j in startI...i { target.append(changes[j]) }
        }
        i += 1
    }
}

private func fillChange<Data: Equatable>(_ changes: [Change<Data>], _ fromB: Int, _ toB: Int) -> Change<Data> {
    // Upstream's combine: identical adjacent data merges into one span.
    let combine: (Data, Data) -> Data? = { a, b in a == b ? a : nil }
    let fromA = changes[0].fromA - (changes[0].fromB - fromB)
    let last = changes[changes.count - 1]
    let toA = last.toA + (toB - last.toB)
    var deleted: [Span<Data>] = []
    var inserted: [Span<Data>] = []
    var delData = (changes[0].deleted.isEmpty ? changes[0].inserted : changes[0].deleted)[0].data
    var insData = (changes[0].inserted.isEmpty ? changes[0].deleted : changes[0].inserted)[0].data
    var posA = fromA, posB = fromB
    var i = 0
    while true {
        let next = i == changes.count ? nil : changes[i]
        let endA = next?.fromA ?? toA
        let endB = next?.fromB ?? toB
        if endA > posA { deleted = Span.join(deleted, [Span(endA - posA, delData)], combine) }
        if endB > posB { inserted = Span.join(inserted, [Span(endB - posB, insData)], combine) }
        guard let next else { break }
        deleted = Span.join(deleted, next.deleted, combine)
        inserted = Span.join(inserted, next.inserted, combine)
        if let lastDel = deleted.last { delData = lastDel.data }
        if let lastIns = inserted.last { insData = lastIns.data }
        posA = next.toA
        posB = next.toB
        i += 1
    }
    return Change(fromA, toA, fromB, toB, deleted, inserted)
}

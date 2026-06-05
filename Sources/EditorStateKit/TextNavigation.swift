import DocumentModel

/// The direction of a cursor move or deletion.
public enum TextDirection: Sendable {
    case backward
    case forward
    /// `-1` for backward, `+1` for forward.
    public var sign: Int { self == .backward ? -1 : 1 }
}

/// How far a single cursor move or deletion travels.
public enum TextGranularity: Sendable {
    case character
    case word
    /// To the start/end of the enclosing textblock.
    case lineBoundary
}

/// Pure, model-based cursor navigation. Given a document and a position, it
/// computes the destination of a move — no view geometry involved, so visual
/// line moves (up/down) stay in the view layer while character/word/line-edge
/// moves are computed (and tested) here.
public enum TextNavigation {
    /// The destination position when moving from `pos` in `direction` by
    /// `granularity`. Always returns a valid in-range position.
    public static func position(in doc: Node, from pos: Int, moving direction: TextDirection, by granularity: TextGranularity) -> Int {
        let clamped = max(0, min(doc.content.size, pos))
        switch granularity {
        case .character: return characterPosition(in: doc, from: clamped, direction: direction)
        case .word: return wordPosition(in: doc, from: clamped, direction: direction)
        case .lineBoundary: return lineBoundaryPosition(in: doc, from: clamped, direction: direction)
        }
    }

    // MARK: - Character

    private static func characterPosition(in doc: Node, from pos: Int, direction: TextDirection) -> Int {
        let target = max(0, min(doc.content.size, pos + direction.sign))
        if target == pos { return pos }
        // Snap to the nearest valid caret, skipping block-boundary tokens so a
        // single press moves from the end of one block to the start of the next.
        return Selection.near(doc.resolve(target), direction.sign).head
    }

    // MARK: - Word

    private static func wordPosition(in doc: Node, from pos: Int, direction: TextDirection) -> Int {
        let resolved = doc.resolve(pos)
        guard resolved.parent.isTextblock else {
            return characterPosition(in: doc, from: pos, direction: direction)
        }
        let start = resolved.start()
        let chars = inlineCharacters(of: resolved.parent)
        let offset = pos - start
        let isWord: (Character) -> Bool = { $0.isLetter || $0.isNumber || $0 == "_" }

        if direction == .forward {
            var i = min(max(offset, 0), chars.count)
            while i < chars.count && !isWord(chars[i]) { i += 1 }
            while i < chars.count && isWord(chars[i]) { i += 1 }
            // At the block edge: cross into the next block by a character move.
            return i == offset ? characterPosition(in: doc, from: pos, direction: direction) : start + i
        } else {
            var i = min(max(offset, 0), chars.count)
            while i > 0 && !isWord(chars[i - 1]) { i -= 1 }
            while i > 0 && isWord(chars[i - 1]) { i -= 1 }
            return i == offset ? characterPosition(in: doc, from: pos, direction: direction) : start + i
        }
    }

    // MARK: - Line (textblock) boundary

    private static func lineBoundaryPosition(in doc: Node, from pos: Int, direction: TextDirection) -> Int {
        let resolved = doc.resolve(pos)
        guard resolved.parent.isTextblock else { return pos }
        return direction == .backward ? resolved.start() : resolved.end()
    }

    /// The inline characters of a textblock, one entry per document position
    /// (inline atoms contribute a single non-word placeholder).
    public static func inlineCharacters(of parent: Node) -> [Character] {
        var chars: [Character] = []
        for i in 0..<parent.childCount {
            let child = parent.child(i)
            if child.isText {
                chars.append(contentsOf: Array(child.text ?? ""))
            } else {
                chars.append("\u{fffc}")
            }
        }
        return chars
    }
}

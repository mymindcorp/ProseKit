import DocumentModel

/// Pure full-text search over a document, returning match ranges as document
/// positions. Searches within each textblock (matches don't span blocks).
public enum TextSearch {
    public struct Match: Equatable, Sendable {
        public let from: Int
        public let to: Int
        public init(from: Int, to: Int) { self.from = from; self.to = to }
    }

    public static func matches(in doc: Node, query: String, caseSensitive: Bool = false) -> [Match] {
        guard !query.isEmpty else { return [] }
        var result: [Match] = []
        doc.descendants { node, pos, _, _ in
            guard node.isTextblock else { return true }
            let contentStart = pos + 1
            let chars = TextNavigation.inlineCharacters(of: node)
            for range in occurrences(of: query, in: chars, caseSensitive: caseSensitive) {
                result.append(Match(from: contentStart + range.lowerBound, to: contentStart + range.upperBound))
            }
            return false // already scanned this block's inline content
        }
        return result
    }

    private static func occurrences(of query: String, in haystack: [Character], caseSensitive: Bool) -> [Range<Int>] {
        let needle = Array(caseSensitive ? query : query.lowercased())
        let hay = caseSensitive ? haystack : haystack.map { Character($0.lowercased()) }
        guard !needle.isEmpty, hay.count >= needle.count else { return [] }
        var result: [Range<Int>] = []
        var i = 0
        while i <= hay.count - needle.count {
            if Array(hay[i..<(i + needle.count)]) == needle {
                result.append(i..<(i + needle.count))
                i += needle.count
            } else {
                i += 1
            }
        }
        return result
    }
}

#if canImport(UIKit)
import UIKit
import NaturalLanguage
import DocumentModel
import EditorStateKit

/// Produces spelling-error decorations for a document using `UITextChecker`.
/// Lives in the renderer because `UITextChecker` is a UIKit facility; the
/// decorations it returns are drawn as dotted red underlines.
///
/// Each textblock is checked in the language it is written in, not a fixed
/// one: a paragraph of Spanish checked as English underlines nearly every
/// word. `languages(for:)` picks the dictionaries, and a word is flagged only
/// when all of them reject it — so an English word quoted in a Spanish note
/// isn't flagged either.
enum SpellCheck {
    /// One checker for every pass. Constructing one isn't free, and a
    /// keystroke shouldn't pay for it.
    @MainActor private static let checker = UITextChecker()

    /// Spelling decorations for the textblocks overlapping `range` (or the whole
    /// document when nil). Bounding to the visible range keeps the cost
    /// independent of document size. `@MainActor` because `UITextChecker` is
    /// main-actor isolated — callers debounce + bound the range so the pass is
    /// cheap enough to run on the main actor.
    /// `languages` overrides detection with a fixed set of checker languages.
    @MainActor
    static func decorations(for doc: Node, in range: ClosedRange<Int>? = nil, languages: [String]? = nil) -> [Decoration] {
        var result: [Decoration] = []
        let from = max(range?.lowerBound ?? 0, 0)
        let to = min(range?.upperBound ?? doc.content.size, doc.content.size)
        // `nodesBetween` skips the blocks before `from` and stops at `to`;
        // walking every descendant to find the few in range made a bounded
        // pass cost the whole document anyway.
        doc.nodesBetween(from, to) { node, pos, _, _ in
            guard node.isTextblock else { return true }
            if node.type.spec.code { return false } // don't spell-check code
            let chars = TextNavigation.inlineCharacters(of: node)
            let langs = languages ?? Self.languages(for: chars[...])
            result.append(contentsOf: check(chars[...], at: pos + 1, languages: langs))
            return false
        }
        return result
    }

    /// Re-check only the words an edit touched.
    ///
    /// `focus` is the edited range, in current-document positions. Within each
    /// textblock it reaches, the span checked is widened to whole words — from
    /// the start of the word the edit began in (or ended just after) to the end
    /// of the word it finished in — so a keystroke costs the word under the
    /// caret, not the paragraph around it. Returns the spans actually checked
    /// so the caller can splice the result into a cache and keep the rest.
    ///
    /// A space typed into the middle of a word, or a backspace joining two,
    /// changes the words on both sides of the edit; widening from the character
    /// before the edit to the one after it covers both.
    @MainActor
    static func recheck(_ doc: Node, around focus: ClosedRange<Int>, languages: [String]? = nil) -> (checked: [ClosedRange<Int>], decorations: [Decoration]) {
        var checked: [ClosedRange<Int>] = []
        var decorations: [Decoration] = []
        let from = max(focus.lowerBound, 0)
        let to = min(focus.upperBound, doc.content.size)
        doc.nodesBetween(from, to) { node, pos, _, _ in
            guard node.isTextblock else { return true }
            if node.type.spec.code { return false }
            let contentStart = pos + 1
            let chars = TextNavigation.inlineCharacters(of: node)
            var a = min(max(from - contentStart, 0), chars.count)
            var b = min(max(to - contentStart, 0), chars.count)
            while a > 0, !isWordBoundary(chars[a - 1]) { a -= 1 }
            while b < chars.count, !isWordBoundary(chars[b]) { b += 1 }
            guard a < b else { return false } // the edit touched only whitespace
            checked.append(contentStart + a ... contentStart + b)
            // The language comes from the whole block: the few words around
            // an edit are too little text to tell one language from another.
            // All of it *except* the words being checked, though. Those are
            // the part a keystroke changes — leave them in and every keystroke
            // is a new text to recognize, which was nearly all of what a
            // keystroke spent here — and a half-typed word says nothing about
            // the language yet. Without them the text is the same from one
            // keystroke to the next, so `languages(for:)` answers from its
            // cache until a word is finished.
            let langs = languages ?? Self.languages(for: Self.context(chars, excluding: a ..< b))
            decorations.append(contentsOf: check(chars[a ..< b], at: contentStart + a, languages: langs))
            return false
        }
        return (checked, decorations)
    }

    /// Suggested corrections for a misspelled `word`, best first, from the
    /// first of `languages` that rejects it. `languages` defaults to what
    /// `context` — the text around the word — is written in.
    @MainActor
    static func guesses(for word: String, context: String? = nil, languages: [String]? = nil) -> [String] {
        let range = NSRange(location: 0, length: (word as NSString).length)
        let langs = languages ?? Self.languages(for: Array(context ?? word)[...])
        for lang in langs where isMisspelled(word, range, language: lang) {
            if let guesses = checker.guesses(forWordRange: range, in: word, language: lang), !guesses.isEmpty {
                return guesses
            }
        }
        return []
    }

    // MARK: - Choosing a language

    @MainActor private static let recognizer = NLLanguageRecognizer()

    /// What `UITextChecker` can check, e.g. `en_US`, `es`, `pt_BR`.
    @MainActor private static let available = UITextChecker.availableLanguages

    /// How sure the recognizer has to be before its guess is trusted over the
    /// user's own languages.
    static let detectionConfidence = 0.5

    /// The fewest words a block needs before its language is recognized at
    /// all. A word or two is too little to tell languages apart — "mispeled
    /// word" comes back confidently Dutch — and is most likely in a language
    /// the user writes.
    static let detectionMinimumWords = 3

    /// The checker languages to check `chars` in, best first: the language
    /// the text is written in, then the user's preferred languages. Empty when
    /// the text is confidently in a language the checker has no dictionary
    /// for — better nothing underlined than every word.
    @MainActor
    static func languages(for chars: ArraySlice<Character>) -> [String] {
        var result: [String] = []
        // The opening of a long block says what it's written in as well as
        // the whole of it, at a fraction of the cost on every keystroke.
        let sample = String(chars.prefix(sampleLength))
        switch detection(for: sample) {
        case .unchecked: return []
        case let .checker(lang): result.append(lang)
        case .undetermined: break
        }
        for lang in preferredLanguages where !result.contains(lang) {
            result.append(lang)
        }
        return result
    }

    /// How much of a block its language is recognized from.
    static let sampleLength = 1_000

    /// What recognizing a sample came to.
    private enum Detection {
        /// Too little text, or no language confidently enough: check in the
        /// user's own languages.
        case undetermined
        /// Written in a language the checker has a dictionary for.
        case checker(String)
        /// Confidently written in a language the checker can't check.
        case unchecked
    }

    /// Recognitions already made, by the exact sample. The recognizer answers
    /// the same text the same way, so a hit changes nothing but the cost —
    /// 0.3 ms for a short paragraph, over a millisecond for a long one, against
    /// a few microseconds for checking the word that was typed. Only the
    /// recognition is kept: the preferred languages are read fresh each time,
    /// since the user can change them while the app runs.
    @MainActor private static var detections: [String: Detection] = [:]
    private static let detectionCacheLimit = 128
    /// Test hook: how many samples were actually run through the recognizer,
    /// so a test can say a keystroke was answered from the cache rather than
    /// infer it from a timing.
    @MainActor private(set) static var debugRecognitions = 0

    @MainActor
    private static func detection(for sample: String) -> Detection {
        if let known = detections[sample] { return known }
        var result = Detection.undetermined
        let words = sample.split { $0.isWhitespace || $0 == "\u{fffc}" }.count
        // Unspaced scripts (Japanese, Chinese, Thai) have no words to count;
        // a run of letters long enough to be a sentence is enough there.
        if words >= detectionMinimumWords || sample.count >= 12 * detectionMinimumWords {
            debugRecognitions += 1
            recognizer.reset()
            recognizer.processString(sample)
            if let (detected, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
               confidence >= detectionConfidence {
                result = checkerLanguage(for: detected.rawValue).map(Detection.checker) ?? .unchecked
            }
        }
        // Wholesale rather than least-recently-used: a full cache means the
        // reader has moved on through the document, and what it held is cold.
        if detections.count >= detectionCacheLimit { detections.removeAll(keepingCapacity: true) }
        detections[sample] = result
        return result
    }

    /// The opening of a block's text with `excluded` cut out — as much as
    /// `languages(for:)` reads, built without copying any more of a long block
    /// than that.
    private static func context(_ chars: [Character], excluding excluded: Range<Int>) -> ArraySlice<Character> {
        if excluded.lowerBound >= sampleLength { return chars.prefix(sampleLength) }
        let after = chars[excluded.upperBound...].prefix(sampleLength - excluded.lowerBound)
        return (chars[..<excluded.lowerBound] + after)[...]
    }


    /// The user's preferred languages that the checker supports, falling back
    /// to English when none of them is.
    @MainActor
    static var preferredLanguages: [String] {
        let langs = Locale.preferredLanguages.prefix(3).compactMap(checkerLanguage(for:))
        var unique: [String] = []
        for lang in langs where !unique.contains(lang) { unique.append(lang) }
        return unique.isEmpty ? [checkerLanguage(for: "en") ?? "en"] : unique
    }

    /// The checker language for a BCP 47 tag (`es`, `pt-BR`, `zh-Hans`): an
    /// exact match, else any regional variant of the same language.
    @MainActor
    static func checkerLanguage(for tag: String) -> String? {
        let normalized = tag.replacingOccurrences(of: "-", with: "_")
        if available.contains(normalized) { return normalized }
        let base = String(normalized.prefix { $0 != "_" })
        if available.contains(base) { return base }
        return available.first { $0.hasPrefix(base + "_") }
    }

    /// Whitespace, or the placeholder `inlineCharacters` uses for an inline
    /// atom (an image, a mention): either ends a word.
    private static func isWordBoundary(_ c: Character) -> Bool {
        c.isWhitespace || c == "\u{fffc}"
    }

    /// Run the checker over `chars`, which begin at document position `base`.
    /// A word is flagged only when every one of `languages` rejects it.
    @MainActor
    private static func check(_ chars: ArraySlice<Character>, at base: Int, languages: [String]) -> [Decoration] {
        guard let primary = languages.first else { return [] }
        let text = String(chars)
        let ns = text as NSString
        var result: [Decoration] = []
        // The checker reports UTF-16 offsets; document positions count
        // characters. Its results come back in order, so one cursor over
        // `chars` converts them all in a single pass.
        var index = chars.startIndex
        var utf16Offset = 0
        func position(atUTF16 target: Int) -> Int {
            while utf16Offset < target, index < chars.endIndex {
                utf16Offset += chars[index].utf16.count
                index += 1
            }
            return base + (index - chars.startIndex)
        }
        var offset = 0
        while offset < ns.length {
            let range = checker.rangeOfMisspelledWord(
                in: text,
                range: NSRange(location: offset, length: ns.length - offset),
                startingAt: offset, wrap: false, language: primary)
            if range.location == NSNotFound { break }
            offset = range.location + range.length
            if languages.dropFirst().contains(where: { !isMisspelled(text, range, language: $0) }) { continue }
            let from = position(atUTF16: range.location)
            let to = position(atUTF16: range.location + range.length)
            result.append(.inline(from, to, ["spelling": "1"]))
        }
        return result
    }

    /// Whether the word at `range` of `text` is misspelled in `language`.
    @MainActor
    private static func isMisspelled(_ text: String, _ range: NSRange, language: String) -> Bool {
        checker.rangeOfMisspelledWord(
            in: text, range: range, startingAt: range.location, wrap: false, language: language
        ).location != NSNotFound
    }
}
#endif

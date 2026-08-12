#if canImport(UIKit)
import UIKit
import CoreFoundation
import DocumentModel
import SchemaKit

/// A `UITextInputTokenizer` that answers word questions without rebuilding a
/// tokenizer for each one.
///
/// UIKit's `UITextInputStringTokenizer` is the default when a text input does
/// not supply its own. It answers by asking the input for text and creating a
/// CoreNLP/ICU word tokenizer from scratch every call. That lands on the scroll
/// path — UIKit re-queries the whole RTI document state on every
/// `selectionDidChange`, and we must send one per tick so the system's
/// selection and caret track the content — where it profiled at 238 samples of
/// a single scroll, all of it tokenizer construction rather than tokenizing.
///
/// Two things make this cheap:
///
/// - The ICU tokenizer is created once and re-pointed at each new string, which
///   is the entire saving. `CFStringTokenizerCreate` loads rule data; `…SetString`
///   does not.
/// - It reads a window around the position rather than the document. A
///   document-sized selection made the old path hand UIKit its whole text.
///
/// Everything that is not `.word` is delegated to a single retained
/// `UITextInputStringTokenizer`, so those answers are identical by construction
/// rather than by agreement — sentence, line and paragraph questions are not on
/// the hot path and are not worth the risk of reimplementing. `TokenizerParityTests`
/// holds the word answers to the system tokenizer's, position by position.
final class DocumentTokenizer: NSObject, UITextInputTokenizer {
    private weak var textInput: EditorTextView?

    /// Created once. The point of this class is that this object survives.
    private lazy var icu: CFStringTokenizer? = {
        // `…UnitWord`, not `…UnitWordBoundary`: the latter emits a token for
        // every boundary-delimited run, whitespace and punctuation included, so
        // the gap character standing for a paragraph break reads as a word.
        CFStringTokenizerCreate(kCFAllocatorDefault, "" as CFString,
                                CFRange(location: 0, length: 0),
                                kCFStringTokenizerUnitWord,
                                CFLocaleCopyCurrent())
    }()

    /// For every granularity but `.word`.
    private lazy var fallback: (any UITextInputTokenizer)? = {
        guard let textInput else { return nil }
        return UITextInputStringTokenizer(textInput: textInput)
    }()

    init(textInput: EditorTextView) {
        self.textInput = textInput
        super.init()
    }

    // MARK: The window

    /// How much text either side of the position to consider. A word longer
    /// than this would be clipped by the window; at this size that means a
    /// single unbroken run of 512 characters, and the answer degrades to the
    /// window edge rather than becoming wrong elsewhere.
    private static let margin = 512

    /// The projected text around `pos`, with the document position its first
    /// character sits at. `projectedText` is one character per document
    /// position, so within the window an index is just `pos - start` — but only
    /// in *characters*, which is not the same as UTF-16 once emoji appear, so
    /// `WordScan` carries the conversion.
    private struct Window {
        let chars: [Character]
        let start: Int
        /// UTF-16 offset of each character index, plus the total at the end.
        let utf16Offsets: [Int]

        init(text: String, start: Int) {
            chars = Array(text)
            self.start = start
            var offsets = [Int](repeating: 0, count: chars.count + 1)
            var running = 0
            for (i, c) in chars.enumerated() {
                offsets[i] = running
                running += String(c).utf16.count
            }
            offsets[chars.count] = running
            utf16Offsets = offsets
        }

        /// Character index → UTF-16 offset.
        func utf16(forCharacter index: Int) -> Int {
            utf16Offsets[min(max(index, 0), chars.count)]
        }

        /// UTF-16 offset → character index, rounding down to the character that
        /// contains it (a UTF-16 offset can land inside a surrogate pair).
        func character(forUTF16 offset: Int) -> Int {
            var lo = 0, hi = chars.count
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if utf16Offsets[mid] <= offset { lo = mid } else { hi = mid - 1 }
            }
            return lo
        }
    }

    /// How far inside the window a position must sit for the cached words to
    /// be trustworthy: a word touching the edge may have been cut in half by
    /// it, so answers within this much of either end are recomputed against a
    /// window centred on the position instead.
    private static let guardBand = 64

    /// The last tokenized window. Rebuilding one costs a scan of `margin`
    /// characters either side, which dwarfs the tokenizer construction it was
    /// meant to save — the first version of this class was ten times slower
    /// than the system tokenizer for exactly that reason. UIKit probes
    /// clustered positions, so one tokenization serves a run of them.
    private var cached: (revision: Int, start: Int, end: Int, words: Words)?

    /// A tokenized window, with everything the four protocol methods need
    /// precomputed. Deriving these per call — flattening the ranges to edges
    /// and sorting them — cost more than the tokenizing did.
    private struct Words {
        /// In document positions, ascending and disjoint.
        let ranges: [Range<Int>]
        /// Every start and end, ascending.
        let edges: [Int]

        init(_ ranges: [Range<Int>]) {
            self.ranges = ranges
            var e = [Int]()
            e.reserveCapacity(ranges.count * 2)
            for r in ranges { e.append(r.lowerBound); e.append(r.upperBound) }
            edges = e   // already ascending: the ranges are
        }

        /// The word containing `pos`, treating a range as `[lower, upper)`.
        func index(containing pos: Int) -> Int? {
            var lo = 0, hi = ranges.count - 1
            while lo <= hi {
                let mid = (lo + hi) / 2
                if pos < ranges[mid].lowerBound { hi = mid - 1 }
                else if pos >= ranges[mid].upperBound { lo = mid + 1 }
                else { return mid }
            }
            return nil
        }

        /// The word `pos` sits in, facing `ahead`. Facing backward a position
        /// at a word's end is inside it and one at its start is not, which is
        /// the same as asking where `pos - 1` sits.
        func word(at pos: Int, ahead: Bool) -> Range<Int>? {
            index(containing: ahead ? pos : pos - 1).map { ranges[$0] }
        }

        func edge(after pos: Int) -> Int? {
            var lo = 0, hi = edges.count
            while lo < hi { let mid = (lo + hi) / 2; if edges[mid] <= pos { lo = mid + 1 } else { hi = mid } }
            return lo < edges.count ? edges[lo] : nil
        }

        func edge(before pos: Int) -> Int? {
            var lo = 0, hi = edges.count
            while lo < hi { let mid = (lo + hi) / 2; if edges[mid] < pos { lo = mid + 1 } else { hi = mid } }
            return lo > 0 ? edges[lo - 1] : nil
        }
    }

    /// Word ranges valid around `pos`, in document positions.
    private func words(around pos: Int) -> Words {
        guard let v = textInput else { return Words([]) }
        let size = v.editor.doc.content.size
        let revision = v.editor.docRevision
        if let c = cached, c.revision == revision,
           pos >= c.start + Self.guardBand || c.start == 0,
           pos <= c.end - Self.guardBand || c.end == size {
            return c.words
        }
        let lo = max(0, pos - Self.margin), hi = min(size, pos + Self.margin)
        guard hi > lo else {
            cached = nil
            return Words([])
        }
        let w = Window(text: v.projectedText(from: lo, to: hi), start: lo)
        let found = Words(tokenize(w))
        cached = (revision, lo, hi, found)
        return found
    }

    /// The word ranges of a window, in document positions.
    private func tokenize(_ w: Window) -> [Range<Int>] {
        guard let icu else { return [] }
        let text = String(w.chars) as CFString
        let length = CFStringGetLength(text)
        guard length > 0 else { return [] }
        CFStringTokenizerSetString(icu, text, CFRange(location: 0, length: length))
        var result: [Range<Int>] = []
        // `SetString` leaves the tokenizer before the first token, so advance
        // to find it. Seeking to index 0 instead finds nothing whenever the
        // window opens on a non-word — a gap character, or a leading space.
        var type = CFStringTokenizerAdvanceToNextToken(icu)
        while type != [] {
            let r = CFStringTokenizerGetCurrentTokenRange(icu)
            if r.location != kCFNotFound, r.length > 0 {
                let from = w.start + w.character(forUTF16: r.location)
                let to = w.start + w.character(forUTF16: r.location + r.length)
                if to > from { result.append(from ..< to) }
            }
            type = CFStringTokenizerAdvanceToNextToken(icu)
        }
        // A leaf node projects as U+FFFC, and the system tokenizer counts one
        // as a word of its own — which is what makes double-tapping an image
        // select it. ICU does not report it, so add it back.
        for (i, c) in w.chars.enumerated() where c == "\u{fffc}" {
            result.append((w.start + i) ..< (w.start + i + 1))
        }
        if result.count > 1 { result.sort { $0.lowerBound < $1.lowerBound } }
        return result
    }

    private func isWord(_ g: UITextGranularity) -> Bool { g == .word }

    private func forward(_ direction: UITextDirection) -> Bool {
        if let storage = UITextStorageDirection(rawValue: direction.rawValue) {
            return storage == .forward
        }
        if let layout = UITextLayoutDirection(rawValue: direction.rawValue) {
            return layout == .right || layout == .down
        }
        return true
    }

    private func offset(_ position: UITextPosition) -> Int? {
        (position as? DocTextPosition)?.offset
    }

    // MARK: UITextInputTokenizer

    func rangeEnclosingPosition(_ position: UITextPosition, with granularity: UITextGranularity,
                                inDirection direction: UITextDirection) -> UITextRange? {
        guard isWord(granularity), let pos = offset(position) else {
            return fallback?.rangeEnclosingPosition(position, with: granularity, inDirection: direction)
        }
        // Facing forward, a position at the word's end is behind you; facing
        // backward, one at its start is. Interior positions belong to the word
        // either way.
        return words(around: pos).word(at: pos, ahead: forward(direction))
            .map { DocTextRange($0.lowerBound, $0.upperBound) }
    }

    func isPosition(_ position: UITextPosition, atBoundary granularity: UITextGranularity,
                    inDirection direction: UITextDirection) -> Bool {
        guard isWord(granularity), let pos = offset(position) else {
            return fallback?.isPosition(position, atBoundary: granularity, inDirection: direction) ?? false
        }
        // Not symmetric, and not the same reading of direction as the rest of
        // the protocol: a word's start counts facing backward, its end facing
        // forward. The layout directions (right/left) behave as backward here
        // rather than following the writing direction — matched against
        // `UITextInputStringTokenizer` position by position, since word-wise
        // arrow movement and double-tap selection both read this.
        let towardEnd = direction.rawValue == UITextStorageDirection.forward.rawValue
        let w = words(around: pos)
        return towardEnd ? w.word(at: pos, ahead: false)?.upperBound == pos
                         : w.word(at: pos, ahead: true)?.lowerBound == pos
    }

    func position(from position: UITextPosition, toBoundary granularity: UITextGranularity,
                  inDirection direction: UITextDirection) -> UITextPosition? {
        guard isWord(granularity), let pos = offset(position) else {
            return fallback?.position(from: position, toBoundary: granularity, inDirection: direction)
        }
        let w = words(around: pos)
        let next = forward(direction) ? w.edge(after: pos) : w.edge(before: pos)
        return next.map { DocTextPosition($0) }
    }

    func isPosition(_ position: UITextPosition, withinTextUnit granularity: UITextGranularity,
                    inDirection direction: UITextDirection) -> Bool {
        guard isWord(granularity), let pos = offset(position) else {
            return fallback?.isPosition(position, withinTextUnit: granularity, inDirection: direction) ?? false
        }
        return words(around: pos).word(at: pos, ahead: forward(direction)) != nil
    }
}
#endif

import CoreText
import Foundation

/// Where a text block's lines end, and how to re-break one after an edit
/// without breaking all of it again. `DocumentLayout.lineEnds` decides which.
enum LineBreaking {
    /// A block shorter than this breaks in full: under ~2000 UTF-16 units a
    /// whole re-break is well under a millisecond, and comparing it with the
    /// last one would cost about as much as it saves.
    ///
    /// Built with `PROSEKIT_VERIFY_BREAKS`, every block resumes whenever it
    /// can, and each result is checked against a full re-break: that puts
    /// every layout the other suites and fuzzers make through this path.
    #if PROSEKIT_VERIFY_BREAKS
    static let incrementalMinimumLength = 0
    #else
    static let incrementalMinimumLength = 2000
    #endif

    /// CoreText shapes a string longer than this many UTF-16 units
    /// differently: the system font loses its kerning (measured on iOS 27 /
    /// macOS 27), so every line of it comes out a little wider — ~0.2% — and
    /// any line that was within that of the width wraps one word earlier. It
    /// is the length of the whole string that counts, not of the paragraph
    /// being broken or of anything near the line. So the same text breaks
    /// differently at 10,240 units than at 10,241, and breaks are only carried
    /// over between two texts on the same side of this length.
    /// `IncrementalLineBreakTests` checks the threshold is still here.
    static let shapingChangeLength = 10240

    /// Whether texts of these two lengths are shaped alike.
    static func shapedAlike(_ a: Int, _ b: Int) -> Bool {
        (a > shapingChangeLength) == (b > shapingChangeLength)
    }

    /// `CTTypesetterSuggestLineBreak` wraps by width only — it doesn't stop at
    /// hard line breaks (a code block's "\n", or a hard break's U+2028) — so
    /// each line is capped at the first mandatory break inside it.
    static let hardBreaks = CharacterSet(charactersIn: "\n\r\u{2028}\u{2029}")

    /// The end of the line that starts at `start`.
    static func lineEnd(_ typesetter: CTTypesetter, string: NSString, width: CGFloat, from start: Int) -> Int {
        let length = string.length
        var count = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
        if count <= 0 { count = length - start }
        let br = string.rangeOfCharacter(from: hardBreaks, range: NSRange(location: start, length: count))
        if br.location != NSNotFound { count = br.location - start + 1 }
        return start + max(count, 1)
    }

    /// Break from `start` to the end of the text, after the lines already in `prefix`.
    static func ends(_ typesetter: CTTypesetter, string: NSString, width: CGFloat,
                     from start: Int, prefix: [Int]) -> [Int] {
        var ends = prefix
        var start = start
        while start < string.length {
            start = lineEnd(typesetter, string: string, width: width, from: start)
            ends.append(start)
        }
        return ends
    }

    /// Re-break text that differs from a previously broken text only between
    /// its first `prefix` and its last `suffix` UTF-16 units, both shaped
    /// alike (`shapedAlike`).
    ///
    /// Old breaks before the change are kept up to a line above the one that
    /// reaches the start of the word the change is in — a deletion can let
    /// the line above take in a word that no longer fits below, and without
    /// that line the oracle tests fail — and further back while that line
    /// would start mid-word. Breaking then resumes with the whole new text's
    /// typesetter, and stops at the first new break in the unchanged tail that
    /// follows a space and lands exactly where an old one did: from there on
    /// the text is what it was, so the old breaks hold, shifted by the change
    /// in length. Starting and stopping only at spaces is deliberately
    /// narrower than it has been shown to need to be — a break inside a word,
    /// between ideographs or after a hyphen is never one to resume from.
    static func resume(_ typesetter: CTTypesetter, string: NSString, units: [unichar], width: CGFloat,
                       old: [Int], oldLength: Int, prefix: Int, suffix: Int) -> [Int] {
        let length = string.length
        let delta = length - oldLength
        var wordStart = prefix
        while wordStart > 0, !isBreakingSpace(units[wordStart - 1]) { wordStart -= 1 }
        var restart = max(0, firstIndex(in: old, atLeast: wordStart) - 1)
        // Lines before the change: the prefix is the same text in both.
        while restart > 0, !isBreakingSpace(units[old[restart - 1] - 1]) { restart -= 1 }
        var ends = Array(old[..<restart])
        var start = restart > 0 ? old[restart - 1] : 0
        let tail = length - suffix
        while start < length {
            start = lineEnd(typesetter, string: string, width: width, from: start)
            ends.append(start)
            if start >= tail, start < length, isBreakingSpace(units[start - 1]) {
                let j = firstIndex(in: old, atLeast: start - delta)
                if j < old.count, old[j] == start - delta {
                    ends.append(contentsOf: old[(j + 1)...].lazy.map { $0 + delta })
                    return ends
                }
            }
        }
        return ends
    }

    /// Whether a line may end after this unit because it is a space a line
    /// breaks after — a hard break counts. Deliberately narrow: a hyphen, a
    /// soft hyphen, the gap between two ideographs and a break forced inside a
    /// word are all breaks, but not ones to resume from.
    static func isBreakingSpace(_ unit: unichar) -> Bool {
        switch unit {
        case 0x0009, 0x000A, 0x000D, 0x0020, 0x1680, 0x2000 ... 0x2006, 0x2008 ... 0x200B,
             0x2028, 0x2029, 0x205F, 0x3000:
            true
        default:
            false
        }
    }

    /// The index of the first element of the ascending `ends` that is at least `value`.
    private static func firstIndex(in ends: [Int], atLeast value: Int) -> Int {
        var lo = 0, hi = ends.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if ends[mid] < value { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    static func utf16(_ string: NSString) -> [unichar] {
        let length = string.length
        guard length > 0 else { return [] }
        return unsafe [unichar](unsafeUninitializedCapacity: length) { buffer, count in
            unsafe string.getCharacters(buffer.baseAddress!, range: NSRange(location: 0, length: length))
            count = length
        }
    }

    /// Whether a text can be re-broken by resuming at all. Two kinds of text
    /// are held back, conservatively, by code unit, because an edit in them
    /// could move breaks further back than the line above it:
    ///
    /// - anything that can reorder a line: right-to-left letters and digits
    ///   (Hebrew through Arabic Extended, the presentation forms, and the
    ///   supplementary right-to-left blocks, via their high surrogates) and
    ///   the explicit bidirectional controls. Bidi levels resolve across the
    ///   whole paragraph.
    /// - the scripts line breaking segments by dictionary — Thai, Lao,
    ///   Myanmar, Khmer and the Tai scripts — where one character can
    ///   re-segment the words around it.
    ///
    /// And a text with no space to resume from gains nothing — it would be
    /// re-broken from its start to its end — so it takes the plain path. That
    /// is Chinese and Japanese, whose breaking isn't quadratic to begin with
    /// (9000 characters: 3.4 ms a keystroke, all of it).
    static func canResume(_ units: [unichar]) -> Bool {
        var space = false
        for u in units {
            switch u {
            case 0x0590 ... 0x08FF, 0xFB1D ... 0xFDFF, 0xFE70 ... 0xFEFF,
                 0xD802 ... 0xD803, 0xD83A ... 0xD83B,
                 0x200E, 0x200F, 0x202A ... 0x202E, 0x2066 ... 0x2069,
                 0x0E00 ... 0x0EFF, 0x1000 ... 0x109F, 0x1780 ... 0x17FF,
                 0x1950 ... 0x19DF, 0x1A20 ... 0x1AAF, 0xA9E0 ... 0xA9FF, 0xAA60 ... 0xAADF:
                return false
            default:
                if !space, isBreakingSpace(u) { space = true }
            }
        }
        return space
    }

    /// How many UTF-16 units two texts share at the start and at the end, by
    /// character alone. The two never overlap, or an edit that repeats the
    /// text around it would have no extent.
    static func sharedUnits(_ ua: [unichar], _ ub: [unichar]) -> (prefix: Int, suffix: Int) {
        let limit = min(ua.count, ub.count)
        var prefix = 0
        while prefix < limit, ua[prefix] == ub[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < limit - prefix, ua[ua.count - 1 - suffix] == ub[ub.count - 1 - suffix] { suffix += 1 }
        return (prefix, suffix)
    }

    /// How many of the first `limit` units — already known to be the same
    /// characters — `a` and `b` also give the same attributes, so that they
    /// shape alike: a run of another font or kerning breaks differently.
    ///
    /// Walked with Core Foundation rather than `attributes(at:)`, which hands
    /// each run over as a Swift dictionary: a paragraph built one text node at
    /// a time holds a run per node, and bridging thousands of them cost
    /// milliseconds a keystroke — as much as the breaking this saves.
    static func sameAttributesFromStart(_ a: NSAttributedString, _ b: NSAttributedString, upTo limit: Int) -> Int {
        let ca = a as CFAttributedString, cb = b as CFAttributedString
        var i = 0
        while i < limit {
            var ra = CFRange(), rb = CFRange()
            guard sameRun(ca, cb, i, i, &ra, &rb) else { return i }
            i = min(ra.location + ra.length, rb.location + rb.length)
        }
        return limit
    }

    /// The same, for the last `limit` units.
    static func sameAttributesFromEnd(_ a: NSAttributedString, _ b: NSAttributedString, upTo limit: Int) -> Int {
        let ca = a as CFAttributedString, cb = b as CFAttributedString
        let la = a.length, lb = b.length
        // `j` units from the end are known to match.
        var j = 0
        while j < limit {
            var ra = CFRange(), rb = CFRange()
            guard sameRun(ca, cb, la - 1 - j, lb - 1 - j, &ra, &rb) else { return j }
            j = min(la - ra.location, lb - rb.location)
        }
        return limit
    }

    /// The metrics an inline atom's run delegate reserves, as a value beside
    /// it: width, ascent and descent (`DocumentLayout`'s `boxRunAttributes`).
    static let atomMetricsKey = NSAttributedString.Key("ProseKitAtomMetrics")

    /// Whether the runs at `i` in `a` and `j` in `b` have attributes known to
    /// shape alike, reporting each run's range.
    ///
    /// A run delegate is a new object per typeset and compares by identity,
    /// so two runs holding one are compared on everything else instead —
    /// which includes the metrics it reserves, carried beside it as a value.
    /// A delegate without them is never known to be the same.
    private static func sameRun(_ a: CFAttributedString, _ b: CFAttributedString, _ i: Int, _ j: Int,
                                _ ra: inout CFRange, _ rb: inout CFRange) -> Bool {
        guard let xa = unsafe CFAttributedStringGetAttributes(a, i, &ra),
              let xb = unsafe CFAttributedStringGetAttributes(b, j, &rb) else { return false }
        let delegate = unsafe Unmanaged.passUnretained(kCTRunDelegateAttributeName).toOpaque()
        let inA = unsafe CFDictionaryContainsKey(xa, delegate), inB = unsafe CFDictionaryContainsKey(xb, delegate)
        if !inA, !inB { return CFEqual(xa, xb) }
        // The key bridged here is a temporary: held alive across every call
        // that hashes it, or its pointer would dangle.
        let name = atomMetricsKey.rawValue as CFString
        return withExtendedLifetime(name) {
            let metrics = unsafe Unmanaged.passUnretained(name).toOpaque()
            guard inA, inB, unsafe CFDictionaryContainsKey(xa, metrics), unsafe CFDictionaryContainsKey(xb, metrics),
                  let ma = CFDictionaryCreateMutableCopy(nil, 0, xa),
                  let mb = CFDictionaryCreateMutableCopy(nil, 0, xb) else { return false }
            unsafe CFDictionaryRemoveValue(ma, delegate)
            unsafe CFDictionaryRemoveValue(mb, delegate)
            return CFEqual(ma, mb)
        }
    }
}

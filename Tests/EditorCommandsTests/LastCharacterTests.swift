import Foundation
import EditorInputRules
import TestHarness

// The input-rules plugin skips a rule's regex when the character just typed
// can't end one of its matches. That's only sound if `LastCharacter` reads the
// pattern right, so these check it against ICU itself, not against a list.

/// Every pattern the kit ships, and some built to trip the reader up.
private let patterns: [String] = [
    "--$", "\\.\\.\\.$", "\"$", "'$",
    "(?<!\\$)\\$([^$\\s][^$]*)\\$$", "^\\$\\$([^$]+)\\$\\$$",
    "^(#{1})\\s$", "^(#{3})\\s$", "^\\s*>\\s$", "^```$", "^\\s*([-+*])\\s$", "^(\\d+)\\.\\s$",
    "(?:^|\\s)(\\*\\*(?<text>[^*]+)\\*\\*)$", "(?:^|\\s)(__([^_]+)__)$",
    "(?:^|\\s)(\\*([^*]+)\\*)$", "(?:^|\\s)(_([^_]+)_)$",
    "(?:^|\\s)(~~([^~\\s]|[^~\\s][^~]*[^~\\s])~~)$", "(?:^|\\s)(==([^=\\s]|[^=\\s][^=]*[^=\\s])==)$",
    "(?:`)([^`]+)(?:`)$", "(?:^|\\s)((?:https?://|www\\.)[^\\s]+)(\\s)$",
    "\\[\\[([^\\]|]+)(?:\\|([^\\]]+))?\\]\\]$", "^\\s*\\[([ xX]?)\\]\\s$",
    // Ones that must not get a character, or must get the right one.
    "a|b$", "(a|b)$", "ab?$", "ab*$", "ab+$", "a(?=b)$", "a\\b$", "(a)$", "a.$", "a\\d$",
    "(?i)a$", "a[b]$", "[a]]$", "[]a]$", "a$|b", "(a$)", "a(?!$)", "\\\\$", "a\\$", "a{2}$",
    "(?:a(?:b(?:c)))$", "(?<n>x)+$", "[[a][b]]c$", "\\Qa\\E$", "x\\p{L}$", "x\\s+$", "x\\s*$",
]

func registerLastCharacterTests() {
    test("last character: read off the end of the shipped patterns") {
        try expectEqual(LastCharacter(endOf: "--$"), .scalar("-"))
        try expectEqual(LastCharacter(endOf: "(?<!\\$)\\$([^$\\s][^$]*)\\$$"), .scalar("$"))
        try expectEqual(LastCharacter(endOf: "^(#{2})\\s$"), .whitespace)
        try expectEqual(LastCharacter(endOf: "(?:^|\\s)(\\*\\*(?<text>[^*]+)\\*\\*)$"), .scalar("*"))
        try expectEqual(LastCharacter(endOf: "(?:^|\\s)((?:https?://|www\\.)[^\\s]+)(\\s)$"), .whitespace)
        try expectEqual(LastCharacter(endOf: "\\[\\[([^\\]|]+)(?:\\|([^\\]]+))?\\]\\]$"), .scalar("]"))
        try expectEqual(LastCharacter(endOf: "(?:`)([^`]+)(?:`)$"), .scalar("`"))
        try expectEqual(LastCharacter(endOf: "ab+$"), .scalar("b"))
        // Not certain, so the rule runs every time.
        for unsure in ["a|b$", "ab?$", "ab*$", "a.$", "(?i)a$", "a$|b", "a{2}$", "\\Qa\\E$", "x\\s*$", "$", "a"] {
            try expectNil(LastCharacter(endOf: unsure))
        }
    }

    test("last character: no match ICU finds at the end ends with another character") {
        // Strings drawn from every character the patterns name, plus letters,
        // Unicode spaces and a combining mark.
        let alphabet: [String] = ["a", "b", "c", "x", "X", "1", "2", " ", "\u{00A0}", "\u{3000}", "\n", "\t",
                                  "-", ".", "\"", "'", "$", "#", ">", "`", "*", "_", "~", "=", "[", "]", "|",
                                  ":", "/", "h", "t", "p", "s", "w", "\\", "\u{0301}", "é", "+"]
        var rng = SplitMix64(seed: 0x1A57)
        var checked = 0
        for pattern in patterns {
            let regex = try NSRegularExpression(pattern: pattern)
            guard let last = LastCharacter(endOf: pattern) else { continue }
            for _ in 0..<4000 {
                let length = Int(rng.next() % 9) + 1
                let text = (0..<length).map { _ in alphabet[Int(rng.next() % UInt64(alphabet.count))] }.joined()
                let ns = text as NSString
                guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
                      NSMaxRange(m.range) == ns.length, m.range.length > 0 else { continue }
                checked += 1
                try expect(last.admits(text.unicodeScalars.last!),
                           "\(pattern) matched \(text.debugDescription), but claims it must end with \(last)")
            }
        }
        // Make sure the sweep reached matches at all.
        try expect(checked > 500, "only \(checked) matches checked")
    }
}

private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

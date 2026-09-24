import Foundation
import DocumentModel
import EditorSerialization
import TestHarness

// `MarkdownParser.literalAutolinks(in:)`: the bare URLs in text that isn't
// Markdown, which the editor links when such text is pasted.
//
// It shares its detector with the Markdown parser, so the examples here pin
// only what differs — the `www.` host, the ranges it hands back — and the sweep
// at the end checks the two agree wherever Markdown has nothing else to say.

/// The URLs found in `text`, as `text→href`.
private func plainLinks(_ text: String) -> [String] {
    MarkdownParser.literalAutolinks(in: text).map { "\(text[$0.range])→\($0.href)" }
}

/// The links in the Markdown parse of `md`, as `text→href`.
private func markdownLinks(_ md: String) throws -> [String] {
    var found: [String] = []
    try MarkdownParser.parse(md, schema: schema).descendants { node, _, _, _ in
        if let href = node.marks.first(where: { $0.type.name == "link" })?.attrs["href"]?.stringValue {
            found.append("\(node.text ?? "")→\(href)")
        }
        return true
    }
    return found
}

/// SplitMix64, so a failing seed reproduces.
private struct AutolinkRNG: RandomNumberGenerator {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Pieces a URL is made of, the punctuation a sentence puts around one, the
/// characters that end one, and text whose UTF-8 and Character counts differ.
private let urlPieces = [
    "https://", "http://", "HTTPS://", "mailto:", "www.", "WWW.", "javascript:",
    "example", "a", "b-c", "x_y", "com", "org", "1",
    ".", ".", "/", "?", "=", "&", "#", "@", ":", ",", "!", ";", "&amp;", "(", ")",
    " ", " ", "\t", "\n", "\r\n", "<",
    "é", "e\u{301}", "🇫🇷", "日本",
]

/// The subset Markdown reads as plain text on one line: no emphasis, escapes,
/// brackets, entities, HTML or line breaks, so Markdown's only inline work is
/// the literal autolinks under test.
private let markdownNeutralPieces = urlPieces.filter { piece in
    !piece.contains { "*_~\\`[]<>&!\n\r\t#".contains($0) }
}

private func pick<T>(_ items: [T], _ rng: inout AutolinkRNG) -> T { items[Int(rng.next() % UInt64(items.count))] }

/// Something shaped like a URL — a scheme, a host, maybe a path, maybe a
/// sentence's punctuation after it — with pieces spliced in, so it's often a
/// link and often almost one.
private func urlShaped(_ pieces: [String], _ rng: inout AutolinkRNG) -> String {
    let neutral = pieces == markdownNeutralPieces
    var url = pick(["https://", "http://", "HTTPS://", "mailto:x@", "www.", "WWW.", "javascript:", ""], &rng)
    let segments = Int(rng.next() % 3) + 1
    url += (0 ..< segments).map { _ in pick(["example", "a", "b-c", "x_y", "1"], &rng) }.joined(separator: ".")
    url += "." + pick(["com", "org", "io", "x_y"], &rng)
    // `(https://` and `(www.` inside a URL: a boundary and a scheme the scan
    // must not start a second, overlapping link at.
    let tails = ["/p", "/(q)", "?k=v", "/é", "/(https://b.io", "(www.c.io"] + (neutral ? [] : ["#f", "&amp;"])
    let trailing = neutral ? [".", ",", ")", ";", ":"] : [".", ",", ")", "!", ";", ":", "&amp;"]
    for _ in 0 ..< Int(rng.next() % 4) { url += pick(tails + pieces, &rng) }
    for _ in 0 ..< Int(rng.next() % 3) { url += pick(trailing, &rng) }
    return url
}

private func randomText(_ pieces: [String], _ rng: inout AutolinkRNG) -> String {
    let count = Int(rng.next() % 8) + 1
    return (0 ..< count).map { _ in rng.next() % 3 == 0 ? urlShaped(pieces, &rng) : pick(pieces, &rng) }.joined()
}

func registerPlainTextAutolinkTests() {
    test("Plain-text autolinks: the parser's URLs, plus a www. host") {
        try expectEqual(plainLinks("see https://example.com/a?b=1, then mailto:a@b.com."),
                        ["https://example.com/a?b=1→https://example.com/a?b=1",
                         "mailto:a@b.com→mailto:a@b.com"])
        // Unlike Markdown, a scheme-less www. host links, to https — as typing one does.
        try expectEqual(plainLinks("go to www.example.com/x!"),
                        ["www.example.com/x→https://www.example.com/x"])
        try expectEqual(plainLinks("(WWW.Example.com)"), ["WWW.Example.com→https://WWW.Example.com"])
        // Several in a row, each at its own word boundary.
        try expectEqual(plainLinks("http://a.io https://b.io\twww.c.io"),
                        ["http://a.io→http://a.io", "https://b.io→https://b.io", "www.c.io→https://www.c.io"])
        // A paren the link opened is the link's; one the sentence opened isn't.
        try expectEqual(plainLinks("(see https://en.wikipedia.org/wiki/Foo_(bar))"),
                        ["https://en.wikipedia.org/wiki/Foo_(bar)→https://en.wikipedia.org/wiki/Foo_(bar)"])
        // A scheme inside a URL, even after a boundary character, is part of it.
        try expectEqual(plainLinks("https://x.io/(https://y.io) www.a.io/(www.b.io)"),
                        ["https://x.io/(https://y.io)→https://x.io/(https://y.io)",
                         "www.a.io/(www.b.io)→https://www.a.io/(www.b.io)"])
        // A trailing entity reference belongs to the text around it.
        try expectEqual(plainLinks("https://a.io/x&amp; more"), ["https://a.io/x→https://a.io/x"])
    }

    test("Plain-text autolinks: line endings end a URL") {
        try expectEqual(plainLinks("https://example.com\r\nnext"),
                        ["https://example.com→https://example.com"])
        try expectEqual(plainLinks("https://a.io\rhttps://b.io"),
                        ["https://a.io→https://a.io", "https://b.io→https://b.io"],
                        "a bare CR is a line ending, and a boundary after it")
        try expectEqual(plainLinks("a\nwww.b.io"), ["www.b.io→https://www.b.io"])
    }

    test("Plain-text autolinks: ranges are right after non-ASCII text") {
        try expectEqual(plainLinks("café 🇫🇷 https://example.fr/é ok"),
                        ["https://example.fr/é→https://example.fr/é"])
        try expectEqual(plainLinks("e\u{301} www.x.io 日本"), ["www.x.io→https://www.x.io"])
        // A combining mark straight after a URL stays inside it: the scan only
        // stops at ASCII, and the mark belongs to the character before it.
        try expectEqual(plainLinks("https://a.io/e\u{301}"), ["https://a.io/e\u{301}→https://a.io/e\u{301}"])
    }

    test("Plain-text autolinks: what isn't one") {
        try expect(plainLinks("").isEmpty)
        try expect(plainLinks("www").isEmpty)
        try expect(plainLinks("www.").isEmpty)
        // `www.` plus one more segment is a host, as it is when typed.
        try expectEqual(plainLinks("www.localhost"), ["www.localhost→https://www.localhost"])
        try expect(plainLinks("awww.example.com").isEmpty, "not mid-word")
        try expect(plainLinks("xhttps://example.com").isEmpty, "not mid-word")
        try expect(plainLinks("/https://example.com").isEmpty, "not mid-path")
        try expect(plainLinks("foo@bar.com").isEmpty)
        try expect(plainLinks("https://localhost").isEmpty)
        try expect(plainLinks("https://").isEmpty)
        try expect(plainLinks("https://.").isEmpty)
        try expect(plainLinks("mailto:nobody").isEmpty)
        try expect(plainLinks("javascript:alert(1)").isEmpty)
        try expect(plainLinks("ftp://example.com").isEmpty)
        // Markdown still leaves a www. host alone.
        try expect(try markdownLinks("www.example.com").isEmpty)
    }

    let deep = ProcessInfo.processInfo.environment["PROSEKIT_FUZZ"] != nil
    let seeds: UInt64 = deep ? 200_000 : 5_000

    test("Plain-text autolinks sweep: every range is a whole, stable link (\(seeds) seeds)") {
        // What the sweep produced, so a generator that stops making some kind
        // of link fails here rather than passing on nothing.
        var kinds: [String: Int] = [:]
        for seed in 0 ..< seeds {
            var rng = AutolinkRNG(seed)
            let text = randomText(urlPieces, &rng)
            let found = MarkdownParser.literalAutolinks(in: text)
            var previousEnd = text.startIndex
            for (range, href) in found {
                let url = String(text[range])
                let context = "seed \(seed): \(text.debugDescription) → \(url.debugDescription)"
                // In order, apart, and never empty.
                try expect(range.lowerBound >= previousEnd, "overlapping or out of order, \(context)")
                try expect(!range.isEmpty, "empty range, \(context)")
                previousEnd = range.upperBound
                // Nothing that ends a URL is inside one.
                try expect(!url.unicodeScalars.contains { " \t\n\r<".unicodeScalars.contains($0) },
                           "a terminator inside the URL, \(context)")
                // At a word boundary: the start of the text, or after one of
                // the characters allowed to hug a link.
                if range.lowerBound > text.startIndex {
                    let before = text.unicodeScalars[text.unicodeScalars.index(before: range.lowerBound)]
                    try expect(" \t\n\r*_~(".unicodeScalars.contains(before), "not at a boundary, \(context)")
                }
                // A sentence's punctuation is never the link's last character.
                // (A `;` is, unless it closes an entity: GFM keeps it.)
                try expect(!"?!.,:*_~".contains(url.last!), "untrimmed tail, \(context)")
                if url.hasSuffix(")") {
                    try expect(url.filter { $0 == ")" }.count <= url.filter { $0 == "(" }.count,
                               "an unbalanced closing paren kept, \(context)")
                }
                // The href is the text, with https:// before a bare www. host.
                let lower = url.lowercased()
                kinds[String(lower.prefix { $0 != ":" && $0 != "." }), default: 0] += 1
                if range.lowerBound > text.startIndex { kinds["mid-text", default: 0] += 1 }
                if !url.allSatisfy(\.isASCII) || !text[..<range.lowerBound].allSatisfy(\.isASCII) {
                    kinds["non-ascii", default: 0] += 1
                }
                if lower.hasPrefix("www.") {
                    try expectEqual(href, "https://" + url, context)
                } else {
                    try expect(lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:"),
                               "an unexpected scheme, \(context)")
                    try expectEqual(href, url, context)
                }
                // Stable: found alone, the link is found whole — nothing more
                // of it trimmed, nothing less of it taken.
                try expectEqual(plainLinks(url), ["\(url)→\(href)"], "not stable, \(context)")
            }
        }
        for kind in ["http", "https", "mailto", "www", "mid-text", "non-ascii"] {
            try expect(kinds[kind, default: 0] >= 20, "the sweep made \(kinds[kind, default: 0]) \(kind) links: \(kinds)")
        }
    }

    test("Plain-text autolinks sweep: agrees with the Markdown parser (\(seeds) seeds)") {
        // On text Markdown reads as nothing but words and bare URLs, the two
        // must find the same links — except the www. hosts only plain text takes.
        var agreed = 0
        for seed in 0 ..< seeds {
            var rng = AutolinkRNG(seed)
            // Markdown trims leading spaces off a paragraph, and a leading
            // digit-dot or dash could start a list.
            let text = "p " + randomText(markdownNeutralPieces, &rng)
            let all = plainLinks(text)
            // A www. link runs to whitespace like any other, so it can swallow
            // a scheme — `www.a.io/(https://b.io` — that Markdown, which
            // doesn't take the www., links on its own.
            if all.contains(where: { link in
                let lower = link.lowercased()
                return lower.hasPrefix("www.") && ["http://", "https://", "mailto:"].contains { lower.contains($0) }
            }) { continue }
            let plain = all.filter { !$0.lowercased().hasPrefix("www.") }
            let markdown = try markdownLinks(text)
            try expectEqual(plain, markdown, "seed \(seed): \(text.debugDescription)")
            agreed += markdown.count
        }
        try expect(agreed >= 100, "only \(agreed) links compared: the sweep isn't making URLs")
    }
}

import Foundation

// Scheme filtering for URLs arriving from outside the editor.
//
// Parsed HTML and Markdown are untrusted: they come from the clipboard, a
// share sheet, a sync peer, or a file. A `javascript:` href that survives into
// a link mark is a script the editor will happily hand to `UIApplication.open`
// when the user taps it, and a `data:text/html` image source is a script the
// moment anything renders it in a web context. `<script>` itself is dropped by
// the parser, but a URL smuggles the same payload past that.
//
// The policy is an allow-list, not a deny-list: a scheme nobody recognizes is
// rejected rather than assumed harmless, so a scheme we've never heard of
// can't slip through.

/// Where a URL is going to be used, which decides what may appear in it.
enum URLUsage {
    /// A link the user can activate — the editor opens these with the system.
    case link
    /// An image source the renderer loads.
    case image
}

/// Schemes a link may use. Everything here is inert until the user acts on it,
/// and none of them execute script.
private let safeLinkSchemes: Set<String> = [
    "http", "https", "mailto", "tel", "sms", "ftp", "ftps",
]

/// Schemes an image source may use. `file:` is here because the editor itself
/// writes dropped images to disk and references them by path.
private let safeImageSchemes: Set<String> = ["http", "https", "file"]

/// Media types allowed in a `data:` image URL.
///
/// Deliberately excludes `image/svg+xml`: SVG is a document format that can
/// carry `<script>` and event handlers, so a "data image" can be a script.
private let safeImageDataTypes: Set<String> = [
    "image/png", "image/jpeg", "image/jpg", "image/gif", "image/webp",
    "image/bmp", "image/tiff", "image/heic", "image/heif", "image/avif", "image/x-icon",
]

/// A URL that's safe to store in the document, or nil if it must be dropped.
///
/// Returns the original text (trimmed) rather than a normalized URL — the
/// document should keep what the author wrote. Relative URLs carry no scheme to
/// abuse and are always allowed.
func sanitizeURL(_ raw: String, for usage: URLUsage) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    // Browsers ignore ASCII whitespace and C0 controls when resolving a scheme,
    // so `java\tscript:alert(1)` and `java\nscript:alert(1)` both run. Match
    // against a stripped, lowercased copy so those don't slip through, but
    // return the original if it passes.
    // Almost no URL actually contains one of those characters, and building the
    // filtered copy is the expensive part — it collects an array of scalars and
    // then a fresh string. Check first, and only rebuild when there's something
    // to strip.
    let clean = trimmed.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value != 0x7F }
    let probe = clean ? trimmed.lowercased()
        : String(String.UnicodeScalarView(
            trimmed.unicodeScalars.filter { $0.value > 0x20 && $0.value != 0x7F })).lowercased()

    guard let colon = probe.firstIndex(of: ":") else { return trimmed } // relative
    let scheme = probe[..<colon]
    // A colon after a path separator isn't a scheme — `notes/a:b` is relative.
    if scheme.contains(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { return trimmed }
    // A scheme is ALPHA *( ALPHA / DIGIT / "+" / "-" / "." ). Anything else
    // isn't one, so the URL is relative.
    guard let first = scheme.first, first.isLetter,
          scheme.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." })
    else { return trimmed }

    switch usage {
    case .link:
        return safeLinkSchemes.contains(String(scheme)) ? trimmed : nil
    case .image:
        if safeImageSchemes.contains(String(scheme)) { return trimmed }
        guard scheme == "data" else { return nil }
        // data:[<mediatype>][;base64],<data>
        let rest = probe[probe.index(after: colon)...]
        let mediaType = rest.prefix { $0 != ";" && $0 != "," }
        return safeImageDataTypes.contains(String(mediaType)) ? trimmed : nil
    }
}

/// A CSS color that's safe to store and re-serialize, or nil.
///
/// Color values round-trip back into a `style` attribute, so an unfiltered one
/// is an injection point for whatever else CSS can express — `url(javascript:…)`
/// among it. Only the color syntaxes the renderer can actually use are kept.
func sanitizeCSSColor(_ raw: String) -> String? {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.count <= 64 else { return nil }
    let lower = value.lowercased()

    // #rgb / #rrggbb / #rrggbbaa
    if lower.hasPrefix("#") {
        let digits = lower.dropFirst()
        guard [3, 4, 6, 8].contains(digits.count),
              digits.allSatisfy({ $0.isHexDigit }) else { return nil }
        return value
    }
    // rgb()/rgba()/hsl()/hsla(), with only numeric arguments inside.
    for function in ["rgb", "rgba", "hsl", "hsla"] where lower.hasPrefix(function + "(") {
        guard lower.hasSuffix(")") else { return nil }
        let arguments = lower.dropFirst(function.count + 1).dropLast()
        let allowed = Set("0123456789.,%/ +-e")
        return arguments.allSatisfy { allowed.contains($0) } ? value : nil
    }
    // A bare CSS keyword (`red`, `transparent`, `rebeccapurple`).
    return lower.allSatisfy { $0.isLetter } ? value : nil
}

public import Foundation
import CoreFoundation
public import DocumentModel

// RTF → document conversion.
//
// RTF is what nearly every Mac and Windows app puts on the pasteboard, and on
// Apple platforms it has so far reached this editor only by way of
// `NSAttributedString` → Cocoa's HTML writer → `HTMLParser`. That bridge is
// AppKit/UIKit-only, lossy in its own ways (see `HTML.swift`'s note on the
// Cocoa HTML Writer), and unavailable anywhere headless. This reader parses the
// RTF itself: Foundation only, no text system, same shapes out as the HTML and
// Markdown parsers produce.
//
// What it understands is driven by what real producers emit — Word, TextEdit,
// Pages, Apple Notes, LibreOffice, and the RTF that `NSAttributedString`
// writes. The format is far larger than that; `docs/rtf-conversion.md` records
// exactly what survives, what is approximated, and what is dropped.
//
// Everything is best-effort and schema-aware in the same way the Apple Notes
// reader is: node and mark types the schema lacks degrade (heading →
// paragraph, table → its cells' paragraphs, unknown mark → plain text) rather
// than failing, and no input — truncated, unbalanced, or hostile — can trap.
// Only two things throw: bytes that aren't RTF at all, and (defensively) a
// parsed document the schema rejects.

/// Knobs for how much interpretation the reader applies to RTF's purely visual
/// formatting.
public struct RTFConfig: Sendable {
    /// Treat a paragraph set entirely in a monospaced font as a code block, and
    /// monospaced runs inside a mixed paragraph as `code` marks. RTF has no
    /// notion of code, so this font heuristic is the only path to one — it's
    /// how a monospaced Apple Note or a fenced block pasted from an editor
    /// keeps its meaning.
    public var monospaceAsCode: Bool
    /// Convert `\pict` PNG/JPEG/GIF payloads to `image` nodes with `data:` URLs.
    /// When off (or for a picture in a format we can't name), the picture is
    /// dropped.
    public var embedImages: Bool
    /// Pictures whose decoded payload exceeds this are dropped rather than
    /// inlined — a `data:` URL of a 40MB TIFF helps nobody.
    public var maxImageBytes: Int
    /// The deepest group nesting accepted. Groups are parsed iteratively, so
    /// this is a sanity bound on absurd input, not a stack-overflow guard.
    public var maxGroupDepth: Int

    public init(monospaceAsCode: Bool = true, embedImages: Bool = true,
                maxImageBytes: Int = 8 << 20, maxGroupDepth: Int = 256) {
        self.monospaceAsCode = monospaceAsCode
        self.embedImages = embedImages
        self.maxImageBytes = maxImageBytes
        self.maxGroupDepth = maxGroupDepth
    }

    public static let `default` = RTFConfig()
}

/// Why RTF couldn't be parsed into a document.
public enum RTFParseError: Error, CustomStringConvertible, Equatable {
    /// The input doesn't begin with an RTF header (`{\rtf`).
    case notRTF
    /// Groups nest deeper than `RTFConfig.maxGroupDepth`.
    case nestingTooDeep(depth: Int, limit: Int)
    /// The parsed content couldn't be fitted to the schema. Every shape real
    /// producers emit is coerced, so this means the schema itself can't express
    /// the document — a bug rather than bad input.
    case invalidDocument(String)

    public var description: String {
        switch self {
        case .notRTF:
            return "RTFParseError: input doesn't start with an RTF header"
        case let .nestingTooDeep(depth, limit):
            return "RTFParseError: groups nest at least \(depth) deep (limit \(limit))"
        case let .invalidDocument(reason):
            return "RTFParseError: parsed content isn't a valid document — \(reason)"
        }
    }
}

public enum RTFParser {
    /// Parse RTF bytes — the pasteboard/file form — into a document.
    ///
    /// The bytes are read as RTF always intends them: the syntax is 7-bit
    /// ASCII, non-ASCII text arrives as `\'hh` escapes decoded through the
    /// document's code page, and `\uN` carries anything else.
    public static func parse(_ data: Data, schema: Schema, config: RTFConfig = .default) throws -> Node {
        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(data.count)
        for byte in data { scalars.append(Unicode.Scalar(byte)) }
        return try parse(scalars: scalars, schema: schema, config: config)
    }

    /// Parse RTF that has already been decoded to a `String`. Characters above
    /// U+00FF pass through as text (a producer that wrote them literally meant
    /// them); the `\'hh` escapes are still decoded through the code page.
    public static func parse(_ rtf: String, schema: Schema, config: RTFConfig = .default) throws -> Node {
        try parse(scalars: Array(rtf.unicodeScalars), schema: schema, config: config)
    }

    static func parse(scalars: [Unicode.Scalar], schema: Schema, config: RTFConfig) throws -> Node {
        var reader = RTFReader(s: scalars, schema: schema, config: config)
        return try reader.run()
    }
}

// MARK: - Code page

/// Windows-1252 for the 0x80–0x9F range, where it differs from Latin-1. Every
/// other byte maps to the scalar of the same value, which is Latin-1 and is
/// also what MacRoman-era producers get closest to.
private let cp1252High: [UInt32] = [
    0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
    0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
]

private func decodeCodePageByte(_ byte: UInt8) -> Unicode.Scalar {
    if (0x80...0x9F).contains(byte) {
        return Unicode.Scalar(cp1252High[Int(byte) - 0x80]) ?? " "
    }
    return Unicode.Scalar(byte)
}

/// Font names that mean "this is code". Matched case-insensitively as a
/// substring, so "SFMono-Regular" and "Courier New" both count.
private let monospaceFontMarkers = [
    "mono", "courier", "menlo", "consolas", "monaco", "andale", "pragmata", "typewriter",
]

// MARK: - Reader

private struct RTFReader {
    let s: [Unicode.Scalar]
    let schema: Schema
    let config: RTFConfig
    var i = 0

    // MARK: State

    /// Character formatting. Scoped to the RTF group, like the format says.
    struct Style: Equatable {
        var bold = false
        var italic = false
        var underline = false
        var strike = false
        var superscript = false
        var subscripted = false
        var hidden = false
        var color: Int?
        var background: Int?
        var font: Int?
        var link: String?
    }

    /// Paragraph formatting. Also group-scoped, and reset by `\pard`.
    struct ParaProps: Equatable {
        var style: Int?
        var outline: Int?
        var listID: Int?
        var level: Int?
        var leftIndent = 0
        var inTable = false
        /// `\itap`: how deeply nested in tables the paragraph is.
        var itap: Int?
        /// `\qc` / `\qr` / `\qj`: the only place alignment has anywhere to go
        /// in this document model is a table cell.
        var alignment: String?
    }

    /// Where the text inside the current group goes.
    enum Destination {
        case body
        /// Dropped along with everything nested inside it.
        case skip
        case fontTable
        case colorTable
        case styleSheet
        /// `\*\fldinst` — the field's instruction, which is where a HYPERLINK's
        /// URL lives.
        case fieldInstruction
        /// `\listtext` / `\pntext` — the literal bullet or number a producer
        /// draws in front of a list paragraph. It's the most reliable statement
        /// of what kind of list this is, and never document text.
        case listText
        case picture
        /// `\*\listtable` — the definitions that say what each list's levels
        /// actually are: numbered or bulleted, and where the numbering starts.
        case listTable
        /// `\*\listoverridetable` — the indirection from the `\ls` a
        /// paragraph names to the list definition it means.
        case listOverrideTable
        /// `\*\nesttableprops` — a nested row's definition, which Word writes
        /// *after* the cells it describes.
        case nestedTableProperties
        /// `\footnote` — the note's own text, which is a document of its own
        /// written where it is referenced.
        case footnote
        /// `\*\pn` — old-style paragraph numbering, which states a list's kind
        /// the way `\listtable` does for everything since Word 97.
        case paragraphNumbering
    }

    /// Which part of the list tables a group is: they nest several deep, and
    /// what a group means on close depends on which one opened it.
    enum ListRole { case list, level, levelText, override }

    struct Picture: Equatable {
        var mediaType: String?
        /// Bytes from `\bin`, for a picture written as binary rather than hex.
        var binary: [UInt8] = []
        var widthTwips = 0
        var heightTwips = 0
        var pixelWidth = 0
        var pixelHeight = 0
    }

    struct Group {
        var style = Style()
        var para = ParaProps()
        var dest = Destination.body
        /// `\ucN`: how many fallback characters follow each `\uN`.
        var uc = 1
        /// Fallback characters still to be swallowed after a `\uN`.
        var skip = 0
        /// Text collected for a non-body destination.
        var buffer = ""
        var fontDef: Int?
        var styleDef: Int?
        var pict = Picture()
        var listRole: ListRole?
    }

    var group = Group()
    var stack: [Group] = []

    var fontNames: [Int: String] = [:]
    /// `\fcharset` per font: a font can name a different code page than the
    /// document does, which is how a Cyrillic run reaches a cp1252 document.
    var fontCharsets: [Int: Int] = [:]
    /// Fonts whose name says "code" — see `monospaceFontMarkers`.
    var monospaceFonts: Set<Int> = []
    /// `\ansicpg`: the code page `\'hh` bytes are written in.
    var codePage = 1252
    /// Escaped bytes waiting to be decoded together. A multi-byte code page
    /// spells one character as two `\'hh`s, so they can't be decoded one at a
    /// time.
    var pendingBytes: [UInt8] = []
    var colors: [Int: String] = [:]
    var styleNames: [Int: String] = [:]
    /// Colour components accumulating between the `;`s of `\colortbl`.
    var pendingColor: (r: Int, g: Int, b: Int)?
    var colorIndex = 0

    /// One level of a `\list` definition.
    struct ListLevel {
        /// `\levelnfc`: 23 (and 255) are bullets, everything else numbers.
        var numberFormat: Int?
        /// `\levelstartat`: what the first item at this level is numbered.
        var startAt: Int?
        /// `\leveltext`: the marker template, which is where a checkbox glyph
        /// shows up when the list is really a checklist.
        var text = ""
    }

    /// `\listid` → its levels, and `\ls` → `\listid`. A paragraph names an
    /// `\ls`, the override table maps it to a list, and the list says what its
    /// levels look like.
    var listDefinitions: [Int: [ListLevel]] = [:]
    var listOverrides: [Int: Int] = [:]
    /// `\ls` → level → the `\levelstartat` an override supplies, which beats
    /// the definition's own.
    var listStartOverrides: [Int: [Int: Int]] = [:]
    var currentListID: Int?
    var currentListLevels: [ListLevel] = []
    var currentLevel: ListLevel?
    var currentOverrideListID: Int?
    var currentOverrideLS: Int?
    var currentOverrideStart: [Int: Int] = [:]
    var currentOverrideLevel = 0

    /// What `{\*\pn …}` said about the paragraph being read, for documents
    /// that predate the list table.
    var paragraphNumberKind: ListKind?
    var paragraphNumberStart: Int?
    /// The URL of the innermost `{\field}` being read, shared with its
    /// `\fldrslt` — which is the text the reader actually keeps.
    var fieldURL: String?
    /// Set by a `\*` prefix: the control word that *immediately* follows names
    /// a destination a reader is allowed not to understand.
    ///
    /// "Immediately" is load-bearing. Word writes field switches as
    /// `\* MERGEFORMAT` — a space, then plain text — and if the flag survived
    /// that, it would swallow the next real control word instead, which for a
    /// field is the `\fldrslt` holding the text the reader sees.
    var ignorableNext = false

    // MARK: Output

    enum Inline {
        case text(String, Style)
        case node(Node)
    }

    enum ListKind: Equatable { case bullet, ordered, task }

    /// One cell's definition from the row's `\trowd` block. The definitions
    /// come in column order, each terminated by the `\cellx` that states where
    /// the column ends, and they are what say which cells are merged.
    struct CellDefinition {
        var rightBoundary = 0
        /// `\clmgf` / `\clmrg`: the first cell of a horizontally merged range,
        /// and the ones that continue it.
        var horizontalMergeStart = false
        var horizontalMerge = false
        /// `\clvmgf` / `\clvmrg`: the same, vertically.
        var verticalMergeStart = false
        var verticalMerge = false
    }

    struct Cell {
        var blocks: [Block] = []
        var align: String?
        var colspan = 1
        var rowspan = 1
        /// One width in points per column this cell spans.
        var widths: [Int] = []
    }

    struct Row {
        var cells: [Cell] = []
        var header = false
    }

    /// One table being assembled. A nested table gets its own, so a document
    /// can have several in flight — `\itap` says which one a cell belongs to.
    struct TableBuilder {
        var rows: [Row] = []
        /// Cells of the row in progress, before merges are resolved.
        var cells: [Cell] = []
        /// Blocks of the cell in progress.
        var blocks: [Block] = []
        var definitions: [CellDefinition] = []
        var pending = CellDefinition()
        var header = false
        /// `\trleft`: where the first column starts, so its width is a width.
        var leftEdge = 0
        /// Right boundary → the cell a vertical merge continues, so the run of
        /// `\clvmrg` cells below it can raise its `rowspan`.
        var verticalAnchors: [Int: (row: Int, cell: Int)] = [:]
    }

    struct Block {
        enum Kind { case paragraph, heading, code, listItem, table }
        var kind: Kind
        var inline: [Inline] = []
        var headingLevel = 1
        var listKind: ListKind = .bullet
        var level = 0
        var checked = false
        /// `\levelstartat` for an ordered list, when it doesn't start at 1.
        var start: Int?
        /// The paragraph's alignment, which survives only inside a cell.
        var alignment: String?
        /// Finished table nodes, for `.table` blocks.
        var nodes: [Node] = []
    }

    var blocks: [Block] = []
    var inline: [Inline] = []
    /// The text run being read, kept apart from `inline` so appending a
    /// character is an append rather than a fresh string per character.
    var runText = ""
    var runStyle = Style()
    var hasRun = false
    /// The literal marker (`•`, `3.`, `☑`) drawn in front of the paragraph
    /// being read, from its `\listtext`.
    var listMarker: String?

    /// Tables in flight, outermost first — one per `\itap` depth.
    var tables: [TableBuilder] = []

    /// The body state a footnote interrupted, to be restored when it ends.
    struct FootnoteFrame {
        let blocks: [Block]
        let inline: [Inline]
        let listMarker: String?
        let tables: [TableBuilder]
        let label: String
    }

    var footnoteStack: [FootnoteFrame] = []
    var footnoteDefinitions: [Node] = []
    var footnoteCounter = 0

    // MARK: - Driver

    mutating func run() throws -> Node {
        try readHeader()
        while i < s.count {
            let c = s[i]
            switch c {
            case "{":
                flushBytes()
                ignorableNext = false
                i += 1
                stack.append(group)
                if stack.count > config.maxGroupDepth {
                    throw RTFParseError.nestingTooDeep(depth: stack.count, limit: config.maxGroupDepth)
                }
                // A new group inherits formatting but starts its own buffer, so
                // a font-table entry or a picture doesn't see its parent's text.
                group.buffer = ""
                group.fontDef = nil
                group.styleDef = nil
                group.pict = Picture()
                // A role belongs to the group that opened it. Inheriting it
                // would make `{\levelnumbers}` close as if it were the
                // `\listlevel` around it.
                group.listRole = nil
            case "}":
                flushBytes()
                ignorableNext = false
                i += 1
                closeGroup()
            case "\\":
                readControl()
            case "\r", "\n":
                i += 1 // line breaks in the source are formatting, not text
            default:
                ignorableNext = false
                i += 1
                // A plain character counts against the fallback run a `\uN`
                // asked us to swallow, the same as a `\'hh` or a control
                // symbol does.
                if consumedBySkip() { continue }
                // A byte above ASCII is code-page text too — some producers
                // write it raw rather than as `\'hh`.
                if c.value >= 0x80, c.value <= 0xFF {
                    appendByte(UInt8(c.value))
                } else {
                    appendCharacter(c)
                }
            }
        }
        // A file that ends mid-paragraph (or without the customary trailing
        // `\par`) still has content worth keeping.
        flushBytes()
        endParagraph()
        collapseTables(below: 0)
        return try buildDocument()
    }

    /// Consume the `{\rtfN` header, or refuse the input.
    mutating func readHeader() throws {
        var j = 0
        // Skip a UTF-8 BOM (read as three Latin-1 scalars) and leading space.
        while j < s.count, s[j] == "\u{FEFF}" || s[j] == "\u{EF}" || s[j] == "\u{BB}"
            || s[j] == "\u{BF}" || s[j].properties.isWhitespace { j += 1 }
        guard j < s.count, s[j] == "{" else { throw RTFParseError.notRTF }
        var k = j + 1
        while k < s.count, s[k].properties.isWhitespace { k += 1 }
        guard k + 3 < s.count, s[k] == "\\", s[k + 1] == "r", s[k + 2] == "t", s[k + 3] == "f" else {
            throw RTFParseError.notRTF
        }
        i = j
    }

    // MARK: - Control words

    mutating func readControl() {
        i += 1 // past the backslash
        guard i < s.count else { return }
        let c = s[i]
        if isASCIILetter(c) {
            var word = ""
            while i < s.count, isASCIILetter(s[i]) {
                word.unicodeScalars.append(s[i])
                i += 1
            }
            var param: Int?
            var negative = false
            if i < s.count, s[i] == "-" { negative = true; i += 1 }
            if i < s.count, isASCIIDigit(s[i]) {
                var value = 0
                var digits = 0
                while i < s.count, isASCIIDigit(s[i]) {
                    // Bound the accumulation: the parameter is untrusted and
                    // `\li99999999999999999999` must not overflow.
                    if digits < 10 { value = value * 10 + Int(s[i].value - 48) }
                    digits += 1
                    i += 1
                }
                param = negative ? -value : value
            } else if negative {
                param = 0
            }
            if i < s.count, s[i] == " " { i += 1 } // one space delimits, and is eaten
            apply(word: word, param: param)
            ignorableNext = false
            return
        }
        i += 1
        // Only `\*` itself leaves the flag set for the word after it.
        if c != "*" { ignorableNext = false }
        switch c {
        case "'":
            var value = 0
            var digits = 0
            while digits < 2, i < s.count, let d = hexValue(s[i]) {
                value = value * 16 + d
                i += 1
                digits += 1
            }
            guard digits == 2 else { return }
            if consumedBySkip() { return }
            appendByte(UInt8(value))
        case "\\", "{", "}":
            if consumedBySkip() { return }
            appendCharacter(c)
        case "*":
            ignorableNext = true
        case "~":
            if consumedBySkip() { return }
            appendCharacter("\u{00A0}")
        case "_":
            if consumedBySkip() { return }
            appendCharacter("\u{2011}") // non-breaking hyphen
        case "-":
            _ = consumedBySkip() // optional hyphen: invisible unless the line breaks there
        case "\r", "\n":
            if consumedBySkip() { return }
            if inBodyText { endParagraph() }
        case ":", "|":
            _ = consumedBySkip()
        default:
            _ = consumedBySkip()
        }
    }

    mutating func apply(word: String, param: Int?) {
        let on = (param ?? 1) != 0
        // Decode what has been read under the settings it was written with,
        // before this word changes any of them.
        flushBytes()

        // Raw binary: the length is a promise about the bytes that follow, and
        // the only safe thing to do with bytes we can't interpret is skip them.
        // Handled before anything else, because getting it wrong inside a
        // dropped destination resumes parsing in the middle of a PNG.
        if word == "bin" {
            let n = max(0, param ?? 0)
            let end = n <= s.count - i ? i + n : s.count
            // Inside a picture the bytes are the picture: a producer that
            // writes binary rather than hex would otherwise lose the image.
            // Everywhere else they're a payload we can't read, and the only
            // safe thing to do with them is step over them.
            if group.dest == .picture, config.embedImages {
                for k in i..<end where s[k].value <= 0xFF { group.pict.binary.append(UInt8(s[k].value)) }
            }
            i = end
            return
        }
        // Nothing inside a dropped destination can change what the document
        // says — including a control word that would otherwise open a
        // destination we do read.
        if group.dest == .skip { return }

        // A destination the reader doesn't know is dropped whole — that's what
        // `\*` is for, and guessing at its contents would put index entries and
        // revision metadata into the document.
        if ignorableNext, !rtfParsedIgnorableDestinations.contains(word) {
            group.dest = .skip
            return
        }
        if let dest = rtfDestinations[word] {
            group.dest = dest
            if dest == .listText || dest == .fieldInstruction { group.buffer = "" }
            return
        }

        switch word {
        // Character formatting.
        case "b": group.style.bold = on
        case "i": group.style.italic = on
        case "ul", "uld", "uldb", "ulth", "ulw", "ulwave", "uldash", "uldashd", "uldashdd",
             "ulhwave", "ulldash", "ulthd", "ulthdash", "ulthldash", "ululdbwave":
            group.style.underline = on
        case "ulnone": group.style.underline = false
        case "strike", "striked": group.style.strike = on
        case "super": group.style.superscript = on; if on { group.style.subscripted = false }
        case "sub": group.style.subscripted = on; if on { group.style.superscript = false }
        case "up": group.style.superscript = on; if on { group.style.subscripted = false }
        case "dn": group.style.subscripted = on; if on { group.style.superscript = false }
        case "nosupersub": group.style.superscript = false; group.style.subscripted = false
        case "v": group.style.hidden = on
        // Word keeps tracked deletions in the text with `\deleted` on them.
        // They are not part of the document as it currently reads.
        case "deleted": group.style.hidden = on
        case "cf": group.style.color = param
        case "cb", "highlight", "chcbpat": group.style.background = param
        case "f":
            if group.dest == .fontTable { group.fontDef = param } else { group.style.font = param }
        case "plain":
            // Resets character formatting only. The link comes from the
            // enclosing field, not from the run, so it survives.
            let link = group.style.link
            group.style = Style()
            group.style.link = link

        // Colour table entries.
        case "red": pendingColor = (param ?? 0, pendingColor?.g ?? 0, pendingColor?.b ?? 0)
        case "green": pendingColor = (pendingColor?.r ?? 0, param ?? 0, pendingColor?.b ?? 0)
        case "blue": pendingColor = (pendingColor?.r ?? 0, pendingColor?.g ?? 0, param ?? 0)

        // Stylesheet entries: `{\s3 ... heading 3;}`. Index 0 is the default
        // style, which carries no `\s`.
        case "s":
            if group.dest == .styleSheet { group.styleDef = param } else { group.para.style = param }

        // Old-style (pre-`\listtable`) numbering: `{\*\pn\pnlvlblt …}` says
        // bulleted, `\pndec` and friends say numbered. Still emitted by simple
        // exporters, and it's the only statement of kind they make.
        case "pn":
            group.dest = .paragraphNumbering
            paragraphNumberKind = nil
        case "pnlvlblt":
            paragraphNumberKind = .bullet
        case "pndec", "pnucltr", "pnlcltr", "pnucrm", "pnlcrm", "pnord", "pnordt", "pnlvlbody":
            if group.dest == .paragraphNumbering, paragraphNumberKind == nil { paragraphNumberKind = .ordered }
        case "pnstart":
            paragraphNumberStart = param

        // List definitions. `\list`, `\listlevel` and `\leveltext` each open a
        // group whose close is what records what it read.
        case "list" where group.dest == .listTable:
            group.listRole = .list
            currentListID = nil
            currentListLevels = []
        case "listlevel" where group.dest == .listTable:
            group.listRole = .level
            currentLevel = ListLevel()
        case "leveltext" where group.dest == .listTable:
            group.listRole = .levelText
            group.buffer = ""
        case "levelnfc", "levelnfcn":
            if currentLevel != nil { currentLevel?.numberFormat = param }
        case "levelstartat":
            if currentLevel != nil {
                currentLevel?.startAt = param
            } else if group.dest == .listOverrideTable {
                currentOverrideStart[currentOverrideLevel] = param
            }
        case "lfolevel":
            // Each `\lfolevel` group overrides the next level in turn.
            if group.dest == .listOverrideTable { currentOverrideLevel = currentOverrideStart.count }
        case "listoverride" where group.dest == .listOverrideTable:
            group.listRole = .override
            currentOverrideListID = nil
            currentOverrideLS = nil
            currentOverrideStart = [:]
            currentOverrideLevel = 0
        case "listid":
            if group.dest == .listOverrideTable { currentOverrideListID = param } else { currentListID = param }

        // Paragraph formatting.
        case "pard":
            group.para = ParaProps()
            paragraphNumberKind = nil
            paragraphNumberStart = nil
        case "outlinelevel": group.para.outline = param
        case "ql": group.para.alignment = nil
        case "qc": group.para.alignment = "center"
        case "qr": group.para.alignment = "right"
        case "qj": group.para.alignment = "justify"
        case "ls":
            if group.dest == .listOverrideTable { currentOverrideLS = param } else { group.para.listID = param }
        case "ilvl": group.para.level = param
        case "li", "lin": group.para.leftIndent = max(group.para.leftIndent, param ?? 0)
        case "intbl": group.para.inTable = on

        // Footnotes. The note's text is written inline, where the reference
        // is; it becomes a definition of its own with a reference in its place.
        case "footnote":
            beginFootnote()

        // Fields. The instruction group states the URL; the result group is
        // the text the reader sees, and the only part kept.
        case "field":
            fieldURL = nil
        case "fldrslt":
            group.style.link = fieldURL

        // Breaks.
        case "par", "sect", "page":
            if inBodyText { endParagraph() }
        case "line", "softline":
            appendInlineNode("hardBreak")
        case "tab":
            if consumedBySkip() { return }
            appendCharacter("\t")

        // Tables. A row's definition arrives before its cells for a top-level
        // table and after them for a nested one (inside `\*\nesttableprops`),
        // which is why merges are resolved when the row closes rather than as
        // the cells arrive.
        case "trowd" where inTableContext:
            let index = table(at: rowDefinitionDepth)
            tables[index].definitions = []
            tables[index].pending = CellDefinition()
            tables[index].header = false
        case "trhdr" where inTableContext:
            tables[table(at: rowDefinitionDepth)].header = on
        case "trleft" where inTableContext:
            tables[table(at: rowDefinitionDepth)].leftEdge = param ?? 0
        case "cellx" where inTableContext:
            let index = table(at: rowDefinitionDepth)
            tables[index].pending.rightBoundary = param ?? 0
            tables[index].definitions.append(tables[index].pending)
            tables[index].pending = CellDefinition()
        case "clmgf" where inTableContext: tables[table(at: rowDefinitionDepth)].pending.horizontalMergeStart = on
        case "clmrg" where inTableContext: tables[table(at: rowDefinitionDepth)].pending.horizontalMerge = on
        case "clvmgf" where inTableContext: tables[table(at: rowDefinitionDepth)].pending.verticalMergeStart = on
        case "clvmrg" where inTableContext: tables[table(at: rowDefinitionDepth)].pending.verticalMerge = on
        case "itap": group.para.itap = param
        case "cell" where inTableContext:
            endCell(depth: max(1, tableDepth(group.para)))
        case "nestcell" where inTableContext:
            endCell(depth: max(2, tableDepth(group.para)))
        case "row" where inTableContext:
            endRow(depth: 1)
        case "nestrow" where inTableContext:
            endRow(depth: max(2, tables.count))

        // Unicode.
        case "uc":
            group.uc = max(0, param ?? 1)
        case "u":
            appendUnicode(param)
        case "ansicpg", "cpg":
            if let param, param > 0 { codePage = param }
        case "fcharset":
            if group.dest == .fontTable, let font = group.fontDef, let param { fontCharsets[font] = param }

        // Literals with a named control word.
        case "emdash": appendEscaped("\u{2014}")
        case "endash": appendEscaped("\u{2013}")
        case "lquote": appendEscaped("\u{2018}")
        case "rquote": appendEscaped("\u{2019}")
        case "ldblquote": appendEscaped("\u{201C}")
        case "rdblquote": appendEscaped("\u{201D}")
        case "bullet": appendEscaped("\u{2022}")
        case "enspace", "emspace", "qmspace": appendEscaped("\u{2002}")
        case "zwnj", "zwj", "ltrmark", "rtlmark": break

        // Pictures.
        case "pngblip": group.pict.mediaType = "image/png"
        case "jpegblip": group.pict.mediaType = "image/jpeg"
        case "picw": group.pict.pixelWidth = param ?? 0
        case "pich": group.pict.pixelHeight = param ?? 0
        case "picwgoal": group.pict.widthTwips = param ?? 0
        case "pichgoal": group.pict.heightTwips = param ?? 0

        default:
            break
        }
    }

    /// Text and structure that belong to a document — the body, or a footnote's
    /// own small document.
    var inBodyText: Bool { group.dest == .body || group.dest == .footnote }

    /// Table structure is stated in the body and, for a nested table, inside
    /// `\*\nesttableprops` — but never inside a destination we're dropping.
    var inTableContext: Bool { inBodyText || group.dest == .nestedTableProperties }

    /// Which table a row definition describes. Inside `\*\nesttableprops` it
    /// is the innermost one; otherwise the depth the current paragraph sits at,
    /// and at minimum the outermost table.
    var rowDefinitionDepth: Int {
        if group.dest == .nestedTableProperties { return max(2, tables.count) }
        return max(1, tableDepth(group.para))
    }

    /// `\*\` destinations we do read rather than drop.
    var parsedIgnorableDestinations: Set<String> {
        ["fldinst", "listtext", "pntext", "shppict", "pict", "listtable", "listoverridetable",
         "nesttableprops"]
    }

    // MARK: - Characters

    /// True when this character is one of the fallbacks a `\uN` told us to
    /// swallow (and consumes one of them).
    mutating func consumedBySkip() -> Bool {
        guard group.skip > 0 else { return false }
        group.skip -= 1
        return true
    }

    /// Hold an escaped byte until we know whether the next one belongs with it.
    mutating func appendByte(_ byte: UInt8) {
        guard group.dest != .skip else { return }
        pendingBytes.append(byte)
    }

    /// Decode the escaped bytes read so far and emit them.
    ///
    /// Called before anything that could change how they should be read — a
    /// different font or code page, a new group, the end of a run of text — so
    /// the bytes are always decoded under the settings they were written with.
    mutating func flushBytes() {
        guard !pendingBytes.isEmpty else { return }
        let bytes = pendingBytes
        pendingBytes = []
        for scalar in decodeBytes(bytes).unicodeScalars { emit(scalar) }
    }

    /// The code page in force: the current font's `\fcharset` if it names one,
    /// otherwise the document's `\ansicpg`.
    var effectiveCodePage: Int {
        if let font = group.style.font, let charset = fontCharsets[font],
           let page = charsetCodePages[charset] {
            return page
        }
        return codePage
    }

    func decodeBytes(_ bytes: [UInt8]) -> String {
        // A Symbol-charset font (Word's bullets are `\f3\'b7`) is not text in
        // any code page. The only glyphs of it that reach a document are list
        // markers, and cp1252's `·` reads as one.
        if let font = group.style.font, fontCharsets[font] == symbolCharset {
            return String(String.UnicodeScalarView(bytes.map(decodeCodePageByte)))
        }
        // The overwhelmingly common case, and the one the table above is for:
        // no Data, no Foundation decoder, no failure mode.
        let page = effectiveCodePage
        if page == 1252 { return String(String.UnicodeScalarView(bytes.map(decodeCodePageByte))) }
        if let encoding = stringEncoding(forCodePage: page),
           let decoded = String(data: Data(bytes), encoding: encoding) {
            return decoded
        }
        // An unknown page, or bytes that aren't valid in it: cp1252 is the
        // closest thing to a universal reading, and never fails.
        return String(String.UnicodeScalarView(bytes.map(decodeCodePageByte)))
    }

    mutating func appendUnicode(_ param: Int?) {
        flushBytes()
        defer { group.skip = group.uc }
        guard let param else { return }
        // The parameter is a signed 16-bit value, so anything above 32767 is
        // written negative.
        var value = param
        if value < 0 { value += 0x10000 }
        guard value >= 0, value <= 0x10FFFF else { return }
        // Surrogate halves are written as a pair of `\u`s; join them.
        if (0xD800...0xDBFF).contains(value) {
            pendingHighSurrogate = value
            return
        }
        if (0xDC00...0xDFFF).contains(value) {
            guard let high = pendingHighSurrogate else { return }
            pendingHighSurrogate = nil
            let combined = 0x10000 + (high - 0xD800) * 0x400 + (value - 0xDC00)
            if let scalar = Unicode.Scalar(UInt32(combined)) { appendCharacter(scalar) }
            return
        }
        pendingHighSurrogate = nil
        if let scalar = Unicode.Scalar(UInt32(value)) { appendCharacter(scalar) }
    }

    mutating func appendEscaped(_ scalar: Unicode.Scalar) {
        if consumedBySkip() { return }
        appendCharacter(scalar)
    }

    mutating func appendCharacter(_ scalar: Unicode.Scalar) {
        flushBytes()
        emit(scalar)
    }

    /// Route one character to wherever the current destination collects text.
    mutating func emit(_ scalar: Unicode.Scalar) {
        switch group.dest {
        case .skip:
            return
        // A footnote's text is body text — of the note, not of the paragraph.
        case .body, .footnote:
            guard !group.style.hidden else { return }
            appendScalar(scalar)
        case .colorTable:
            if scalar == ";" {
                let c = pendingColor
                // Entry 0 (and any entry with no components) is "auto": the
                // reader's own colour, which is not a colour to record.
                if let c { colors[colorIndex] = hexColor(c.r, c.g, c.b) }
                pendingColor = nil
                colorIndex += 1
            }
        case .fontTable:
            if scalar == ";" { recordFont() } else { group.buffer.unicodeScalars.append(scalar) }
        case .styleSheet:
            if scalar == ";" { recordStyle() } else { group.buffer.unicodeScalars.append(scalar) }
        case .fieldInstruction, .listText, .picture:
            group.buffer.unicodeScalars.append(scalar)
        case .nestedTableProperties, .paragraphNumbering:
            return
        case .listTable, .listOverrideTable:
            // Only `\leveltext` holds anything worth keeping; the rest of the
            // tables is control words, and none of it is document text.
            if group.listRole == .levelText { group.buffer.unicodeScalars.append(scalar) }
        }
    }

    mutating func appendText(_ text: String) {
        guard !text.isEmpty else { return }
        startRun()
        runText += text
    }

    mutating func appendScalar(_ scalar: Unicode.Scalar) {
        startRun()
        runText.unicodeScalars.append(scalar)
    }

    /// Begin (or continue) the run for the current formatting.
    mutating func startRun() {
        if hasRun, runStyle == group.style { return }
        flushRun()
        runStyle = group.style
        hasRun = true
    }

    /// Hand the run being read to `inline`. Everything that reads `inline` has
    /// to call this first — the run is text that hasn't arrived there yet.
    mutating func flushRun() {
        if hasRun, !runText.isEmpty { inline.append(.text(runText, runStyle)) }
        runText = ""
        hasRun = false
    }

    mutating func appendInlineNode(_ typeName: String, _ attrs: Attrs = [:]) {
        guard inBodyText, !group.style.hidden,
              let type = schema.nodes[typeName], let node = type.createAndFill(attrs) else { return }
        flushRun()
        inline.append(.node(node))
    }

    var pendingHighSurrogate: Int?

    // MARK: - Group close

    mutating func closeGroup() {
        switch group.dest {
        case .fontTable: recordFont()
        case .styleSheet: recordStyle()
        case .fieldInstruction: readFieldInstruction()
        case .listText: listMarker = group.buffer
        case .picture: appendPicture()
        case .footnote: endFootnote()
        case .listTable, .listOverrideTable: closeListTableGroup()
        default: break
        }
        // A field's URL belongs to the field group, not to the instruction
        // group that stated it: it has to outlive the instruction to reach the
        // result. The next `\field` clears it.
        group = stack.popLast() ?? Group()
    }

    /// Record what a `\list` / `\listlevel` / `\leveltext` / `\listoverride`
    /// group read, now that it has closed.
    mutating func closeListTableGroup() {
        switch group.listRole {
        case .levelText:
            currentLevel?.text = group.buffer
        case .level:
            currentListLevels.append(currentLevel ?? ListLevel())
            currentLevel = nil
        case .list:
            if let id = currentListID { listDefinitions[id] = currentListLevels }
            currentListID = nil
            currentListLevels = []
        case .override:
            if let ls = currentOverrideLS {
                if let id = currentOverrideListID { listOverrides[ls] = id }
                if !currentOverrideStart.isEmpty { listStartOverrides[ls] = currentOverrideStart }
            }
            currentOverrideListID = nil
            currentOverrideLS = nil
            currentOverrideStart = [:]
        case nil:
            break
        }
    }

    /// The definition a paragraph's `\ls` names, at the level it sits at.
    ///
    /// The override table is the documented indirection, but a producer that
    /// writes no overrides numbers its `\ls` as the `\listid` itself, so fall
    /// back to that rather than losing the definition.
    func listLevelDefinition(_ para: ParaProps) -> (level: ListLevel, start: Int?)? {
        guard let ls = para.listID, ls > 0 else { return nil }
        let listID = listOverrides[ls] ?? ls
        guard let levels = listDefinitions[listID], !levels.isEmpty else { return nil }
        let index = min(max(para.level ?? 0, 0), levels.count - 1)
        let level = levels[index]
        return (level, listStartOverrides[ls]?[index] ?? level.startAt)
    }

    /// Start reading a footnote: the note is a small document, so the body's
    /// state steps aside for it. A schema with nowhere to put footnotes drops
    /// the note instead — its text is not part of the paragraph it interrupts.
    mutating func beginFootnote() {
        guard schema.nodes["footnoteReference"] != nil, schema.nodes["footnoteDefinition"] != nil else {
            group.dest = .skip
            return
        }
        flushBytes()
        flushRun()
        group.dest = .footnote
        footnoteCounter += 1
        footnoteStack.append(FootnoteFrame(blocks: blocks, inline: inline, listMarker: listMarker,
                                           tables: tables, label: "\(footnoteCounter)"))
        blocks = []
        inline = []
        listMarker = nil
        tables = []
    }

    /// Finish the note, restore the body, and leave a reference behind where
    /// the note was written.
    ///
    /// RTF numbers footnotes by position, so the label is the note's ordinal.
    /// The definitions are collected and appended at the end of the document,
    /// which is where a block-level definition belongs.
    mutating func endFootnote() {
        guard let frame = footnoteStack.popLast() else { return }
        flushBytes()
        flushRun()
        collapseTables(below: 0)
        if !inline.isEmpty { blocks.append(makeBlock(inline, para: group.para, marker: listMarker)) }
        var content = assembleBlocks(blocks)
        while let last = content.last, last.type.name == "paragraph", last.childCount == 0 { content.removeLast() }

        blocks = frame.blocks
        inline = frame.inline
        listMarker = frame.listMarker
        tables = frame.tables

        if let type = schema.nodes["footnoteDefinition"],
           let node = type.createAndFill(["label": .string(frame.label)], content: Fragment.from(content)) {
            footnoteDefinitions.append(node)
        }
        if let type = schema.nodes["footnoteReference"],
           let node = try? type.create(["label": .string(frame.label)]) {
            inline.append(.node(node))
        }
    }

    mutating func recordFont() {
        defer { group.buffer = ""; group.fontDef = nil }
        guard let index = group.fontDef else { return }
        let name = group.buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        fontNames[index] = name
        // Decided once per font rather than once per run: this question is
        // asked for every text run in the document.
        let lowered = name.lowercased()
        if monospaceFontMarkers.contains(where: { lowered.contains($0) }) { monospaceFonts.insert(index) }
    }

    mutating func recordStyle() {
        defer { group.buffer = ""; group.styleDef = nil }
        let name = group.buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        styleNames[group.styleDef ?? 0] = name
    }

    /// `{\*\fldinst{ HYPERLINK "https://example.com" }}` — pull the URL out and
    /// hand it to the `\fldrslt` that follows.
    mutating func readFieldInstruction() {
        let text = group.buffer
        guard let range = text.range(of: "HYPERLINK", options: .caseInsensitive) else { return }
        let rest = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        var url = rest
        if rest.hasPrefix("\"") {
            let body = rest.dropFirst()
            url = String(body.prefix(while: { $0 != "\"" }))
        } else {
            url = String(rest.prefix(while: { !$0.isWhitespace }))
        }
        // `HYPERLINK \l "anchor"` links within the document rather than out of
        // it; the anchor is the destination, spelled the way every other format
        // spells one.
        if url.hasPrefix("\\") {
            let switchName = url.dropFirst().prefix(while: { !$0.isWhitespace })
            guard switchName.lowercased() == "l" else { return }
            let rest = rest.drop(while: { $0 != "\"" }).dropFirst()
            let anchor = String(rest.prefix(while: { $0 != "\"" }))
            if !anchor.isEmpty { fieldURL = "#" + anchor }
            return
        }
        guard !url.isEmpty else { return }
        fieldURL = url
    }

    mutating func appendPicture() {
        guard config.embedImages, let mediaType = group.pict.mediaType,
              let type = schema.nodes["image"] else { return }
        var bytes = group.pict.binary
        bytes.reserveCapacity(bytes.count + group.buffer.unicodeScalars.count / 2)
        var high: Int?
        for scalar in group.buffer.unicodeScalars {
            guard let value = hexValue(scalar) else { continue }
            if let h = high {
                bytes.append(UInt8(h * 16 + value))
                high = nil
            } else {
                high = value
            }
        }
        guard !bytes.isEmpty, bytes.count <= config.maxImageBytes else { return }
        var attrs: Attrs = ["src": .string("data:\(mediaType);base64,\(Data(bytes).base64EncodedString())")]
        // `picwgoal` is the displayed size in twips, which is what the author
        // chose; `picw` is the intrinsic pixel size, which is the fallback.
        let width = group.pict.widthTwips > 0 ? group.pict.widthTwips / 20 : group.pict.pixelWidth
        let height = group.pict.heightTwips > 0 ? group.pict.heightTwips / 20 : group.pict.pixelHeight
        if width > 0, type.defaultAttrs["width"] != nil { attrs["width"] = .int(width) }
        if height > 0, type.defaultAttrs["height"] != nil { attrs["height"] = .int(height) }
        guard let node = try? type.create(attrs) else { return }
        // The picture is a group of its own; the image belongs to the paragraph
        // around it.
        if let parent = stack.last, parent.dest == .body || parent.dest == .footnote {
            flushRun()
            inline.append(.node(node))
        }
    }

    // MARK: - Paragraph and table flushing

    mutating func endParagraph() {
        flushBytes()
        flushRun()
        let items = inline
        inline = []
        let marker = listMarker
        listMarker = nil
        let numbering = (kind: paragraphNumberKind, start: paragraphNumberStart)
        paragraphNumberKind = nil
        paragraphNumberStart = nil
        let para = group.para

        let depth = tableDepth(para)
        if depth > 0 {
            // A paragraph mark inside a cell separates that cell's blocks — and
            // they are blocks, not merely paragraphs: a list, a heading or a
            // code block inside a cell is as real as one outside it. Anything
            // nested deeper has ended by the time a paragraph arrives here.
            collapseTables(below: depth)
            let index = table(at: depth)
            tables[index].blocks.append(makeBlock(items, para: para, marker: marker, numbering: numbering))
            return
        }
        collapseTables(below: 0)
        blocks.append(makeBlock(items, para: para, marker: marker, numbering: numbering))
    }

    /// How deeply nested in tables this paragraph is: `\itap` says outright,
    /// and a producer that writes only `\intbl` means one.
    func tableDepth(_ para: ParaProps) -> Int {
        max(para.itap ?? 0, para.inTable ? 1 : 0)
    }

    /// The builder for a table `depth` levels in, created on demand. Depth is
    /// clamped to one more than what exists, so a bogus `\itap9` opens one
    /// table rather than nine.
    mutating func table(at depth: Int) -> Int {
        let index = max(1, min(depth, tables.count + 1)) - 1
        while tables.count <= index { tables.append(TableBuilder()) }
        return index
    }

    /// Finish every table nested deeper than `depth`, folding each into the
    /// cell of the table above it — or, at depth 0, into the document.
    mutating func collapseTables(below depth: Int) {
        while tables.count > max(0, depth) {
            var builder = tables.removeLast()
            closePendingRow(&builder)
            let nodes = tableNodes(builder.rows)
            guard !nodes.isEmpty else { continue }
            if !tables.isEmpty {
                tables[tables.count - 1].blocks.append(Block(kind: .table, nodes: nodes))
            } else {
                blocks.append(Block(kind: .table, nodes: nodes))
            }
        }
    }

    /// Close a row that content was still being added to when its table ended —
    /// a truncated document, or a producer that left off the final `\row`.
    mutating func closePendingRow(_ builder: inout TableBuilder) {
        if !builder.blocks.isEmpty {
            builder.cells.append(Cell(blocks: builder.blocks,
                                      align: builder.blocks.compactMap(\.alignment).first))
            builder.blocks = []
        }
        guard !builder.cells.isEmpty else { return }
        builder.rows.append(resolveRow(&builder))
        builder.cells = []
    }

    mutating func endCell(depth: Int) {
        // A nested table inside this cell ends with the cell.
        collapseTables(below: depth)
        let index = table(at: depth)
        flushBytes()
        flushRun()
        let items = inline
        let marker = listMarker
        inline = []
        listMarker = nil
        // The text before `\cell` is this cell's last block — but a cell whose
        // content ended with `\par` has nothing left here, and must not pick up
        // an empty paragraph for it.
        if !items.isEmpty || tables[index].blocks.isEmpty {
            tables[index].blocks.append(makeBlock(items, para: group.para, marker: marker))
        }
        let blocks = tables[index].blocks
        tables[index].cells.append(Cell(blocks: blocks, align: blocks.compactMap(\.alignment).first))
        tables[index].blocks = []
    }

    mutating func endRow(depth: Int) {
        collapseTables(below: depth)
        let index = table(at: depth)
        var builder = tables[index]
        closePendingRow(&builder)
        builder.definitions = []
        builder.pending = CellDefinition()
        tables[index] = builder
    }

    /// Turn the row's raw cells into the row the document holds, applying the
    /// merges its definitions describe.
    ///
    /// RTF writes a merged range as one cell per column either way: the extra
    /// ones carry `\clmrg` or `\clvmrg` and exist only to keep the columns
    /// lined up. A document model with `colspan`/`rowspan` wants them gone and
    /// the surviving cell widened — which is also why reading them naively
    /// produced rows with too many cells.
    func resolveRow(_ builder: inout TableBuilder) -> Row {
        var cells: [Cell] = []
        var boundary = builder.leftEdge
        let rowIndex = builder.rows.count
        for (index, raw) in builder.cells.enumerated() {
            let definition = index < builder.definitions.count ? builder.definitions[index] : CellDefinition()
            let width = definition.rightBoundary > boundary ? (definition.rightBoundary - boundary) / 20 : nil
            if definition.rightBoundary > boundary { boundary = definition.rightBoundary }

            if definition.horizontalMerge, var previous = cells.last {
                previous.colspan += 1
                if let width { previous.widths.append(width) }
                // Word leaves these empty, but a producer that puts content in
                // one shouldn't lose it.
                previous.blocks.append(contentsOf: raw.blocks)
                cells[cells.count - 1] = previous
                continue
            }
            if definition.verticalMerge, let anchor = builder.verticalAnchors[definition.rightBoundary],
               anchor.row < builder.rows.count, anchor.cell < builder.rows[anchor.row].cells.count {
                builder.rows[anchor.row].cells[anchor.cell].rowspan += 1
                builder.rows[anchor.row].cells[anchor.cell].blocks.append(contentsOf: raw.blocks)
                continue
            }
            var cell = raw
            cell.widths = width.map { [$0] } ?? []
            cells.append(cell)
            if definition.verticalMergeStart {
                builder.verticalAnchors[definition.rightBoundary] = (rowIndex, cells.count - 1)
            }
        }
        return Row(cells: cells, header: builder.header)
    }

    /// Classify one finished paragraph: list item, heading, code line, or prose.
    func makeBlock(_ items: [Inline], para: ParaProps, marker: String?,
                   numbering: (kind: ListKind?, start: Int?) = (nil, nil)) -> Block {
        if var (kind, checked) = listKind(marker: marker, para: para, numbering: numbering.kind) {
            var items = items
            // Some producers draw the checkbox into the item's text rather than
            // into its `\listtext` ("\u9745 \tab milk"). It's a marker either
            // way, and it is not part of what the line says.
            if schema.nodes["taskItem"] != nil, let stripped = strippingCheckboxPrefix(items) {
                items = stripped.items
                kind = .task
                checked = stripped.checked
            }
            return Block(kind: .listItem, inline: items, listKind: kind,
                         level: listLevel(para: para), checked: checked,
                         start: kind == .ordered
                             ? (listLevelDefinition(para)?.start ?? numbering.start) : nil,
                         alignment: para.alignment)
        }
        if let level = headingLevel(para) {
            return Block(kind: .heading, inline: items, headingLevel: level, alignment: para.alignment)
        }
        if config.monospaceAsCode, schema.nodes["codeBlock"] != nil, isAllMonospace(items) {
            return Block(kind: .code, inline: items, alignment: para.alignment)
        }
        return Block(kind: .paragraph, inline: items, alignment: para.alignment)
    }

    /// What kind of list this paragraph belongs to, if any.
    ///
    /// Three sources, in order of how much they actually know:
    ///
    /// 1. A checkbox in the drawn marker or in the level's `\leveltext`. RTF
    ///    has no checklist, so the glyph *is* the statement — and only the
    ///    per-paragraph marker can say whether this one is ticked.
    /// 2. The `\listtable` definition this paragraph's `\ls` names, which is
    ///    the format's own account of the level: `\levelnfc23` is a bullet,
    ///    every other code numbers.
    /// 3. The drawn `\listtext` marker, for the producers that ship no list
    ///    table (TextEdit's older output, RTF written by hand). A bare `\ls`
    ///    with neither reads as a bullet, which is the safe guess.
    func listKind(marker: String?, para: ParaProps, numbering: ListKind? = nil) -> (ListKind, Bool)? {
        let text = (marker ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let definition = listLevelDefinition(para)
        if definition == nil, let kind = numbering {
            if schema.nodes["taskItem"] != nil, let checked = checkboxMarker(text) { return (.task, checked) }
            return (kind, false)
        }
        if schema.nodes["taskItem"] != nil {
            if let checked = checkboxMarker(text) { return (.task, checked) }
            if let template = definition?.level.text, checkboxMarker(template) != nil {
                return (.task, checkboxMarker(text) ?? false)
            }
        }
        if let format = definition?.level.numberFormat {
            return (isBulletFormat(format) ? .bullet : .ordered, false)
        }
        if !text.isEmpty {
            if text.contains(where: { $0.isNumber || ($0.isLetter && $0.isASCII) }),
               text.contains(where: { $0 == "." || $0 == ")" }) {
                return (.ordered, false)
            }
            return (.bullet, false)
        }
        if definition != nil { return (.bullet, false) }
        if let id = para.listID, id > 0 { return (.bullet, false) }
        return nil
    }

    /// `\levelnfc`: 23 is "bullet" and 255 is "no number"; 0–22 are the
    /// numbering formats (arabic, roman, lettered, ordinal, …), all of which
    /// this document model spells as one ordered list.
    func isBulletFormat(_ format: Int) -> Bool { format == 23 || format == 255 }

    /// A list item whose text begins with a checkbox glyph, with the glyph (and
    /// the tab or space that separates it) removed. Nil when it doesn't.
    func strippingCheckboxPrefix(_ items: [Inline]) -> (items: [Inline], checked: Bool)? {
        guard case let .text(text, style) = items.first else { return nil }
        var rest = Substring(text).drop(while: { $0 == " " })
        guard let glyph = rest.first, let checked = checkboxMarker(String(glyph)) else { return nil }
        rest = rest.dropFirst().drop(while: { $0 == "\t" || $0 == " " })
        var out = items
        if rest.isEmpty {
            out.removeFirst()
        } else {
            out[0] = .text(String(rest), style)
        }
        return (out, checked)
    }

    func checkboxMarker(_ text: String) -> Bool? {
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\u{2610}": return false                                 // ☐
            case "\u{2611}", "\u{2612}", "\u{2713}", "\u{2714}": return true // ☑ ☒ ✓ ✔
            default: continue
            }
        }
        return nil
    }

    /// Nesting depth. `\ilvl` states it outright; without one, the left indent
    /// does — producers step it by half an inch (720 twips) per level.
    func listLevel(para: ParaProps) -> Int {
        if let level = para.level, level >= 0 { return min(level, 16) }
        guard para.leftIndent > 0 else { return 0 }
        return min(max(0, para.leftIndent / 720 - 1), 16)
    }

    /// A heading, if the paragraph says so. Word states it with
    /// `\outlinelevel`; everyone states it by naming a stylesheet entry.
    func headingLevel(_ para: ParaProps) -> Int? {
        guard schema.nodes["heading"] != nil else { return nil }
        if let outline = para.outline, (0...8).contains(outline) { return min(outline + 1, 6) }
        guard let index = para.style, let name = styleNames[index] else { return nil }
        let lower = name.lowercased()
        if lower == "title" { return 1 }
        for prefix in ["heading", "überschrift", "titre", "h"] where lower.hasPrefix(prefix) {
            let rest = lower.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            if let level = Int(rest), (1...6).contains(level) { return level }
        }
        return nil
    }

    func isMonospace(_ font: Int?) -> Bool {
        guard let font else { return false }
        return monospaceFonts.contains(font)
    }

    func isAllMonospace(_ items: [Inline]) -> Bool {
        guard !items.isEmpty else { return false }
        return items.allSatisfy {
            if case let .text(_, style) = $0 { return isMonospace(style.font) }
            return false
        }
    }

    // MARK: - Node building

    func marks(for style: Style, inCodeBlock: Bool) -> [Mark] {
        guard !inCodeBlock else { return [] }
        var marks: [Mark] = []
        func add(_ name: String, _ attrs: Attrs = [:]) {
            guard schema.marks[name] != nil else { return }
            marks.append(schema.mark(name, attrs))
        }
        if style.bold { add("bold") }
        if style.italic { add("italic") }
        if style.underline { add("underline") }
        if style.strike { add("strike") }
        if style.superscript { add("superscript") }
        if style.subscripted { add("subscript") }
        if config.monospaceAsCode, isMonospace(style.font) { add("code") }
        if let index = style.color, let hex = colors[index] { add("textColor", ["color": .string(hex)]) }
        if let index = style.background, let hex = colors[index] {
            if schema.marks["backgroundColor"] != nil {
                add("backgroundColor", ["color": .string(hex)])
            } else {
                add("highlight", ["color": .string(hex)])
            }
        }
        if let link = style.link, let href = sanitizeURL(link, for: .link) {
            add("link", ["href": .string(href)])
        }
        return marks
    }

    func inlineNodes(_ items: [Inline], inCodeBlock: Bool = false) -> [Node] {
        var out: [Node] = []
        for item in items {
            switch item {
            case let .text(text, style):
                guard !text.isEmpty else { continue }
                out.append(schema.text(text, marks(for: style, inCodeBlock: inCodeBlock)))
            case let .node(node):
                out.append(node)
            }
        }
        return out
    }

    func paragraphNode(_ items: [Inline]) -> Node? {
        guard let type = schema.nodes["paragraph"] else { return nil }
        let nodes = inlineNodes(items)
        return type.createAndFill([:], content: Fragment.from(nodes))
    }

    func plainText(_ items: [Inline]) -> String {
        var text = ""
        for item in items {
            switch item {
            case let .text(t, _): text += t
            case let .node(node): text += node.type.name == "hardBreak" ? "\n" : node.textContent
            }
        }
        return text
    }

    mutating func buildDocument() throws -> Node {
        var out = assembleBlocks(blocks)
        // Producers end a document with `\par`, which describes a paragraph
        // mark, not an empty paragraph after it.
        while let last = out.last, last.type.name == "paragraph", last.childCount == 0 { out.removeLast() }
        // Footnote text is written where it is referenced; the definitions are
        // blocks of their own, and belong at the end.
        out.append(contentsOf: footnoteDefinitions)

        var content = fitContent(out, into: schema.topNodeType, schema: schema)
        if content.isEmpty, let empty = schema.nodes["paragraph"]?.createAndFill() { content = [empty] }
        let doc = try schema.node(schema.topNodeType, [:], content: Fragment.from(content))
        do {
            try doc.check()
        } catch {
            throw RTFParseError.invalidDocument(String(describing: error))
        }
        return doc
    }

    /// Turn classified blocks into nodes: runs of list items become lists, runs
    /// of code lines become one code block, and the rest map one to one.
    ///
    /// The document and every table cell go through this, so a cell holds real
    /// lists and headings rather than a flat run of paragraphs.
    func assembleBlocks(_ source: [Block]) -> [Node] {
        var out: [Node] = []
        var index = 0
        while index < source.count {
            let block = source[index]
            switch block.kind {
            case .table:
                out.append(contentsOf: block.nodes)
                index += 1
            case .code:
                // Consecutive monospaced paragraphs are one block of code, the
                // way they read on the page they came from.
                var lines: [String] = []
                while index < source.count, source[index].kind == .code {
                    lines.append(plainText(source[index].inline))
                    index += 1
                }
                let text = lines.joined(separator: "\n")
                if let type = schema.nodes["codeBlock"],
                   let node = type.createAndFill([:], content: Fragment.from(text.isEmpty ? [] : [schema.text(text)])) {
                    out.append(node)
                } else {
                    for line in lines {
                        if let node = paragraphNode(line.isEmpty ? [] : [.text(line, Style())]) { out.append(node) }
                    }
                }
            case .listItem:
                index = appendLists(source, from: index, into: &out)
            case .heading:
                if let type = schema.nodes["heading"],
                   let node = type.createAndFill(["level": .int(block.headingLevel)],
                                                 content: Fragment.from(inlineNodes(block.inline))) {
                    out.append(node)
                } else if let node = paragraphNode(block.inline) {
                    out.append(node)
                }
                index += 1
            case .paragraph:
                if let node = paragraphNode(block.inline) { out.append(node) }
                index += 1
            }
        }
        return out
    }

    func tableNodes(_ rows: [Row]) -> [Node] {
        /// No table in this schema, or one that can't be built: the cells'
        /// content is still the document's content.
        func contentOnly() -> [Node] { rows.flatMap { $0.cells.flatMap { assembleBlocks($0.blocks) } } }

        guard !rows.isEmpty else { return [] }
        guard let tableType = schema.nodes["table"], let rowType = schema.nodes["tableRow"],
              let cellType = schema.nodes["tableCell"] else { return contentOnly() }
        let headerType = schema.nodes["tableHeader"] ?? cellType
        var rowNodes: [Node] = []
        for row in rows {
            let type = row.header ? headerType : cellType
            let cells = row.cells.compactMap {
                type.createAndFill(cellAttrs($0, type: type), content: Fragment.from(assembleBlocks($0.blocks)))
            }
            guard !cells.isEmpty, let node = rowType.createAndFill([:], content: Fragment.from(cells)) else { continue }
            rowNodes.append(node)
        }
        guard !rowNodes.isEmpty, let table = tableType.createAndFill([:], content: Fragment.from(rowNodes)) else {
            return contentOnly()
        }
        return [table]
    }

    /// A cell's span and column widths, for the attributes the schema declares.
    /// A schema without `colspan`/`rowspan`/`colwidth` simply gets none of them —
    /// the cell is still there, just not merged or sized.
    func cellAttrs(_ cell: Cell, type: NodeType) -> Attrs {
        var attrs: Attrs = [:]
        if cell.colspan > 1, type.defaultAttrs["colspan"] != nil { attrs["colspan"] = .int(cell.colspan) }
        if cell.rowspan > 1, type.defaultAttrs["rowspan"] != nil { attrs["rowspan"] = .int(cell.rowspan) }
        if let align = cell.align, type.defaultAttrs["align"] != nil { attrs["align"] = .string(align) }
        if type.defaultAttrs["colwidth"] != nil, cell.widths.count == cell.colspan,
           cell.widths.allSatisfy({ $0 > 0 }) {
            attrs["colwidth"] = .array(cell.widths.map { .int($0) })
        }
        return attrs
    }

    /// Consume the run of consecutive list paragraphs starting at `start`,
    /// building (possibly nested, possibly type-switching) lists onto `out`.
    /// Returns the index of the first paragraph that isn't a list item.
    func appendLists(_ source: [Block], from start: Int, into out: inout [Node]) -> Int {
        struct Level {
            var kind: ListKind
            var depth: Int
            var items: [Node]
            var start: Int?
        }
        var stack: [Level] = []

        /// The attributes of the list a level opens. An ordered list that
        /// starts somewhere other than 1 says so, when the schema has somewhere
        /// to put it.
        func listAttrs(_ kind: ListKind, start: Int?) -> Attrs {
            guard kind == .ordered, let start,
                  schema.nodes["orderedList"]?.defaultAttrs["order"] != nil else { return [:] }
            return ["order": .int(start)]
        }

        func listName(_ kind: ListKind) -> String {
            switch kind {
            case .ordered: return "orderedList"
            case .task: return "taskList"
            case .bullet: return "bulletList"
            }
        }

        func pop() {
            guard let level = stack.popLast(),
                  let list = schema.nodes[listName(level.kind)]?
                      .createAndFill(listAttrs(level.kind, start: level.start),
                                     content: Fragment.from(level.items))
            else { return }
            if let parent = stack.last, let lastItem = parent.items.last {
                let kids = (0..<lastItem.childCount).map { lastItem.child($0) } + [list]
                stack[stack.count - 1].items[parent.items.count - 1] = lastItem.copy(content: Fragment.from(kids))
            } else {
                out.append(list)
            }
        }

        var index = start
        while index < source.count, source[index].kind == .listItem {
            let block = source[index]
            index += 1
            let itemName = block.listKind == .task ? "taskItem" : "listItem"
            guard let paragraph = paragraphNode(block.inline),
                  let item = schema.nodes[itemName]?.createAndFill(
                      block.listKind == .task ? ["checked": .bool(block.checked)] : [:],
                      content: Fragment.from([paragraph]))
            else {
                // The schema can't express this list — flush and degrade.
                while !stack.isEmpty { pop() }
                if let node = paragraphNode(block.inline) { out.append(node) }
                continue
            }
            while let top = stack.last, top.depth > block.level { pop() }
            if let top = stack.last, top.depth == block.level, top.kind != block.listKind { pop() }
            if let top = stack.last, top.depth == block.level, top.kind == block.listKind {
                stack[stack.count - 1].items.append(item)
            } else {
                stack.append(Level(kind: block.listKind, depth: block.level, items: [item],
                                   start: block.start))
            }
        }
        while !stack.isEmpty { pop() }
        return index
    }
}

// MARK: - Scalar helpers

private func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
    (scalar.value >= 65 && scalar.value <= 90) || (scalar.value >= 97 && scalar.value <= 122)
}

private func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
    scalar.value >= 48 && scalar.value <= 57
}

private func hexValue(_ scalar: Unicode.Scalar) -> Int? {
    switch scalar.value {
    case 48...57: return Int(scalar.value - 48)
    case 97...102: return Int(scalar.value - 87)
    case 65...70: return Int(scalar.value - 55)
    default: return nil
    }
}

private func hexColor(_ r: Int, _ g: Int, _ b: Int) -> String {
    let digits = "0123456789abcdef"
    var out = "#"
    for component in [r, g, b] {
        let value = min(max(component, 0), 255)
        out.append(digits[digits.index(digits.startIndex, offsetBy: value / 16)])
        out.append(digits[digits.index(digits.startIndex, offsetBy: value % 16)])
    }
    return out
}

/// `\fcharset` → the Windows code page it names. The Symbol charset is not a
/// code page at all and is handled separately.
private let symbolCharset = 2
private let charsetCodePages: [Int: Int] = [
    0: 1252, 1: 1252, 77: 10000, 128: 932, 129: 949, 130: 1361, 134: 936, 136: 950,
    161: 1253, 162: 1254, 163: 1258, 177: 1255, 178: 1256, 186: 1257,
    204: 1251, 222: 874, 238: 1250, 255: 850,
]

/// The encoding for a code page, or nil when this platform can't name one.
///
/// CoreFoundation knows every Windows code page, including the multi-byte ones
/// (Shift-JIS, GBK, Big5), which is why they're looked up rather than tabulated.
private func stringEncoding(forCodePage page: Int) -> String.Encoding? {
    guard page > 0, page <= UInt32.max else { return nil }
    if page == 10000 { return .macOSRoman }
    let cfEncoding = CFStringConvertWindowsCodepageToEncoding(UInt32(page))
    guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
    let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
    guard nsEncoding != kCFStringEncodingInvalidId else { return nil }
    return String.Encoding(rawValue: nsEncoding)
}

/// Destinations recognized by name (as opposed to swallowed by `\*`).
///
/// File scope, and built once: these are consulted for every control word in
/// the document, and rebuilding them per lookup dominated parsing.
private let rtfDestinations: [String: RTFReader.Destination] = [
    "fonttbl": .fontTable, "colortbl": .colorTable, "stylesheet": .styleSheet,
    "fldinst": .fieldInstruction, "listtext": .listText, "pntext": .listText,
    "pict": .picture,
    // Content-bearing destinations we deliberately drop.
    "info": .skip, "author": .skip, "operator": .skip, "title": .skip,
    "subject": .skip, "keywords": .skip, "comment": .skip, "doccomm": .skip,
    "creatim": .skip, "revtim": .skip, "printim": .skip, "buptim": .skip,
    "header": .skip, "headerl": .skip, "headerr": .skip, "headerf": .skip,
    "footer": .skip, "footerl": .skip, "footerr": .skip, "footerf": .skip,
    "ftnsep": .skip, "ftnsepc": .skip, "ftncn": .skip,
    "aftnsep": .skip, "aftnsepc": .skip, "aftncn": .skip,
    "filetbl": .skip, "colorschememapping": .skip, "latentstyles": .skip,
    "themedata": .skip, "datastore": .skip, "docvar": .skip,
    "listtable": .listTable, "listoverridetable": .listOverrideTable, "revtbl": .skip,
    "nesttableprops": .nestedTableProperties,
    // Word writes every nested table twice: once nested, once flattened
    // for readers that can't nest. Keeping both would double the text.
    "nonesttables": .skip,
    "xe": .skip, "tc": .skip, "bkmkstart": .skip, "bkmkend": .skip,
    // Word writes the same image twice: once as a shape, once as a
    // plain `\pict` fallback. Reading the shape wrapper transparently
    // and dropping the duplicate keeps exactly one image.
    "nonshppict": .skip,
]

/// `\*\` destinations we do read rather than drop. File scope for the same
/// reason as the map above.
private let rtfParsedIgnorableDestinations: Set<String> = [
    "fldinst", "listtext", "pntext", "shppict", "pict", "listtable", "listoverridetable",
    "nesttableprops", "pn",
]

public extension Node {
    /// Read a document from RTF bytes — what the pasteboard and `.rtf` files
    /// carry — against the given schema.
    static func fromRTF(_ data: Data, schema: Schema, config: RTFConfig = .default) throws -> Node {
        try RTFParser.parse(data, schema: schema, config: config)
    }

    /// Read a document from RTF that has already been decoded to a `String`.
    static func fromRTF(_ rtf: String, schema: Schema, config: RTFConfig = .default) throws -> Node {
        try RTFParser.parse(rtf, schema: schema, config: config)
    }
}

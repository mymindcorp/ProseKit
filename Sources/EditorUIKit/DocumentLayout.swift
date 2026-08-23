#if canImport(UIKit)
import UIKit
import CoreText
import DocumentModel

/// One laid-out line within a text block.
struct LineLayout {
    let ctLine: CTLine
    let baselineOrigin: CGPoint   // in view coordinates
    let stringRange: NSRange      // range into the block's attributed string
    let height: CGFloat
    let ascent: CGFloat
}

/// Maps document positions to attributed-string indices within a block. Text
/// runs map 1:1; inline atoms (image/wikiLink) take one document position but
/// may display several glyphs.
struct Segment {
    var docStart: Int
    var docLen: Int
    var attrStart: Int
    var attrLen: Int
    /// The source text for a text run (nil for inline atoms). Lets us convert
    /// between grapheme-based document offsets and UTF-16 attributed indices.
    var text: String?
}

/// A document position (relative to whatever the segments are relative to) as an
/// index into the attributed string those segments describe. Free-standing
/// because it is needed both on a laid-out `TextBlock` and while typesetting
/// one, before there is a block to ask.
func attrIndex(forDocPos pos: Int, in segments: [Segment]) -> Int {
    for seg in segments where pos >= seg.docStart && pos <= seg.docStart + seg.docLen {
        if let text = seg.text {
            // Grapheme offset → UTF-16 index within the run.
            let graphemeOffset = pos - seg.docStart
            // Every grapheme is one UTF-16 unit exactly when the two counts
            // agree (each is at least one, so equal totals force all ones),
            // and then the mapping is the identity. That is ordinary text,
            // and it is worth checking: this runs on the scroll path, where
            // UIKit asks for character rects as you drag, and walking the
            // run to build a prefix string made a ~500-word paragraph cost
            // thousands of graphemes and an allocation per call.
            if seg.docLen == seg.attrLen { return seg.attrStart + graphemeOffset }
            let idx = text.index(text.startIndex, offsetBy: graphemeOffset,
                                 limitedBy: text.endIndex) ?? text.endIndex
            return seg.attrStart + text.utf16.distance(from: text.startIndex, to: idx)
        }
        return pos <= seg.docStart ? seg.attrStart : seg.attrStart + seg.attrLen
    }
    return segments.last.map { $0.attrStart + $0.attrLen } ?? 0
}

/// A laid-out text block (paragraph, heading, code block, list-item paragraph).
struct TextBlock {
    let contentStart: Int          // doc position of the first inline position
    let contentEnd: Int            // doc position after the last inline position
    let frame: CGRect              // text frame in view coordinates
    let lines: [LineLayout]
    let segments: [Segment]
    let attributed: NSAttributedString

    func attrIndex(forDocPos pos: Int) -> Int { EditorUIKit.attrIndex(forDocPos: pos, in: segments) }

    func docPos(forAttrIndex index: Int) -> Int {
        for seg in segments where index >= seg.attrStart && index <= seg.attrStart + seg.attrLen {
            if let text = seg.text {
                // UTF-16 index → grapheme offset within the run. Identity when
                // the counts agree, as in `attrIndex(forDocPos:)`.
                let utf16Offset = index - seg.attrStart
                if seg.docLen == seg.attrLen { return seg.docStart + utf16Offset }
                let ns = text as NSString
                let prefix = ns.substring(to: min(utf16Offset, ns.length))
                // Clamped: an index *inside* a grapheme cluster cuts the run
                // mid-sequence, and the broken tail counts as a cluster of its
                // own — so a split inside a ZWJ emoji counts one more grapheme
                // than the whole run has, and the position lands past the end of
                // the block. CoreText only ever hands back cluster boundaries,
                // but the arithmetic ones (a line's last index, say) can land
                // anywhere.
                return seg.docStart + min(prefix.count, seg.docLen)
            }
            return index < seg.attrStart + (seg.attrLen + 1) / 2 ? seg.docStart : seg.docStart + seg.docLen
        }
        return contentEnd
    }
}

/// A wiki-link chip's typeset extent, in a block's LOCAL terms: the run it
/// occupies in the attributed string, plus the pill and glyph to draw over it.
/// Geometry is relative to the run's start x and the line's baseline, so a
/// cached block can be re-emitted wherever it next sits.
struct WikiLinkChip {
    let attrStart: Int
    /// Exclusive — the index just past the label (and its trailing padding).
    let attrEnd: Int
    /// nil = no pill; the glyph (if any) is still drawn.
    let background: UIColor?
    let cornerRadius: CGFloat
    /// The pill's top edge, relative to the baseline (negative = above it).
    let top: CGFloat
    let height: CGFloat
    /// Already tinted with the chip's colour; nil = label only.
    let icon: UIImage?
    /// The glyph's box, relative to the run's start x and the baseline.
    let iconRect: CGRect
}

/// The `[[…` a reader is part-way through typing: still ordinary text in the
/// document, and set apart from the prose around it until the input rule turns
/// it into a chip. Handed to the layout by the editable view, which is the only
/// one that has a cursor and so the only one that can have an open trigger.
struct WikiLinkTrigger: Equatable {
    /// The document range to style — the `[[` alone, or the query with it.
    let range: Range<Int>
    /// The cursor: where the closing brackets would be typed.
    let cursor: Int
    /// Closing brackets to draw after the cursor without putting them in the
    /// document — `"]]"`, or `" ]]"` to mirror a space typed after the opening.
    /// Nil draws none.
    let closing: String?
}

/// A non-text drawing primitive (rule, list marker, quote bar, box).
enum DecorationItem {
    case fill(CGRect, UIColor)
    case text(String, CGPoint, [NSAttributedString.Key: Any])
    case stroke(CGRect, UIColor, CGFloat)
    case image(UIImage, CGRect)
    /// A small glyph drawn as-is (a wiki-link chip's icon). Unlike `image` it
    /// never takes the theme's photo corner radius — rounding a 1-em square by
    /// a radius chosen for photographs turns it into a circle.
    case icon(UIImage, CGRect)
    /// A typeset formula, drawn by its renderer at the rect's top-left.
    case math(MathRendering, CGRect)
    case roundedFill(CGRect, UIColor, CGFloat)
    case roundedStroke(CGRect, UIColor, CGFloat, CGFloat)
    case checkmark(CGRect, UIColor, CGFloat)
}

/// A text block typeset in local coordinates (block top at y = 0), cached and
/// reused across layouts so unchanged blocks don't re-run CoreText line breaking
/// — the expensive per-keystroke cost on large documents.
///
/// This is cached by (node, width) and reused wherever that node next sits, so
/// **nothing here may be absolute** — not a y coordinate, and not a document
/// position. `layoutTextBlock` rebases all of it onto the block's actual origin
/// and content start. Deleting a list item is what punishes a field that forgets
/// this: every item below it keeps its exact paragraph node, so it hits this
/// cache, but has moved to a lower document position.
struct LocalTextBlock {
    let lines: [LineLayout]   // baselineOrigin relative to (0, 0)
    /// `docStart` relative to the block's content start.
    let segments: [Segment]
    let attributed: NSAttributedString
    let height: CGFloat
    let imageAtoms: [(attrIndex: Int, image: UIImage, size: CGSize)]
    /// Inline formulas, drawn at their run position once line breaking has
    /// placed them. Unlike an image atom these carry their own baseline, so the
    /// formula lines up with the text rather than sitting on top of it.
    /// `docOffset` is relative to the block's content start.
    let mathAtoms: [(attrIndex: Int, docOffset: Int, rendering: MathRendering)]
    /// Highlight-mark and inline-code backgrounds, as ranges relative to the
    /// block's content start. Carried here rather than emitted while typesetting
    /// because a block served from the cache is never typeset again — and would
    /// otherwise lose its backgrounds entirely.
    let highlights: [(from: Int, to: Int, color: UIColor)]
    let codeBackgrounds: [(from: Int, to: Int, color: UIColor)]
    /// Wiki-link chips, positioned once line breaking has placed their runs.
    let wikiLinkChips: [WikiLinkChip]
}

/// Caches typeset blocks by (node, width). Mark-and-sweep keeps it bounded to
/// the blocks used in the most recent layout.
final class TextBlockLayoutCache {
    /// Identity-keyed: the content array's buffer address stands in for the
    /// (expensive-to-hash) subtree, so lookups are O(1) instead of O(text).
    /// Sound because the entry's value retains the node — a live entry's
    /// buffer can't be freed and its address recycled. Type/attrs/marks still
    /// participate: they affect layout without changing the content buffer.
    private struct Key: Hashable {
        let type: ObjectIdentifier
        let attrs: Attrs
        let marks: [Mark]
        let buffer: UInt
        let width: CGFloat
        /// The alignment inherited from an enclosing table cell, for the same
        /// reason as `checked` below: the paragraph node is identical whichever
        /// way its cell is aligned, so without this a re-aligned column would
        /// reuse blocks typeset the old way.
        let align: String?
        /// Styling inherited from an enclosing node rather than from the block
        /// itself: a paragraph is the *same* node whether its task item is
        /// checked or not, so without this a toggle would reuse the stale
        /// (unstruck) typeset. Theme changes drop the cache wholesale, so this
        /// only has to capture the inherited state, not the styling it implies.
        let checked: Bool
    }
    private struct Entry {
        let node: Node // retains the keyed buffer
        let block: LocalTextBlock
        var generation: Int
    }
    private var entries: [Key: Entry] = [:]
    private var generation = 0
    /// The theme the cached blocks were typeset with. Colors and fonts are baked
    /// into each block's attributed string (not part of `Key`), so a theme change
    /// must drop the cache — otherwise a new theme reuses stale-styled blocks.
    private(set) var lastTheme: DocumentTheme?
    private(set) var lastFootnoteOrder: [String: Int]?

    var debugEntryCount: Int { entries.count }

    /// Drop all cached blocks when the theme changes (e.g. the user edits colors,
    /// fonts, or spacing live), so they're re-typeset with the new styling.
    func syncTheme(_ theme: DocumentTheme) {
        if let lastTheme, lastTheme != theme { entries.removeAll() }
        lastTheme = theme
    }

    /// A footnote reference draws the number it has in the document, not
    /// anything the node itself carries — so when the numbering changes, blocks
    /// keyed on unchanged nodes are showing stale numbers and have to go. For a
    /// document without footnotes both sides stay empty and nothing is dropped.
    func syncFootnoteOrder(_ order: [String: Int]) {
        if let lastFootnoteOrder, lastFootnoteOrder != order { entries.removeAll() }
        lastFootnoteOrder = order
    }

    private static func key(_ node: Node, _ width: CGFloat, _ checked: Bool, _ align: String?) -> Key {
        let buffer = unsafe node.content.content.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
        return Key(type: ObjectIdentifier(node.type), attrs: node.attrs, marks: node.marks,
                   buffer: buffer, width: width, align: align, checked: checked)
    }

    func lookup(_ node: Node, width: CGFloat, checked: Bool, align: String?) -> LocalTextBlock? {
        let key = Self.key(node, width, checked, align)
        guard var entry = entries[key] else { return nil }
        entry.generation = generation
        entries[key] = entry
        return entry.block
    }
    func store(_ node: Node, width: CGFloat, checked: Bool, align: String?, _ block: LocalTextBlock) {
        entries[Self.key(node, width, checked, align)] = Entry(node: node, block: block, generation: generation)
    }
    func beginPass() { generation += 1 }
    /// Drop everything (e.g. when the syntax highlighter changes).
    func clear() { entries.removeAll() }
    /// Drop the blocks whose node matches — the paragraphs holding an inline
    /// image whose bytes have just arrived, say. The block is keyed by its node
    /// and width, neither of which changed when the bytes turned up, so without
    /// this the placeholder is what comes back out of the cache. Targeted
    /// because the alternative is re-typesetting every paragraph on screen for
    /// each picture that loads.
    func evict(where matches: (Node) -> Bool) {
        entries = entries.filter { !matches($0.value.node) }
    }
    /// Eviction is deliberately rare: a keystroke pass touches one block and
    /// must not churn the rest of the cache (incremental layout reuses whole
    /// entries without consulting it, so "unused this pass" means nothing).
    /// Only when the cache outgrows a generous cap, drop the older half.
    func endPass() {
        guard entries.count > 4096 else { return }
        let generations = entries.values.map(\.generation).sorted()
        let threshold = generations[generations.count / 2]
        entries = entries.filter { $0.value.generation >= threshold }
    }
}

/// Lays out a document into text blocks + decorations using CoreText, and
/// answers caret/hit-test queries.
final class DocumentLayout {
    let theme: DocumentTheme
    let width: CGFloat
    private(set) var height: CGFloat = 0
    private(set) var blocks: [TextBlock] = []
    private(set) var decorations: [DecorationItem] = []
    /// Tappable task-item checkboxes: their hit rect, the task item's document
    /// position, and current checked state.
    private(set) var checkboxes: [(rect: CGRect, pos: Int, checked: Bool)] = []
    /// Whether the block being laid out sits inside a *checked* task item, so it
    /// is typeset in the theme's checked style. Set for the duration of that
    /// item's subtree by `layoutTaskList`, and part of the block cache's key —
    /// the same paragraph node can appear checked or not.
    private var inCheckedItem = false
    /// The alignment of the table cell being laid out, if any. Inherited by the
    /// blocks inside it the way `inCheckedItem` is.
    private var inCellAlignment: String?
    /// Tappable details disclosure triangles: their hit rect, the `details`
    /// node's document position, and whether it is currently open.
    private(set) var disclosures: [(rect: CGRect, pos: Int, open: Bool)] = []
    /// Drawn rects of `inlineMath` / `blockMath` nodes, for tap activation.
    private(set) var mathTargets: [(rect: CGRect, pos: Int)] = []
    /// Highlight-mark ranges (document positions) and their colors, drawn as a
    /// background behind the text (CoreText ignores `.backgroundColor`).
    private(set) var highlights: [(from: Int, to: Int, color: UIColor)] = []
    /// Inline-code background ranges + color, painted as a rounded pill behind the
    /// run. Kept separate from `highlights` so the (demo) drying-ink renderer,
    /// which consumes `highlights`, never textures a code pill.
    private(set) var codeBackgrounds: [(from: Int, to: Int, color: UIColor)] = []
    /// Which number each footnote label shows as, in reading order. A block
    /// on its own can't know its place, so the whole document is numbered once
    /// up front.
    private var footnoteOrder: [String: Int] = [:]
    /// Laid-out tables, for column-border hit-testing and resize.
    struct TableInfo {
        let tablePos: Int
        let originX: CGFloat
        let widths: [CGFloat]
        let top: CGFloat
        let bottom: CGFloat
        /// X of the border to the right of column `c` (0-based).
        func borderX(after c: Int) -> CGFloat { originX + widths[0...c].reduce(0, +) }
    }
    private(set) var tables: [TableInfo] = []
    /// Image sources referenced by the document that the provider didn't have
    /// cached — the view loads these and rebuilds.
    /// Image nodes whose drawable couldn't be resolved from a cache — the host
    /// resolves each (it sees all the node's attrs, not just `src`) and loads it.
    /// Unlike every other output here this is a work list, not something keyed
    /// by position — so `TopEntry` doesn't carry it and reused entries don't
    /// re-emit it. That is safe because `loadPendingImages` is idempotent and a
    /// finished load clears the block cache, which re-emits from scratch. A load
    /// that *fails* is not retried while its block stays cached.
    private(set) var pendingImages: [Node] = []
    /// Resolves an image node to a drawable image (host data hook, cache, or a
    /// decoded `data:` URL). Returns nil to draw a placeholder.
    private let imageProvider: (Node) -> UIImage?
    private let blockCache: TextBlockLayoutCache?
    /// Optional host hook to color code-block text (nil = plain monospaced).
    private let syntaxHighlighter: SyntaxHighlighter?
    /// Optional host hook returning a badge label (e.g. detected language) for a
    /// code block, given its text and `language` attribute. Nil = no badge.
    private let codeLanguageLabel: ((String, String?) -> String?)?
    /// Optional host hook to typeset `inlineMath` / `blockMath` nodes. Nil (or a
    /// nil return) falls back to drawing the raw LaTeX source.
    private let mathRenderer: MathRenderer?
    /// Optional host hook supplying a wiki-link atom's leading glyph. Nil (or a
    /// nil return) draws the label alone.
    private let wikiLinkIcon: WikiLinkIconProvider?
    /// The `[[` currently being typed, when the editable view has one open and
    /// the theme actually sets it apart. A block holding it is styled per
    /// layout and never cached: it is state, not content.
    private let wikiLinkTrigger: WikiLinkTrigger?

    /// One top-level child's fully-positioned output. Kept so an edit can reuse
    /// the unchanged blocks (prefix as-is, suffix shifted) instead of re-laying
    /// out the whole document.
    struct TopEntry {
        let node: Node
        let docStart: Int
        let topY: CGFloat
        let height: CGFloat
        let blocks: [TextBlock]
        let decorations: [DecorationItem]
        let checkboxes: [(rect: CGRect, pos: Int, checked: Bool)]
        var disclosures: [(rect: CGRect, pos: Int, open: Bool)] = []
        var mathTargets: [(rect: CGRect, pos: Int)] = []
        let highlights: [(from: Int, to: Int, color: UIColor)]
        var codeBackgrounds: [(from: Int, to: Int, color: UIColor)] = []
        let tables: [TableInfo]
        /// When true this child's height is an estimate and it hasn't been
        /// typeset — it carries no blocks/decorations. Realized on demand when it
        /// scrolls near the viewport.
        var estimated: Bool = false
    }
    private(set) var entries: [TopEntry] = []
    /// Below this child count, the whole document is always laid out eagerly
    /// (estimation only pays off for very large documents).
    private static let lazyThreshold = 60

    init(doc: Node, width: CGFloat, theme: DocumentTheme, imageProvider: @escaping (Node) -> UIImage? = { _ in nil },
         blockCache: TextBlockLayoutCache? = nil, previous: DocumentLayout? = nil,
         realizeWindow: ClosedRange<CGFloat>? = nil, syntaxHighlighter: SyntaxHighlighter? = nil,
         codeLanguageLabel: ((String, String?) -> String?)? = nil,
         mathRenderer: MathRenderer? = nil,
         wikiLinkIcon: WikiLinkIconProvider? = nil,
         wikiLinkTrigger: WikiLinkTrigger? = nil) {
        self.theme = theme
        self.width = width
        self.imageProvider = imageProvider
        self.blockCache = blockCache
        self.syntaxHighlighter = syntaxHighlighter
        self.codeLanguageLabel = codeLanguageLabel
        self.mathRenderer = mathRenderer
        self.wikiLinkIcon = wikiLinkIcon
        self.wikiLinkTrigger = wikiLinkTrigger
        footnoteOrder = Self.footnoteOrdering(doc)
        blockCache?.syncTheme(theme) // drop stale-styled blocks when the theme changes
        blockCache?.syncFootnoteOrder(footnoteOrder)
        blockCache?.beginPass()
        let contentWidth = width - theme.pageInsets.left - theme.pageInsets.right
        let x = theme.pageInsets.left
        // Only reuse a previous layout when it was built with the same theme — its
        // entries bake in the old colors/fonts, so a theme change must re-lay them.
        if let previous, previous.width == width, previous.theme == theme,
           previous.footnoteOrder == footnoteOrder,
           let (front, back) = diff(doc, previous), front + back > 0 {
            // A real edit: reuse the unchanged prefix/suffix, re-lay the middle.
            buildIncremental(doc, previous: previous, front: front, back: back, x: x, width: contentWidth)
        } else if let realizeWindow, doc.childCount > Self.lazyThreshold {
            // Lazy: typeset only children near the viewport, estimate the rest.
            buildLazy(doc, window: realizeWindow, x: x, width: contentWidth)
        } else {
            buildFull(doc, x: x, width: contentWidth)
        }
        blockCache?.endPass()
    }

    // MARK: - Incremental build

    /// Common unchanged top-level children at the front and back of the
    /// document (compared in O(1) each via the Fragment COW fast path).
    private func diff(_ doc: Node, _ previous: DocumentLayout) -> (front: Int, back: Int)? {
        let newCount = doc.childCount
        let prev = previous.entries
        guard prev.count > 0 else { return nil }
        var front = 0
        while front < newCount, front < prev.count, doc.child(front) == prev[front].node { front += 1 }
        var back = 0
        while back < (newCount - front), back < (prev.count - front),
              doc.child(newCount - 1 - back) == prev[prev.count - 1 - back].node { back += 1 }
        // An entry's height starts with the spacing before it, and that spacing
        // is a function of the block *and the one above it*. So the suffix's
        // first entry is only reusable when its predecessor is unchanged too —
        // otherwise it carries the old gap, and everything below it (the caret
        // included) sits a spacing's worth off. Re-lay that one entry.
        if back > 0 {
            let newPrev = newCount - back - 1, oldPrev = prev.count - back - 1
            let samePredecessor = newPrev < 0 && oldPrev < 0
                || newPrev >= 0 && oldPrev >= 0 && doc.child(newPrev) == prev[oldPrev].node
            if !samePredecessor { back -= 1 }
        }
        return (front, back)
    }

    private func buildFull(_ doc: Node, x: CGFloat, width contentWidth: CGFloat) {
        var y = theme.pageInsets.top
        var pos = 0
        for i in 0..<doc.childCount {
            entries.append(layoutTopChild(doc.child(i), docPos: pos, x: x, width: contentWidth, y: &y,
                                          previous: i == 0 ? nil : doc.child(i - 1)))
            pos += doc.child(i).nodeSize
        }
        height = y + theme.pageInsets.bottom
    }

    private func buildIncremental(_ doc: Node, previous: DocumentLayout, front: Int, back: Int, x: CGFloat, width contentWidth: CGFloat) {
        var y = theme.pageInsets.top
        var pos = 0
        // Prefix: unchanged blocks before the edit — positions are identical.
        for j in 0..<front {
            let e = previous.entries[j]
            append(e); entries.append(e)
            y = e.topY + e.height; pos = e.docStart + e.node.nodeSize
        }
        // Middle: the changed children — re-laid out.
        let midEnd = doc.childCount - back
        for i in front..<midEnd {
            entries.append(layoutTopChild(doc.child(i), docPos: pos, x: x, width: contentWidth, y: &y,
                                          previous: i == 0 ? nil : doc.child(i - 1)))
            pos += doc.child(i).nodeSize
        }
        // Suffix: unchanged blocks after the edit — same layout, shifted in y and
        // document position by how much the middle grew/shrank.
        let oldBackStart = previous.entries.count - back
        let dy = back > 0 ? y - previous.entries[oldBackStart].topY : 0
        let dPos = back > 0 ? pos - previous.entries[oldBackStart].docStart : 0
        for j in oldBackStart..<previous.entries.count {
            let e = shiftEntry(previous.entries[j], dPos: dPos, dy: dy)
            append(e); entries.append(e)
            y = e.topY + e.height; pos = e.docStart + e.node.nodeSize
        }
        height = y + theme.pageInsets.bottom
    }

    /// Lay out one top-level child at `y`, returning its positioned output.
    private func layoutTopChild(_ child: Node, docPos: Int, x: CGFloat, width: CGFloat, y: inout CGFloat, previous: Node?) -> TopEntry {
        let topY = y
        let (b0, d0, c0, h0, t0) = (blocks.count, decorations.count, checkboxes.count, highlights.count, tables.count)
        let cb0 = codeBackgrounds.count
        let dc0 = disclosures.count
        let m0 = mathTargets.count
        y += theme.spacing(before: child, after: previous)
        y = layoutBlock(child, docPos: docPos, x: x, width: width, y: y)
        return TopEntry(node: child, docStart: docPos, topY: topY, height: y - topY,
                        blocks: Array(blocks[b0...]), decorations: Array(decorations[d0...]),
                        checkboxes: Array(checkboxes[c0...]), disclosures: Array(disclosures[dc0...]),
                        mathTargets: Array(mathTargets[m0...]),
                        highlights: Array(highlights[h0...]),
                        codeBackgrounds: Array(codeBackgrounds[cb0...]),
                        tables: Array(tables[t0...]))
    }

    private func append(_ e: TopEntry) {
        blocks += e.blocks; decorations += e.decorations; checkboxes += e.checkboxes
        disclosures += e.disclosures; mathTargets += e.mathTargets
        highlights += e.highlights; codeBackgrounds += e.codeBackgrounds; tables += e.tables
    }

    private func shiftEntry(_ e: TopEntry, dPos: Int, dy: CGFloat) -> TopEntry {
        guard dPos != 0 || dy != 0 else { return e }
        // Estimated (off-screen) entries carry no sub-arrays — the common case in
        // a long document. Reuse the (empty) arrays instead of `.map`-ing them,
        // so shifting the suffix past an edit is allocation-free per entry.
        return TopEntry(node: e.node, docStart: e.docStart + dPos, topY: e.topY + dy, height: e.height,
                        blocks: e.blocks.isEmpty ? e.blocks : e.blocks.map { shiftBlock($0, dPos: dPos, dy: dy) },
                        decorations: e.decorations.isEmpty ? e.decorations : e.decorations.map { shiftDeco($0, dy: dy) },
                        checkboxes: e.checkboxes.isEmpty ? e.checkboxes : e.checkboxes.map { (rect: $0.rect.offsetBy(dx: 0, dy: dy), pos: $0.pos + dPos, checked: $0.checked) },
                        disclosures: e.disclosures.isEmpty ? e.disclosures : e.disclosures.map { (rect: $0.rect.offsetBy(dx: 0, dy: dy), pos: $0.pos + dPos, open: $0.open) },
                        mathTargets: e.mathTargets.isEmpty ? e.mathTargets : e.mathTargets.map { (rect: $0.rect.offsetBy(dx: 0, dy: dy), pos: $0.pos + dPos) },
                        highlights: e.highlights.isEmpty ? e.highlights : e.highlights.map { (from: $0.from + dPos, to: $0.to + dPos, color: $0.color) },
                        codeBackgrounds: e.codeBackgrounds.isEmpty ? e.codeBackgrounds : e.codeBackgrounds.map { (from: $0.from + dPos, to: $0.to + dPos, color: $0.color) },
                        tables: e.tables.isEmpty ? e.tables : e.tables.map { TableInfo(tablePos: $0.tablePos + dPos, originX: $0.originX, widths: $0.widths, top: $0.top + dy, bottom: $0.bottom + dy) },
                        estimated: e.estimated)
    }

    // MARK: - Lazy (estimated) layout

    /// Typeset only the children whose estimated y-range overlaps `window`;
    /// estimate the height of the rest so the total document height is known
    /// without paying to lay out every block.
    private func buildLazy(_ doc: Node, window: ClosedRange<CGFloat>, x: CGFloat, width contentWidth: CGFloat) {
        var y = theme.pageInsets.top
        var pos = 0
        for i in 0..<doc.childCount {
            let child = doc.child(i)
            let previous = i == 0 ? nil : doc.child(i - 1)
            let spacing = theme.spacing(before: child, after: previous)
            let estimated = spacing + estimatedContentHeight(of: child)
            // Realize if the child's (estimated) span is anywhere near the window.
            if y + estimated >= window.lowerBound && y <= window.upperBound {
                entries.append(layoutTopChild(child, docPos: pos, x: x, width: contentWidth, y: &y, previous: previous))
            } else {
                let topY = y
                y += estimated
                entries.append(TopEntry(node: child, docStart: pos, topY: topY, height: estimated,
                                        blocks: [], decorations: [], checkboxes: [], highlights: [], tables: [], estimated: true))
            }
            pos += child.nodeSize
        }
        height = y + theme.pageInsets.bottom
    }

    /// A cheap height estimate for a top-level child (no typesetting): its text
    /// length wrapped at the content width.
    private func estimatedContentHeight(of child: Node) -> CGFloat {
        // A rule holds a height the theme fixes outright, so estimate it exactly
        // rather than guessing at text it doesn't have.
        if child.type.name == "horizontalRule" {
            let rule = theme.horizontalRule
            return theme.points(rule.spacingBefore) + rule.thickness + theme.points(rule.spacingAfter)
        }
        let font = theme.blockFont(child)
        let lineHeight = theme.lineHeight(for: child, naturalHeight: font.lineHeight)
        let avgChar = max(font.pointSize * 0.5, 1)
        let usableWidth = max(width - theme.pageInsets.left - theme.pageInsets.right, avgChar)
        let charsPerLine = max(Int(usableWidth / avgChar), 1)
        // A closed details shows only its summary — its hidden body isn't laid out.
        let visibleText = child.type.name == "details" && !(child.attrs["open"]?.boolValue ?? false)
            ? (child.firstChild?.textContent ?? "")
            : child.textContent
        let textLength = max(visibleText.count, 1)
        let lines = Int(ceil(Double(textLength) / Double(charsPerLine)))
        // The block's own height only: its caller adds the gap above it, and
        // adding one here as well counted every block's spacing twice.
        var height = CGFloat(max(lines, 1)) * lineHeight
        // Chrome the theme adds around the text, which the estimate would
        // otherwise miss and have to correct for on realizing the block.
        if child.type.name == "codeBlock" {
            let padding = theme.points(theme.code.block.padding)
            height += padding.top + padding.bottom
        }
        if let rule = theme.heading.resolved(for: child)?.rule {
            height += theme.points(rule.spacing) + rule.thickness
        }
        return height
    }

    /// Realize (typeset) any estimated children overlapping `window`, re-flowing
    /// positions and correcting the total height. Returns true if anything
    /// changed (the caller should redraw and re-report the height). O(children)
    /// plus the cost of the few children actually typeset.
    func realize(window: ClosedRange<CGFloat>) -> Bool {
        guard entries.contains(where: { $0.estimated }) else { return false }
        // Anything to do?
        var probe = theme.pageInsets.top
        var hit = false
        for e in entries {
            if e.estimated, probe + e.height >= window.lowerBound, probe <= window.upperBound { hit = true; break }
            probe = e.topY + e.height
        }
        guard hit else { return false }

        let old = entries
        entries = []; blocks = []; decorations = []; checkboxes = []; disclosures = []; mathTargets = []
        highlights = []; codeBackgrounds = []; tables = []; pendingImages = []
        let x = theme.pageInsets.left
        let contentWidth = width - theme.pageInsets.left - theme.pageInsets.right
        var y = theme.pageInsets.top
        for (i, e) in old.enumerated() {
            if e.estimated, y + e.height >= window.lowerBound, y <= window.upperBound {
                entries.append(layoutTopChild(e.node, docPos: e.docStart, x: x, width: contentWidth, y: &y,
                                              previous: i == 0 ? nil : old[i - 1].node))
            } else if e.estimated {
                entries.append(TopEntry(node: e.node, docStart: e.docStart, topY: y, height: e.height,
                                        blocks: [], decorations: [], checkboxes: [], highlights: [], tables: [], estimated: true))
                y += e.height
            } else {
                let shifted = shiftEntry(e, dPos: 0, dy: y - e.topY)
                append(shifted); entries.append(shifted)
                y = shifted.topY + shifted.height
            }
        }
        height = y + theme.pageInsets.bottom
        return true
    }

    /// Re-lay only the top-level children holding an image the predicate
    /// accepts, shifting everything below them by whatever they gained or lost.
    /// Returns true if anything moved.
    ///
    /// Image bytes arriving is the one change that alters the layout without
    /// altering the document, so none of the usual triggers fire — and a rebuild
    /// that reuses the previous layout would faithfully reproduce the
    /// placeholder. Rebuilding from scratch instead is correct but re-flows a
    /// whole document to adopt one picture, once per picture, while the reader
    /// is scrolling through them. This touches only the entries that actually
    /// reference it.
    func relayoutImages(matching predicate: (Node) -> Bool) -> Bool {
        func affected(_ e: TopEntry) -> Bool {
            !e.estimated && Self.containsImage(e.node, matching: predicate)
        }
        guard entries.contains(where: affected) else { return false }

        let old = entries
        entries = []; blocks = []; decorations = []; checkboxes = []; disclosures = []; mathTargets = []
        highlights = []; codeBackgrounds = []; tables = []; pendingImages = []
        let x = theme.pageInsets.left
        let contentWidth = width - theme.pageInsets.left - theme.pageInsets.right
        var y = theme.pageInsets.top
        for (i, e) in old.enumerated() {
            if affected(e) {
                entries.append(layoutTopChild(e.node, docPos: e.docStart, x: x, width: contentWidth, y: &y,
                                              previous: i == 0 ? nil : old[i - 1].node))
            } else if e.estimated {
                entries.append(TopEntry(node: e.node, docStart: e.docStart, topY: y, height: e.height,
                                        blocks: [], decorations: [], checkboxes: [], highlights: [], tables: [], estimated: true))
                y += e.height
            } else {
                let shifted = shiftEntry(e, dPos: 0, dy: y - e.topY)
                append(shifted); entries.append(shifted)
                y = shifted.topY + shifted.height
            }
        }
        height = y + theme.pageInsets.bottom
        return true
    }

    /// Whether `node` is, or contains, an image the predicate accepts.
    static func containsImage(_ node: Node, matching predicate: (Node) -> Bool) -> Bool {
        if node.type.name == "image" { return predicate(node) }
        var found = false
        node.descendants { child, _, _, _ in
            if found { return false }
            if child.type.name == "image", predicate(child) { found = true; return false }
            return true
        }
        return found
    }

    /// Whether any part of the document is still only estimated.
    var hasEstimatedContent: Bool { entries.contains { $0.estimated } }

    /// Realize the content around a document position (so an off-screen caret
    /// target becomes available for `caretRect`/reveal). Returns true if anything
    /// changed.
    func realize(aroundPos pos: Int, viewportHeight: CGFloat) -> Bool {
        guard hasEstimatedContent, let y = topY(forPos: pos) else { return false }
        let h = max(viewportHeight, 1)
        return realize(window: (y - h) ... (y + h))
    }

    /// The top y of the top-level child containing `pos` (estimated or realized).
    private func topY(forPos pos: Int) -> CGFloat? {
        for e in entries where pos >= e.docStart && pos <= e.docStart + e.node.nodeSize { return e.topY }
        return entries.last?.topY
    }

    /// Whether the top-level child containing `pos` is still only estimated (so
    /// `caretRect`/`selectionRects` would fall back to the nearest realized block).
    func isEstimated(pos: Int) -> Bool {
        for e in entries where pos >= e.docStart && pos <= e.docStart + e.node.nodeSize { return e.estimated }
        return false
    }

    private func shiftBlock(_ b: TextBlock, dPos: Int, dy: CGFloat) -> TextBlock {
        TextBlock(contentStart: b.contentStart + dPos, contentEnd: b.contentEnd + dPos,
                  frame: b.frame.offsetBy(dx: 0, dy: dy),
                  lines: dy == 0 ? b.lines : b.lines.map {
                      LineLayout(ctLine: $0.ctLine, baselineOrigin: CGPoint(x: $0.baselineOrigin.x, y: $0.baselineOrigin.y + dy),
                                 stringRange: $0.stringRange, height: $0.height, ascent: $0.ascent)
                  },
                  segments: dPos == 0 ? b.segments : b.segments.map {
                      Segment(docStart: $0.docStart + dPos, docLen: $0.docLen, attrStart: $0.attrStart, attrLen: $0.attrLen, text: $0.text)
                  },
                  attributed: b.attributed)
    }

    private func shiftDeco(_ d: DecorationItem, dy: CGFloat) -> DecorationItem {
        guard dy != 0 else { return d }
        switch d {
        case let .fill(r, c): return .fill(r.offsetBy(dx: 0, dy: dy), c)
        case let .stroke(r, c, w): return .stroke(r.offsetBy(dx: 0, dy: dy), c, w)
        case let .text(s, p, a): return .text(s, CGPoint(x: p.x, y: p.y + dy), a)
        case let .image(img, r): return .image(img, r.offsetBy(dx: 0, dy: dy))
        case let .icon(img, r): return .icon(img, r.offsetBy(dx: 0, dy: dy))
        case let .math(m, r): return .math(m, r.offsetBy(dx: 0, dy: dy))
        case let .roundedFill(r, c, rad): return .roundedFill(r.offsetBy(dx: 0, dy: dy), c, rad)
        case let .roundedStroke(r, c, w, rad): return .roundedStroke(r.offsetBy(dx: 0, dy: dy), c, w, rad)
        case let .checkmark(r, c, w): return .checkmark(r.offsetBy(dx: 0, dy: dy), c, w)
        }
    }

    // MARK: - Layout

    @discardableResult
    /// Lay out a fragment's children in a column. A fragment always starts its
    /// container, so its first child opens flush — there is no caller that
    /// continues one mid-column.
    private func layoutFragment(_ fragment: Fragment, docPos: Int, x: CGFloat, width: CGFloat, y: CGFloat) -> CGFloat {
        var y = y
        var pos = docPos
        for i in 0..<fragment.childCount {
            let child = fragment.child(i)
            let previous = i == 0 ? nil : fragment.child(i - 1)
            y += theme.spacing(before: child, after: previous)
            y = layoutBlock(child, docPos: pos, x: x, width: width, y: y)
            pos += child.nodeSize
        }
        return y
    }

    /// A small language badge at the top-right of a code block, when the host's
    /// `codeLanguageLabel` hook returns a label.
    private func addCodeLanguageBadge(_ node: Node, blockFrame: CGRect?) {
        guard let codeLanguageLabel, let frame = blockFrame,
              let label = codeLanguageLabel(node.textContent, node.attrs["language"]?.stringValue),
              !label.isEmpty else { return }
        let font = UIFont.systemFont(ofSize: max(10, theme.monoFont.pointSize - 3), weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: theme.code.color]
        let textSize = (label as NSString).size(withAttributes: attrs)
        let padX: CGFloat = 6, padY: CGFloat = 2
        let badge = CGRect(x: frame.maxX - textSize.width - padX * 2, y: frame.minY,
                           width: textSize.width + padX * 2, height: textSize.height + padY * 2)
        decorations.append(.roundedFill(badge, theme.hairlineColor.withAlphaComponent(0.25), 4))
        decorations.append(.text(label, CGPoint(x: badge.minX + padX, y: badge.minY + padY), attrs))
    }

    private func layoutBlock(_ node: Node, docPos: Int, x: CGFloat, width: CGFloat, y: CGFloat) -> CGFloat {
        // Where this block's decorations begin, for the few that have to be
        // inserted underneath the ones its content adds.
        let decorationStart = decorations.count
        switch node.type.name {
        case "codeBlock":
            let block = theme.code.block
            let inset = theme.points(block.padding)
            let endY = layoutTextBlock(node, docPos: docPos, x: x + inset.left,
                                       width: max(width - inset.left - inset.right, 1), y: y + inset.top)
            let bottom = endY + inset.bottom
            if let background = block.background {
                // Prepended, not appended: decorations paint in order and this
                // one goes under the block's own text and its language badge.
                decorations.insert(.roundedFill(CGRect(x: x, y: y, width: width, height: bottom - y),
                                                background, theme.points(block.cornerRadius)), at: decorationStart)
            }
            addCodeLanguageBadge(node, blockFrame: blocks.last?.frame)
            return bottom
        case "paragraph", "heading":
            let endY = layoutTextBlock(node, docPos: docPos, x: x, width: width, y: y)
            guard let rule = theme.heading.resolved(for: node)?.rule else { return endY }
            let ruleY = endY + theme.points(rule.spacing)
            decorations.append(.fill(CGRect(x: x, y: ruleY, width: width, height: rule.thickness),
                                     rule.color ?? theme.hairlineColor))
            return ruleY + rule.thickness
        case "figcaption":
            // A textblock, so it lays out like a paragraph. Without this it fell
            // to `default`, which walks a node's *children* as blocks — and a
            // caption's children are inline, so nothing was drawn at all.
            return layoutTextBlock(node, docPos: docPos, x: x, width: width, y: y)
        case "blockquote":
            let barX = x
            let quoteIndent = theme.points(theme.quote.indent)
            let innerX = x + quoteIndent
            let startY = y
            let endY = layoutFragment(node.content, docPos: docPos + 1, x: innerX, width: width - quoteIndent, y: y)
            decorations.append(.fill(CGRect(x: barX, y: startY, width: theme.quote.barWidth,
                                            height: endY - startY), theme.quoteBarColor))
            return endY
        case "bulletList", "orderedList":
            return layoutList(node, docPos: docPos, x: x, width: width, y: y)
        case "taskList":
            return layoutTaskList(node, docPos: docPos, x: x, width: width, y: y)
        case "listItem", "taskItem":
            return layoutFragment(node.content, docPos: docPos + 1, x: x, width: width, y: y)
        case "details":
            return layoutDetails(node, docPos: docPos, x: x, width: width, y: y)
        case "footnoteDefinition":
            return layoutFootnoteDefinition(node, docPos: docPos, x: x, width: width, y: y)
        case "horizontalRule":
            let rule = theme.horizontalRule
            let inset = theme.points(rule.inset)
            let lineY = y + theme.points(rule.spacingBefore)
            decorations.append(.fill(CGRect(x: x + inset, y: lineY,
                                            width: max(width - inset * 2, 0), height: rule.thickness),
                                     rule.color ?? theme.hairlineColor))
            return lineY + rule.thickness + theme.points(rule.spacingAfter)
        case "image":
            let src = node.attrs["src"]?.stringValue ?? ""
            let image = imageProvider(node)
            let size = Self.imageDisplaySize(node, natural: image?.size, available: width)
            if let image {
                decorations.append(.image(image, CGRect(x: x, y: y, width: size.width, height: size.height)))
                return y + size.height
            }
            // The placeholder reserves the box the image will occupy, so a
            // document whose images carry a size doesn't move when they load.
            // It borrows the picture's corner radius too, so the shape doesn't
            // change either.
            let box = CGRect(x: x, y: y, width: size.width, height: size.height)
            if let radius = Self.imageCornerRadius(theme, in: box) {
                decorations.append(.roundedStroke(box, theme.hairlineColor, 1, radius))
            } else {
                decorations.append(.stroke(box, theme.hairlineColor, 1))
            }
            let alt = node.attrs["alt"]?.stringValue ?? src
            decorations.append(.text("🖼 \(alt)", CGPoint(x: x + 8, y: y + 8), [.font: theme.bodyFont, .foregroundColor: theme.code.color]))
            if !src.isEmpty { pendingImages.append(node) }
            return y + size.height
        case "blockMath":
            // Display math is centered in the content column, like a figure.
            let latex = node.attrs["latex"]?.stringValue ?? ""
            let padding: CGFloat = 6
            guard let rendering = renderMath(latex, display: true) else {
                decorations.append(.text(latex, CGPoint(x: x, y: y + padding),
                                         [.font: theme.monoFont, .foregroundColor: theme.code.color]))
                return y + padding * 2 + theme.monoFont.lineHeight
            }
            let originX = x + max(0, (width - rendering.size.width) / 2)
            let rect = CGRect(x: originX, y: y + padding,
                              width: rendering.size.width, height: rendering.size.height)
            decorations.append(.math(rendering, rect))
            // The whole row is the tap target, not just the (often narrow) ink.
            mathTargets.append((rect: CGRect(x: x, y: y, width: width,
                                             height: rect.height + padding * 2), pos: docPos))
            return y + rendering.size.height + padding * 2
        case "table":
            return layoutTable(node, docPos: docPos, x: x, width: width, y: y)
        default:
            return layoutFragment(node.content, docPos: docPos + 1, x: x, width: width, y: y)
        }
    }

    /// Typeset a formula through the host's hook, in the theme's body font and
    /// text color (errors in the code color, so a typo reads as "not a formula"
    /// rather than as a formula that happens to look odd).
    private func renderMath(_ latex: String, display: Bool) -> MathRendering? {
        guard let mathRenderer, !latex.isEmpty else { return nil }
        guard let rendering = mathRenderer(latex, display, theme.bodyFont, theme.textColor) else { return nil }
        guard rendering.isError else { return rendering }
        // The source didn't parse: draw it in the muted code color instead, so a
        // typo reads as "not a formula" rather than as an odd-looking one.
        return mathRenderer(latex, display, theme.bodyFont, theme.code.color) ?? rendering
    }

    /// The box an image draws in.
    ///
    /// The node's `width`/`height` are the model. Either may be absent and is
    /// then derived from the other and the aspect ratio, so a host can pin one
    /// dimension and let the image keep its proportions; with neither set the
    /// image draws at its natural size. The result is always capped to the
    /// available width, scaled so the proportions chosen above survive.
    ///
    /// `natural` is nil until the bytes have loaded — the same rule then sizes
    /// the placeholder, which is what stops the document reflowing when they
    /// arrive.
    static func imageDisplaySize(_ node: Node, natural: CGSize?, available: CGFloat) -> CGSize {
        let attrWidth = node.attrs["width"]?.intValue.map { CGFloat($0) }
        let attrHeight = node.attrs["height"]?.intValue.map { CGFloat($0) }
        // The original image's own dimensions, when the node records them. This
        // is what a placeholder has to go on before any bytes exist — without
        // it, an image sized only by its width has to guess its own shape.
        let original = originalImageSize(node)

        // Prefer the loaded image's aspect, then the original's, then a
        // plausible default for a placeholder with nothing else to go on.
        let aspect: CGFloat
        if let natural, natural.width > 0, natural.height > 0 {
            aspect = natural.width / natural.height
        } else if let original, original.width > 0, original.height > 0 {
            aspect = original.width / original.height
        } else {
            aspect = placeholderSize.width / placeholderSize.height
        }

        var width: CGFloat, height: CGFloat
        switch (attrWidth, attrHeight) {
        case let (pinnedWidth?, pinnedHeight?):
            (width, height) = (pinnedWidth, pinnedHeight) // both pinned: the model wins
        case let (pinnedWidth?, nil):
            (width, height) = (pinnedWidth, pinnedWidth / max(aspect, 0.0001))
        case let (nil, pinnedHeight?):
            (width, height) = (pinnedHeight * aspect, pinnedHeight)
        case (nil, nil):
            // No display size: the loaded image, else the original's dimensions,
            // else the fallback box.
            let size = natural ?? original ?? placeholderSize
            (width, height) = (size.width, size.height)
        }
        if width > available, width > 0 {
            height *= available / width
            width = available
        }
        return CGSize(width: max(1, width), height: max(1, height))
    }

    /// The box an image with neither a size nor bytes yet falls back to.
    static let placeholderSize = CGSize(width: 200, height: 120)

    /// The corner radius to round a picture drawn in `rect` by, or nil when the
    /// theme asks for square corners — the caller then takes the cheaper path.
    ///
    /// Capped at half the shorter side: past that a rounded rect is no longer a
    /// well-defined path, and a host that writes a very large radius is asking
    /// for a capsule (or a circle on a square picture), which is what it gets.
    static func imageCornerRadius(_ theme: DocumentTheme, in rect: CGRect) -> CGFloat? {
        let radius = min(theme.image.cornerRadius, min(rect.width, rect.height) / 2)
        return radius > 0 ? radius : nil
    }

    /// The intrinsic size recorded in the node's `model` attribute — the
    /// original image behind the one being drawn. Read structurally rather than
    /// through `SchemaKit.ImageModel`, since the renderer sits below it; a
    /// malformed or partial value simply reads as nil.
    private static func originalImageSize(_ node: Node) -> CGSize? {
        // The `path` is required even though only the dimensions are used here:
        // without it this isn't a model, and sizing from an object that
        // `ImageModel` rejects would have the two layers disagreeing about the
        // same attribute.
        guard case let .object(model)? = node.attrs["model"],
              case .string = model["path"] ?? .null,
              let width = model["width"]?.intValue, let height = model["height"]?.intValue,
              width > 0, height > 0 else { return nil }
        return CGSize(width: CGFloat(width), height: CGFloat(height))
    }

    private func layoutList(_ node: Node, docPos: Int, x: CGFloat, width: CGFloat, y: CGFloat) -> CGFloat {
        var y = y
        var pos = docPos + 1
        let ordered = node.type.name == "orderedList"
        let start = node.attrs["order"]?.intValue ?? 1
        let markerAttrs: [NSAttributedString.Key: Any] = [.font: theme.bodyFont, .foregroundColor: theme.textColor]
        let indent = theme.points(theme.listIndent)
        let gap = theme.points(theme.listMarkerGap)
        for i in 0..<node.childCount {
            let item = node.child(i)
            y += theme.spacing(before: item, after: i == 0 ? nil : node.child(i - 1))
            // The marker sits on the first line of the item's content, right-
            // aligned in the indent gutter — and clamped into the content
            // column, since a marker can outgrow the gutter at large type.
            let marker = ordered ? "\(start + i)." : "•"
            let markerWidth = (marker as NSString).size(withAttributes: markerAttrs).width
            let markerX = max(x, x + indent - markerWidth - gap)
            decorations.append(.text(marker, CGPoint(x: markerX, y: y), markerAttrs))
            y = layoutFragment(item.content, docPos: pos + 1, x: x + indent, width: width - indent, y: y)
            pos += item.nodeSize
        }
        return y
    }

    /// A footnote's note: its number in the gutter, its blocks indented beside
    /// it — the shape a note takes at the foot of a page.
    private func layoutFootnoteDefinition(_ node: Node, docPos: Int, x: CGFloat,
                                          width: CGFloat, y: CGFloat) -> CGFloat {
        let indent = theme.points(theme.listIndent)
        let marker = footnoteNumber(node.attrs["label"]?.stringValue ?? "") + "."
        let markerAttrs: [NSAttributedString.Key: Any] = [
            .font: theme.bodyFont, .foregroundColor: theme.link.color,
        ]
        let markerWidth = (marker as NSString).size(withAttributes: markerAttrs).width
        let markerX = max(x, x + indent - markerWidth - theme.points(theme.listMarkerGap))
        decorations.append(.text(marker, CGPoint(x: markerX, y: y), markerAttrs))
        return layoutFragment(node.content, docPos: docPos + 1, x: x + indent,
                              width: width - indent, y: y)
    }

    /// What to show for a footnote label: its place among the references, so
    /// the numbers read 1, 2, 3 however the labels are spelled. Computed once
    /// for the document, since a block on its own can't know the order.
    private func footnoteNumber(_ label: String) -> String {
        footnoteOrder[label].map(String.init) ?? label
    }

    /// Every footnote label in the document, numbered in reading order:
    /// references first, then any note nothing refers to.
    static func footnoteOrdering(_ doc: Node) -> [String: Int] {
        // One walk, not two: this runs for every layout, so a long document
        // shouldn't be traversed more than it has to be. References are
        // numbered in reading order and notes take what's left, so both are
        // collected in the same pass and ordered afterwards.
        //
        // Deliberately not short-circuited on "does this schema have
        // footnotes": `NodeType.schema` is `unowned(unsafe)`, and a document
        // outliving the schema that made it is ordinary in this codebase —
        // reading through it crashes.
        var referenced: [String] = []
        var defined: [String] = []
        var seenReference = Set<String>()
        var seenDefinition = Set<String>()
        doc.descendants { node, _, _, _ in
            switch node.type.name {
            case "footnoteReference":
                let label = node.attrs["label"]?.stringValue ?? ""
                if seenReference.insert(label).inserted { referenced.append(label) }
            case "footnoteDefinition":
                let label = node.attrs["label"]?.stringValue ?? ""
                if seenDefinition.insert(label).inserted { defined.append(label) }
            default: break
            }
            return true
        }
        guard !referenced.isEmpty || !defined.isEmpty else { return [:] }
        var order: [String: Int] = [:]
        var next = 1
        for label in referenced + defined where order[label] == nil {
            order[label] = next
            next += 1
        }
        return order
    }

    private func layoutTaskList(_ node: Node, docPos: Int, x: CGFloat, width: CGFloat, y: CGFloat) -> CGFloat {
        var y = y
        var pos = docPos + 1
        let indent = theme.points(theme.listIndent)
        let gap = theme.points(theme.listMarkerGap)
        for i in 0..<node.childCount {
            let item = node.child(i)
            let checked = item.attrs["checked"]?.boolValue ?? false
            y += theme.spacing(before: item, after: i == 0 ? nil : node.child(i - 1))
            // Centre the box on the midline of the text it belongs to, sized to
            // that text — both derived from the first line's font, so the box
            // tracks Dynamic Type instead of fitting one body size. The font is
            // enough; the line doesn't have to be typeset first.
            let boxSize = Self.checkboxSize(for: theme, item: item)
            // Clamped into the content column: a box sized from the text can
            // outgrow its gutter, and it must never reach into the page margin
            // — still less off the left edge of the view.
            let boxRect = CGRect(x: max(x, x + indent - boxSize - gap),
                                 y: y + Self.checkboxOffset(for: theme, item: item, boxSize: boxSize),
                                 width: boxSize, height: boxSize)
            // The checkbox itself is a managed UIView (see EditorTextView's
            // checkbox-view recycling) positioned over this rect — the layout
            // only reserves its (touch-padded) box for positioning + hit-test.
            checkboxes.append((rect: boxRect.insetBy(dx: -6, dy: -6), pos: pos, checked: checked))
            // The item's whole subtree is typeset in its checked style. Saved and
            // restored rather than just set, so a nested list under a checked
            // item is governed by its *own* item — an unchecked sub-task is still
            // to do, whatever its parent says. (Tiptap's descendant selector
            // strikes those too; this reads better.)
            let outer = inCheckedItem
            inCheckedItem = checked
            y = layoutFragment(item.content, docPos: pos + 1, x: x + indent, width: width - indent, y: y)
            inCheckedItem = outer
            pos += item.nodeSize
        }
        return y
    }

    /// A collapsible section: a disclosure triangle in the gutter, the summary
    /// as a text block beside it, and — only while open — the content indented
    /// beneath. A closed section lays out no content at all, so its hidden text
    /// costs nothing to render.
    private func layoutDetails(_ node: Node, docPos: Int, x: CGFloat, width: CGFloat, y: CGFloat) -> CGFloat {
        let open = node.attrs["open"]?.boolValue ?? false
        let indent = theme.points(theme.listIndent)
        let innerX = x + indent
        let innerWidth = width - indent
        var y = y
        var pos = docPos + 1 // inside the details, before the summary
        // The triangle sits on the summary's first line, right-aligned in the gutter.
        let glyph = open ? "▼" : "▶"
        let glyphAttrs: [NSAttributedString.Key: Any] = [.font: theme.bodyFont, .foregroundColor: theme.code.color]
        let glyphSize = (glyph as NSString).size(withAttributes: glyphAttrs)
        decorations.append(.text(glyph, CGPoint(x: innerX - glyphSize.width - 8, y: y), glyphAttrs))
        disclosures.append((rect: CGRect(x: innerX - glyphSize.width - 8, y: y,
                                         width: glyphSize.width, height: glyphSize.height).insetBy(dx: -8, dy: -8),
                            pos: docPos, open: open))
        if node.childCount > 0 {
            let summary = node.child(0)
            // `pos` is already the position before the summary, which is what
            // `layoutTextBlock` wants — it adds the one for the opening token
            // itself. Passing `pos + 1` put the summary's whole block one
            // position late, so a tap in it answered with a position inside the
            // `details` rather than inside the summary; with an empty summary
            // that was the only block on screen, and every tap in the document
            // landed somewhere no caret could go.
            y = layoutTextBlock(summary, docPos: pos, x: innerX, width: innerWidth, y: y)
            pos += summary.nodeSize
        }
        if open, node.childCount > 1 {
            let content = node.child(1)
            y = layoutFragment(content.content, docPos: pos + 1, x: innerX, width: innerWidth,
                               y: y + theme.points(theme.paragraphSpacing))
        }
        return y
    }

    /// The document position of the math node drawn under `point`, if any.
    func math(at point: CGPoint) -> Int? {
        for target in mathTargets where target.rect.contains(point) { return target.pos }
        return nil
    }

    /// The details node whose disclosure triangle contains the point, if any.
    func disclosure(at point: CGPoint) -> (pos: Int, open: Bool)? {
        for d in disclosures where d.rect.contains(point) { return (d.pos, d.open) }
        return nil
    }

    /// The checkbox for a task item, sized against the text beside it: a little
    /// larger than its cap height, the proportion a checkbox and its label hold
    /// in the system's own lists.
    private static func checkboxSize(for theme: DocumentTheme, item: Node) -> CGFloat {
        let font = theme.blockFont(item.firstChild ?? item)
        return (font.capHeight * 1.55).rounded()
    }

    /// How far below the item's top the checkbox sits: enough to centre it on
    /// the first line's midline — halfway up the cap height from the baseline.
    private static func checkboxOffset(for theme: DocumentTheme, item: Node, boxSize: CGFloat) -> CGFloat {
        let font = theme.blockFont(item.firstChild ?? item)
        let midline = font.ascender - font.capHeight / 2
        return (midline - boxSize / 2).rounded()
    }

    /// The checkmark glyph for a checkbox of the given rect — shared between
    /// the canvas drawing and the view's check-on animation so the animated
    /// stroke and the final drawn glyph are pixel-identical.
    static func checkmarkPath(in rect: CGRect) -> UIBezierPath {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.22, y: rect.minY + rect.height * 0.54))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.42, y: rect.minY + rect.height * 0.74))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.78, y: rect.minY + rect.height * 0.28))
        return path
    }

    /// The task-item position whose checkbox contains the point, if any.
    func checkbox(at point: CGPoint) -> (pos: Int, checked: Bool)? {
        for box in checkboxes where box.rect.contains(point) { return (box.pos, box.checked) }
        return nil
    }

    private func layoutTable(_ node: Node, docPos: Int, x: CGFloat, width: CGFloat, y: CGFloat) -> CGFloat {
        var y0 = y
        let rows = node.childCount
        let cols = node.firstChild?.childCount ?? 1
        let widths = columnWidths(for: node, cols: cols, available: width)
        // Left edge of each column, then the table's right edge.
        var edges: [CGFloat] = [x]
        for w in widths { edges.append(edges.last! + w) }
        let style = theme.table
        let padding = theme.points(style.cellPadding)
        var pos = docPos + 1 // inside the table, before the first row
        for r in 0..<rows {
            let row = node.child(r)
            var cellPos = pos + 1 // inside the row, before the first cell
            var rowHeight = theme.points(style.minimumRowHeight)
            // Lay each cell's content out as real text blocks so the cell is
            // clickable, caret-able, and editable (top-aligned within the cell).
            for c in 0..<row.childCount {
                let cell = row.child(c)
                let cellX = edges[min(c, edges.count - 1)]
                let cellW = c < widths.count ? widths[c] : (width / CGFloat(max(cols, 1)))
                let outerAlignment = inCellAlignment
                inCellAlignment = cell.attrs["align"]?.stringValue
                let bottom = layoutFragment(cell.content, docPos: cellPos + 1,
                                            x: cellX + padding.left,
                                            width: max(cellW - padding.left - padding.right, 1),
                                            y: y0 + padding.top)
                inCellAlignment = outerAlignment
                rowHeight = max(rowHeight, bottom - y0 + padding.bottom)
                cellPos += cell.nodeSize
            }
            // Cell borders, drawn under the text.
            for c in 0..<row.childCount {
                let cellX = edges[min(c, edges.count - 1)]
                let cellW = c < widths.count ? widths[c] : (width / CGFloat(max(cols, 1)))
                decorations.append(.stroke(CGRect(x: cellX, y: y0, width: cellW, height: rowHeight),
                                           style.borderColor ?? theme.hairlineColor, style.borderWidth))
            }
            y0 += rowHeight
            pos += row.nodeSize
        }
        // Record the table geometry so the view can hit-test column borders.
        tables.append(TableInfo(tablePos: docPos, originX: x, widths: widths, top: y, bottom: y0))
        return y0 + theme.points(style.spacingAfter)
    }

    /// A colwidth attribute's width: the official array-of-ints form (first
    /// slot), with back-compat for the scalar doubles older documents carry.
    private static func colwidthValue(_ attr: AttributeValue?) -> Double? {
        if case let .array(arr)? = attr { return arr.first?.doubleValue }
        return attr?.doubleValue
    }

    /// Column widths for a table: the first row's `colwidth` attributes
    /// normalized to the available width, or an equal split when unset.
    private func columnWidths(for node: Node, cols: Int, available: CGFloat) -> [CGFloat] {
        let firstRow = node.firstChild
        let raw: [CGFloat?] = (0..<cols).map { c in
            guard let row = firstRow, c < row.childCount,
                  let w = Self.colwidthValue(row.child(c).attrs["colwidth"]), w > 0 else { return nil }
            return CGFloat(w)
        }
        if raw.contains(where: { $0 == nil }) {
            return Array(repeating: available / CGFloat(max(cols, 1)), count: cols)
        }
        let sum = raw.compactMap { $0 }.reduce(0, +)
        guard sum > 0 else { return Array(repeating: available / CGFloat(max(cols, 1)), count: cols) }
        return raw.map { ($0! / sum) * available }
    }

    private func layoutTextBlock(_ node: Node, docPos: Int, x: CGFloat, width: CGFloat, y: CGFloat) -> CGFloat {
        let contentStart = docPos + 1
        // Reuse the cached typeset block (in local coords) when unchanged; this
        // is what keeps per-keystroke cost off the whole document.
        // A block holding the `[[` being typed is typeset for this layout only:
        // the trigger is state, and neither the node nor the width changes as it
        // opens, moves or closes, so a cached block would keep serving the last
        // one's styling.
        let trigger = localTrigger(contentStart: contentStart, size: node.content.size)
        let local = trigger.map { typesetBlock(node, width: width, trigger: $0) }
            ?? blockCache?.lookup(node, width: width, checked: inCheckedItem,
                                  align: inCellAlignment) ?? {
            let built = typesetBlock(node, width: width)
            blockCache?.store(node, width: width, checked: inCheckedItem, align: inCellAlignment, built)
            return built
        }()

        // Shift the cached local lines to this block's absolute (x, y).
        let lines = local.lines.map {
            LineLayout(ctLine: $0.ctLine,
                       baselineOrigin: CGPoint(x: $0.baselineOrigin.x + x, y: $0.baselineOrigin.y + y),
                       stringRange: $0.stringRange, height: $0.height, ascent: $0.ascent)
        }
        for atom in local.imageAtoms {
            guard let line = lines.first(where: { NSLocationInRange(atom.attrIndex, $0.stringRange) }) else { continue }
            let xOffset = CTLineGetOffsetForStringIndex(line.ctLine, atom.attrIndex, nil)
            let top = line.baselineOrigin.y - atom.size.height
            decorations.append(.image(atom.image, CGRect(x: line.baselineOrigin.x + xOffset, y: top, width: atom.size.width, height: atom.size.height)))
        }
        // Wiki-link chips: the pill first, then the glyph over it (decorations
        // draw in order, and both draw under the text).
        for chip in local.wikiLinkChips {
            guard let line = lines.first(where: { NSLocationInRange(chip.attrStart, $0.stringRange) }) else { continue }
            let startX = line.baselineOrigin.x + CTLineGetOffsetForStringIndex(line.ctLine, chip.attrStart, nil)
            if let background = chip.background {
                let endX = line.baselineOrigin.x + CTLineGetOffsetForStringIndex(line.ctLine, chip.attrEnd, nil)
                let rect = CGRect(x: startX, y: line.baselineOrigin.y + chip.top,
                                  width: max(endX - startX, 0), height: chip.height)
                decorations.append(.roundedFill(rect, background, chip.cornerRadius))
            }
            if let icon = chip.icon {
                decorations.append(.icon(icon, chip.iconRect.offsetBy(dx: startX, dy: line.baselineOrigin.y)))
            }
        }
        for atom in local.mathAtoms {
            guard let line = lines.first(where: { NSLocationInRange(atom.attrIndex, $0.stringRange) }) else { continue }
            let xOffset = CTLineGetOffsetForStringIndex(line.ctLine, atom.attrIndex, nil)
            // The formula's own baseline sits on the line's baseline.
            let top = line.baselineOrigin.y - atom.rendering.ascent
            let rect = CGRect(x: line.baselineOrigin.x + xOffset, y: top,
                              width: atom.rendering.size.width, height: atom.rendering.size.height)
            decorations.append(.math(atom.rendering, rect))
            mathTargets.append((rect: rect, pos: contentStart + atom.docOffset))
        }

        // Rebase the cached ranges onto where this block actually sits.
        for h in local.highlights {
            highlights.append((from: contentStart + h.from, to: contentStart + h.to, color: h.color))
        }
        for c in local.codeBackgrounds {
            codeBackgrounds.append((from: contentStart + c.from, to: contentStart + c.to, color: c.color))
        }

        let frame = CGRect(x: x, y: y, width: width, height: local.height)
        blocks.append(TextBlock(
            contentStart: contentStart,
            contentEnd: contentStart + node.content.size,
            frame: frame,
            lines: lines,
            segments: local.segments.isEmpty
                ? [Segment(docStart: contentStart, docLen: 0, attrStart: 0, attrLen: 0, text: "")]
                : local.segments.map {
                    Segment(docStart: contentStart + $0.docStart, docLen: $0.docLen,
                            attrStart: $0.attrStart, attrLen: $0.attrLen, text: $0.text)
                },
            attributed: local.attributed))
        return y + local.height
    }

    /// Typeset a text block in LOCAL coordinates (top at y = 0) and with
    /// block-relative document offsets, independent of its eventual position —
    /// cacheable by (node, width).
    private func typesetBlock(_ node: Node, width: CGFloat,
                              trigger: WikiLinkTrigger? = nil) -> LocalTextBlock {
        let (attr, builtSegments, imageAtoms, mathAtoms, highlights, codeBackgrounds, wikiLinkChips) =
            buildAttributed(node, width: width)
        var segments = builtSegments
        let rtl = isRightToLeft(attr.string)
        let base = NSMutableAttributedString(attributedString:
            attr.length == 0 ? NSAttributedString(string: " ", attributes: [.font: theme.blockFont(node)]) : attr)
        if let trigger { applyTrigger(trigger, to: base, segments: &segments, font: theme.blockFont(node)) }
        // A cell's alignment wins over the reading direction: a column set
        // `:---:` is centred whichever way its text runs.
        let cellAlignment = inCellAlignment
        // The block's own alignment (a caption's, a heading's) where the theme
        // gives one; a cell's column alignment still outranks it.
        let blockAlignment = theme.alignment(for: node)
        let centred = blockAlignment == .center || cellAlignment == "center"
        let para = NSMutableParagraphStyle()
        para.baseWritingDirection = rtl ? .rightToLeft : .leftToRight
        switch cellAlignment {
        case "left": para.alignment = .left
        case "center": para.alignment = .center
        case "right": para.alignment = .right
        default: para.alignment = blockAlignment ?? (rtl ? .right : .natural)
        }
        base.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: base.length))

        let typesetter = CTTypesetterCreateWithAttributedString(base as CFAttributedString)
        let length = base.length
        let nsString = base.string as NSString
        // CTTypesetterSuggestLineBreak wraps by WIDTH only — it doesn't stop at
        // hard line breaks (a code block's "\n", or a hard-break " "). So
        // cap each line at the first mandatory break within the suggested span.
        let hardBreaks = CharacterSet(charactersIn: "\n\r\u{2028}\u{2029}")
        var lines: [LineLayout] = []
        var lineStart = 0
        var lineY: CGFloat = 0
        while lineStart < length {
            var count = CTTypesetterSuggestLineBreak(typesetter, lineStart, Double(width))
            if count <= 0 { count = length - lineStart }
            let br = nsString.rangeOfCharacter(from: hardBreaks, range: NSRange(location: lineStart, length: count))
            if br.location != NSNotFound { count = br.location - lineStart + 1 }
            let ctLine = CTTypesetterCreateLine(typesetter, CFRangeMake(lineStart, count))
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            unsafe CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading)
            let lineHeight = theme.lineHeight(for: node, naturalHeight: ascent + descent + leading)
            // Lines are placed by hand, so alignment has to be applied here:
            // flush 0.5 centres, 1 pushes to the trailing edge.
            let flush: CGFloat? = centred ? 0.5
                : cellAlignment == "right" || blockAlignment == .right ? 1
                : cellAlignment == "left" || blockAlignment == .left ? nil
                : (rtl ? 1 : nil)
            let penOffset: CGFloat = flush
                .map { CGFloat(CTLineGetPenOffsetForFlush(ctLine, $0, Double(width))) } ?? 0
            lines.append(LineLayout(ctLine: ctLine,
                                    baselineOrigin: CGPoint(x: penOffset, y: lineY + ascent),
                                    stringRange: NSRange(location: lineStart, length: count),
                                    height: lineHeight, ascent: ascent))
            lineY += lineHeight
            lineStart += count
            if count == 0 { break }
        }
        // If the text ends with a hard break, add a trailing empty line so the
        // caret has somewhere to sit on the new (blank) line.
        if length > 0, let last = Unicode.Scalar(nsString.character(at: length - 1)), hardBreaks.contains(last) {
            let font = theme.blockFont(node)
            let ascent = font.ascender, descent = -font.descender
            let lineHeight = theme.lineHeight(for: node, naturalHeight: ascent + descent)
            let empty = CTLineCreateWithAttributedString(NSAttributedString(string: "", attributes: [.font: font]))
            lines.append(LineLayout(ctLine: empty, baselineOrigin: CGPoint(x: 0, y: lineY + ascent),
                                    stringRange: NSRange(location: length, length: 0), height: lineHeight, ascent: ascent))
            lineY += lineHeight
        }
        return LocalTextBlock(lines: lines, segments: segments, attributed: base, height: lineY,
                              imageAtoms: imageAtoms, mathAtoms: mathAtoms,
                              highlights: highlights, codeBackgrounds: codeBackgrounds,
                              wikiLinkChips: wikiLinkChips)
    }

    /// The open `[[` rebased onto a block's local offsets, when it is this
    /// block that holds it. A trigger never spans two blocks, so anything that
    /// doesn't sit wholly inside this one belongs to another.
    private func localTrigger(contentStart: Int, size: Int) -> WikiLinkTrigger? {
        guard let trigger = wikiLinkTrigger,
              trigger.range.lowerBound >= contentStart, trigger.range.upperBound <= contentStart + size,
              trigger.cursor >= contentStart, trigger.cursor <= contentStart + size else { return nil }
        return WikiLinkTrigger(
            range: (trigger.range.lowerBound - contentStart)..<(trigger.range.upperBound - contentStart),
            cursor: trigger.cursor - contentStart, closing: trigger.closing)
    }

    /// Set the typed `[[` apart, and draw the closing brackets it hasn't got
    /// yet. The ghost goes into the attributed string rather than over it, so
    /// the text after the cursor reflows around it instead of being painted on;
    /// it carries a zero-length segment, which is what keeps every document
    /// position mapping to a real character.
    private func applyTrigger(_ trigger: WikiLinkTrigger, to text: NSMutableAttributedString,
                              segments: inout [Segment], font: UIFont) {
        let style = theme.wikiLink.trigger
        if !trigger.range.isEmpty {
            let start = attrIndex(forDocPos: trigger.range.lowerBound, in: segments)
            let end = attrIndex(forDocPos: trigger.range.upperBound, in: segments)
            if end > start, end <= text.length {
                let range = NSRange(location: start, length: end - start)
                if let color = style.color { text.addAttribute(.foregroundColor, value: color, range: range) }
                if style.opacity < 1 {
                    // Collected first: the colour of one run decides the colour
                    // it's replaced by, and rewriting it mid-enumeration would
                    // be reading and writing the same attribute at once.
                    var faded: [(NSRange, UIColor)] = []
                    unsafe text.enumerateAttribute(.foregroundColor, in: range) { value, sub, _ in
                        faded.append((sub, Self.fade(value as? UIColor ?? theme.textColor, style.opacity)))
                    }
                    for (sub, color) in faded { text.addAttribute(.foregroundColor, value: color, range: sub) }
                }
            }
        }
        guard let closing = trigger.closing, !closing.isEmpty else { return }
        let index = attrIndex(forDocPos: trigger.cursor, in: segments)
        guard index >= 0, index <= text.length else { return }
        // The face of the character it completes, so the ghost matches the text
        // it's standing in for — but none of its decoration: an atom's reserved
        // box, an underline or a chip's kerning would all come along otherwise.
        var attrs: [NSAttributedString.Key: Any] = index > 0
            ? unsafe text.attributes(at: index - 1, effectiveRange: nil) : [.font: font]
        attrs[kCTRunDelegateAttributeName as NSAttributedString.Key] = nil
        attrs[.underlineStyle] = nil
        attrs[.kern] = nil
        attrs[.foregroundColor] = Self.fade(style.color ?? attrs[.foregroundColor] as? UIColor ?? theme.textColor,
                                            style.opacity)
        let ghost = NSAttributedString(string: closing, attributes: attrs)
        let length = ghost.length
        // The cursor can sit inside a text run, which then becomes two runs with
        // the ghost between them. (It can never sit inside an atom: an atom is
        // one document position, and both of its edges are segment boundaries.)
        if let i = segments.firstIndex(where: { $0.attrStart < index && index < $0.attrStart + $0.attrLen }),
           let runText = segments[i].text {
            let seg = segments[i]
            let split = runText.index(runText.startIndex, offsetBy: trigger.cursor - seg.docStart,
                                      limitedBy: runText.endIndex) ?? runText.endIndex
            let head = String(runText[..<split]), tail = String(runText[split...])
            segments[i] = Segment(docStart: seg.docStart, docLen: head.count, attrStart: seg.attrStart,
                                  attrLen: (head as NSString).length, text: head)
            segments.insert(Segment(docStart: seg.docStart + head.count, docLen: tail.count,
                                    attrStart: index, attrLen: (tail as NSString).length, text: tail), at: i + 1)
        }
        for i in segments.indices where segments[i].attrStart >= index { segments[i].attrStart += length }
        text.insert(ghost, at: index)
        // Zero document length: the ghost is not in the document, so no position
        // may land in it — the run before it owns the cursor's index.
        let at = segments.firstIndex { $0.attrStart >= index + length } ?? segments.count
        segments.insert(Segment(docStart: trigger.cursor, docLen: 0, attrStart: index,
                                attrLen: length, text: nil), at: at)
    }

    /// A colour at a fraction of its own opacity, still resolving light/dark for
    /// itself — `withAlphaComponent` alone would pin whichever it is now.
    private static func fade(_ color: UIColor, _ opacity: CGFloat) -> UIColor {
        let factor = max(0, min(opacity, 1))
        guard factor < 1 else { return color }
        return UIColor { trait in
            let resolved = color.resolvedColor(with: trait)
            return resolved.withAlphaComponent(resolved.cgColor.alpha * factor)
        }
    }

    /// Every document offset it produces is relative to the block's content
    /// start, so the result can be cached and reused at any position.
    private func buildAttributed(_ node: Node, width: CGFloat)
        -> (NSMutableAttributedString, [Segment],
            [(attrIndex: Int, image: UIImage, size: CGSize)],
            [(attrIndex: Int, docOffset: Int, rendering: MathRendering)],
            [(from: Int, to: Int, color: UIColor)],
            [(from: Int, to: Int, color: UIColor)],
            [WikiLinkChip]) {
        let result = NSMutableAttributedString()
        var segments: [Segment] = []
        var imageAtoms: [(attrIndex: Int, image: UIImage, size: CGSize)] = []
        var mathAtoms: [(attrIndex: Int, docOffset: Int, rendering: MathRendering)] = []
        // Block-relative, and deliberately not the layout-wide `highlights` /
        // `codeBackgrounds` they used to append straight to — a block served
        // from the cache is never typeset again, so collecting them here and
        // rebasing at the call site is what keeps them.
        var blockHighlights: [(from: Int, to: Int, color: UIColor)] = []
        var blockCodeBackgrounds: [(from: Int, to: Int, color: UIColor)] = []
        var wikiLinkChips: [WikiLinkChip] = []
        let blockFont = theme.blockFont(node)
        var docPos = 0

        // A heading's settled style — which level's color applies, and whether
        // the h1 title takes one at all, is the theme's policy, not ours.
        let headingStyle = theme.heading.resolved(for: node)

        func appendText(_ text: String, marks: [Mark]) {
            // A caption is quieter than body text (marks still win over both);
            // inside a checked task item, the item's own color wins instead.
            let baseColor = node.type.name == "figcaption"
                ? theme.caption.color
                : (inCheckedItem ? theme.taskItem.checkedTextColor : nil) ?? headingStyle?.color
            var attrs = node.type.name == "codeBlock"
                ? [NSAttributedString.Key.font: theme.monoFont,
                   .foregroundColor: theme.code.block.color ?? theme.textColor]
                : theme.attributes(for: marks, baseFont: blockFont, baseColor: baseColor,
                                   tracking: headingStyle?.tracking)
            // A checked item reads as done: struck through, like Reminders.
            // (A `strike` mark sets the same attribute, so they can't conflict.)
            if inCheckedItem, theme.taskItem.strikethroughWhenChecked {
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            // Highlight and backgroundColor marks paint a background behind the
            // run (drawn separately since CoreText ignores `.backgroundColor`).
            if !text.isEmpty {
                if let mark = marks.first(where: { $0.type.name == "highlight" }) {
                    blockHighlights.append((from: docPos, to: docPos + text.count,
                                            color: theme.highlightColor(mark.attrs["color"]?.stringValue)))
                } else if let mark = marks.first(where: { $0.type.name == "backgroundColor" }),
                          let color = DocumentTheme.parseColor(mark.attrs["color"]?.stringValue) {
                    blockHighlights.append((from: docPos, to: docPos + text.count, color: color))
                }
                // Inline `code` runs get a themed background pill (if configured).
                if let codeBg = theme.code.inline.background, marks.contains(where: { $0.type.name == "code" }) {
                    blockCodeBackgrounds.append((from: docPos, to: docPos + text.count, color: codeBg))
                }
            }
            let attrStart = result.length
            result.append(NSAttributedString(string: text, attributes: attrs))
            let len = (text as NSString).length
            segments.append(Segment(docStart: docPos, docLen: text.count, attrStart: attrStart, attrLen: len, text: text))
            docPos += text.count
        }

        for i in 0..<node.childCount {
            let child = node.child(i)
            if child.isText {
                appendText(child.text ?? "", marks: child.marks)
            } else if child.type.name == "hardBreak" {
                let attrStart = result.length
                result.append(NSAttributedString(string: "\u{2028}", attributes: [.font: blockFont]))
                segments.append(Segment(docStart: docPos, docLen: 1, attrStart: attrStart, attrLen: 1, text: "\u{2028}"))
                docPos += 1
            } else if child.type.name == "inlineMath",
                      let rendering = renderMath(child.attrs["latex"]?.stringValue ?? "", display: false) {
                // Reserve the formula's box on its own baseline, so the line's
                // ascent grows to fit it and the text next to it stays aligned.
                let ascent = rendering.ascent
                let descent = rendering.size.height - ascent
                let delegate = makeBoxRunDelegate(width: rendering.size.width, ascent: ascent, descent: descent)
                let attrStart = result.length
                result.append(NSAttributedString(string: "\u{fffc}", attributes: [kCTRunDelegateAttributeName as NSAttributedString.Key: delegate]))
                mathAtoms.append((attrIndex: attrStart, docOffset: docPos, rendering: rendering))
                segments.append(Segment(docStart: docPos, docLen: 1, attrStart: attrStart, attrLen: 1, text: nil))
                docPos += 1
            } else if child.type.name == "image", let image = imageProvider(child) {
                // Inline image: reserve its box via a run delegate, and record it
                // to draw at its run position after line breaking. Sized by the
                // same rule as a block image — `width`/`height` mean the same
                // thing wherever the image sits, and used to be ignored here.
                let size = Self.imageDisplaySize(child, natural: image.size, available: width)
                let delegate = makeImageRunDelegate(size)
                let attrStart = result.length
                result.append(NSAttributedString(string: "\u{fffc}", attributes: [kCTRunDelegateAttributeName as NSAttributedString.Key: delegate]))
                imageAtoms.append((attrIndex: attrStart, image: image, size: size))
                segments.append(Segment(docStart: docPos, docLen: 1, attrStart: attrStart, attrLen: 1, text: nil))
                docPos += 1
            } else {
                // wikiLink, an image still loading, or math with no renderer
                // wired up: show a text placeholder.
                let wikiStyle = theme.wikiLink
                let wikiColor = wikiStyle.color ?? theme.link.color
                // The host's glyph, looked up before the label is built: a chip
                // with one is a chip even without a pill behind it.
                let chipIcon: UIImage? = child.type.name == "wikiLink"
                    ? wikiLinkIcon?(child)?.withTintColor(wikiColor, renderingMode: .alwaysTemplate)
                    : nil
                let isChip = child.type.name == "wikiLink"
                    && (wikiStyle.background != nil || chipIcon != nil)
                let display: String
                switch child.type.name {
                case "wikiLink":
                    let label = child.attrs["label"]?.stringValue ?? child.attrs["target"]?.stringValue ?? "link"
                    // A chip is one object: it may not break in half at the end
                    // of a line, so its spaces stop being break opportunities.
                    display = isChip ? label.replacingOccurrences(of: " ", with: "\u{00a0}") : label
                case "inlineMath":
                    display = "$" + (child.attrs["latex"]?.stringValue ?? "") + "$"
                case "footnoteReference":
                    // The number a reader sees, not the label: `[^note]` is the
                    // second footnote, so it reads as "2".
                    display = footnoteNumber(child.attrs["label"]?.stringValue ?? "")
                default:
                    display = "🖼"
                }
                var atomAttrs: [NSAttributedString.Key: Any] = child.type.name == "wikiLink"
                    ? [.font: blockFont, .foregroundColor: wikiColor]
                    : [.font: child.type.name == "inlineMath" ? theme.monoFont : blockFont,
                       .foregroundColor: theme.code.color]
                if child.type.name == "footnoteReference" {
                    // Raised and smaller, the way a footnote marker is set.
                    let superscript = blockFont.withSize(max(8, blockFont.pointSize * 0.75))
                    atomAttrs = [.font: superscript,
                                 .baselineOffset: blockFont.pointSize * 0.35,
                                 .foregroundColor: theme.link.color]
                }
                if child.type.name == "wikiLink", wikiStyle.underline ?? theme.link.underline {
                    atomAttrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
                let attrStart = result.length
                // A wiki-link chip: reserve the pill's leading padding and the
                // host glyph's box as real advance, so the words around the
                // chip clear it instead of tucking underneath.
                if child.type.name == "wikiLink" {
                    let padX = wikiStyle.background != nil ? theme.points(wikiStyle.paddingX) : 0
                    let iconBox = chipIcon != nil ? theme.points(wikiStyle.iconSize) : 0
                    let gap = chipIcon != nil ? theme.points(wikiStyle.iconGap) : 0
                    let leading = padX + iconBox + gap
                    if leading > 0 {
                        let delegate = makeBoxRunDelegate(width: leading, ascent: blockFont.ascender,
                                                          descent: -blockFont.descender)
                        // The box's own character is U+FFFC, whose line-breaking
                        // class allows a break on either side of it — which put
                        // a chip's glyph at the end of one line and its label at
                        // the start of the next. The word joiner after it
                        // forbids that break without taking any width.
                        result.append(NSAttributedString(string: "\u{fffc}", attributes: [
                            kCTRunDelegateAttributeName as NSAttributedString.Key: delegate,
                            .font: blockFont,
                        ]))
                        // Its own run, so the delegate still governs exactly one
                        // character and reserves exactly one box.
                        result.append(NSAttributedString(string: "\u{2060}", attributes: [.font: blockFont]))
                    }
                }
                result.append(NSAttributedString(string: display, attributes: atomAttrs))
                if child.type.name == "wikiLink" {
                    if wikiStyle.background != nil, result.length > attrStart {
                        // Trailing padding, as kerning on the last glyph — the
                        // mirror of the leading box, and the same reason.
                        result.addAttribute(.kern, value: theme.points(wikiStyle.paddingX),
                                            range: NSRange(location: result.length - 1, length: 1))
                    }
                    let padY = wikiStyle.background != nil ? theme.points(wikiStyle.paddingY) : 0
                    let iconBox = theme.points(wikiStyle.iconSize)
                    wikiLinkChips.append(WikiLinkChip(
                        attrStart: attrStart, attrEnd: result.length,
                        background: wikiStyle.background,
                        cornerRadius: theme.points(wikiStyle.cornerRadius),
                        top: -blockFont.ascender - padY,
                        height: blockFont.ascender - blockFont.descender + padY * 2,
                        icon: chipIcon,
                        iconRect: CGRect(x: wikiStyle.background != nil ? theme.points(wikiStyle.paddingX) : 0,
                                         y: -(blockFont.capHeight + iconBox) / 2,
                                         width: iconBox, height: iconBox)))
                }
                segments.append(Segment(docStart: docPos, docLen: 1, attrStart: attrStart, attrLen: result.length - attrStart, text: nil))
                docPos += 1
                if child.type.name == "image", let src = child.attrs["src"]?.stringValue, !src.isEmpty {
                    pendingImages.append(child)
                }
            }
        }
        // Code-block syntax highlighting: apply the host's tokens over the
        // monospaced base. Token ranges are grapheme offsets into the code text.
        if node.type.name == "codeBlock", let highlighter = syntaxHighlighter, result.length > 0 {
            let code = result.string
            let tokens = highlighter(code, node.attrs["language"]?.stringValue)
            // Grapheme offset -> UTF-16 offset for every grapheme boundary,
            // built in one pass. A host highlighter may hand back tokens in any
            // order, so this is a table rather than a moving cursor; either way
            // it replaces walking from `startIndex` once per token, which made
            // applying the tokens quadratic in the size of the block.
            var utf16Offsets: [Int] = []
            if !tokens.isEmpty {
                utf16Offsets.reserveCapacity(code.utf16.count + 1)
                var offset = 0
                for character in code {
                    utf16Offsets.append(offset)
                    offset += character.utf16.count
                }
                utf16Offsets.append(offset)
            }
            for token in tokens {
                let lo = token.range.lowerBound, hi = token.range.upperBound
                guard lo >= 0, hi < utf16Offsets.count, lo < hi else { continue }
                let nsRange = NSRange(location: utf16Offsets[lo], length: utf16Offsets[hi] - utf16Offsets[lo])
                if let color = token.color { result.addAttribute(.foregroundColor, value: color, range: nsRange) }
                if token.bold || token.italic {
                    var traits: UIFontDescriptor.SymbolicTraits = []
                    if token.bold { traits.insert(.traitBold) }
                    if token.italic { traits.insert(.traitItalic) }
                    if let descriptor = theme.monoFont.fontDescriptor.withSymbolicTraits(traits) {
                        result.addAttribute(.font, value: UIFont(descriptor: descriptor, size: theme.monoFont.pointSize), range: nsRange)
                    }
                }
            }
        }
        return (result, segments, imageAtoms, mathAtoms, blockHighlights, blockCodeBackgrounds, wikiLinkChips)
    }

    // MARK: - Geometry queries

    /// The index of the line that owns `attrIndex` as a caret position. At a
    /// boundary shared by two lines (right after a soft wrap or a hard "\n"), the
    /// LATER line wins, so the caret sits at the start of the new line rather
    /// than the end of the previous one.
    private func lineIndex(_ block: TextBlock, _ attrIndex: Int) -> Int? {
        var found: Int?
        for (i, line) in block.lines.enumerated()
        where line.stringRange.location <= attrIndex && attrIndex <= line.stringRange.location + line.stringRange.length {
            found = i
        }
        return found ?? (block.lines.isEmpty ? nil : block.lines.count - 1)
    }

    /// The caret rectangle for a document position, or nil if not in a text block.
    func caretRect(at pos: Int) -> CGRect? {
        guard let block = blockContaining(pos) else {
            // fall back to nearest block edge
            if let block = nearestBlock(toPos: pos), let first = block.lines.first {
                return CGRect(x: block.frame.minX, y: first.baselineOrigin.y - first.ascent, width: 2, height: first.height)
            }
            return nil
        }
        let attrIndex = block.attrIndex(forDocPos: pos)
        let line = lineIndex(block, attrIndex).map { block.lines[$0] } ?? block.lines.last
        guard let line else {
            return CGRect(x: block.frame.minX, y: block.frame.minY, width: 2, height: block.frame.height)
        }
        let xOffset = CTLineGetOffsetForStringIndex(line.ctLine, attrIndex, nil)
        let top = line.baselineOrigin.y - line.ascent
        return CGRect(x: line.baselineOrigin.x + xOffset, y: top, width: 2, height: line.height)
    }

    /// The document position one line above/below `pos`, keeping the caret's
    /// horizontal position (`preferredX`, in view coordinates). Returns nil when
    /// there is no line in that direction. Moving by adjacent line (rather than
    /// by a guessed point) avoids snapping back across inter-block gaps.
    func verticalPosition(from pos: Int, up: Bool, preferredX: CGFloat) -> Int? {
        // The target line is the adjacent line in the same block, or the first/
        // last line of the neighbouring block — found locally, without building
        // or sorting every line in the document.
        guard let bi = blockIndex(containing: pos) else { return nil }
        let block = blocks[bi]
        let attrIndex = block.attrIndex(forDocPos: pos)
        guard let li = lineIndex(block, attrIndex) else { return nil }

        var target: (block: TextBlock, line: LineLayout)?
        if up {
            if li > 0 {
                target = (block, block.lines[li - 1])
            } else if let nb = neighbourBlock(below: false, of: block, preferredX: preferredX) {
                target = (nb, nb.lines.last!)
            }
        } else {
            if li < block.lines.count - 1 {
                target = (block, block.lines[li + 1])
            } else if let nb = neighbourBlock(below: true, of: block, preferredX: preferredX) {
                target = (nb, nb.lines.first!)
            }
        }
        guard let target else { return nil }
        let relative = CGPoint(x: preferredX - target.line.baselineOrigin.x, y: 0)
        var attr = CTLineGetStringIndexForPosition(target.line.ctLine, relative)
        // The index at the end of the target line is the NEXT line's start, and
        // the caret for it is drawn there — so landing on it bounces the caret
        // straight past the line we aimed at (the "stuck" arrow). Clamp to the
        // last index the target line actually owns.
        //
        // Two ways to arrive there. A trailing hard break: the line owns the
        // "\n" and the index after it starts the next line. And a soft wrap
        // onto a shorter line: a column beyond the short line's width answers
        // with its end, which is the next line's start — ↓ from a long line
        // then skips the short one, and ↑ from where it lands comes back to the
        // same place forever.
        let lineEnd = target.line.stringRange.location + target.line.stringRange.length
        if attr >= lineEnd, lineEnd > target.line.stringRange.location {
            let endsInBreak = Unicode.Scalar((target.block.attributed.string as NSString).character(at: lineEnd - 1))
                .map { CharacterSet(charactersIn: "\n\r\u{2028}\u{2029}").contains($0) } ?? false
            let isLastLine = target.line.stringRange.location == target.block.lines.last?.stringRange.location
            if endsInBreak || !isLastLine { attr = lineEnd - 1 }
        }
        return target.block.docPos(forAttrIndex: attr)
    }

    /// The block directly above/below `block` at `preferredX`. For normal
    /// stacked flow this is simply the vertically-nearest block in the travel
    /// direction (so short list items / paragraphs are never skipped). The
    /// same-column preference applies ONLY within that nearest vertical level —
    /// i.e. side-by-side table cells in one row — where we pick the cell whose
    /// x-range straddles `preferredX` instead of the nearest one by x.
    private func neighbourBlock(below: Bool, of block: TextBlock, preferredX: CGFloat) -> TextBlock? {
        let cur = block.frame
        func yGap(_ f: CGRect) -> CGFloat { below ? f.minY - cur.maxY : cur.minY - f.maxY }
        let candidates = blocks.filter { b in
            !b.lines.isEmpty && (below ? b.frame.minY >= cur.maxY - 0.5 : b.frame.maxY <= cur.minY + 0.5)
        }
        guard let minGap = candidates.map({ yGap($0.frame) }).min() else { return nil }
        // The nearest "row": blocks essentially at the same vertical level
        // (one element for stacked flow; several for a table row).
        let row = candidates.filter { yGap($0.frame) <= minGap + 1 }
        // Within the row, prefer the block straddling the caret column; else the
        // one nearest the column in x.
        if let inColumn = row.first(where: { $0.frame.minX - 0.5 <= preferredX && preferredX <= $0.frame.maxX + 0.5 }) {
            return inColumn
        }
        return row.min(by: { abs($0.frame.midX - preferredX) < abs($1.frame.midX - preferredX) })
    }

    /// The document position at the start or end of the *visual* line that
    /// contains `pos` (the wrapped line, not the whole textblock).
    func lineBoundary(from pos: Int, toEnd: Bool) -> Int? {
        guard let block = blockContaining(pos) else { return nil }
        let attrIndex = block.attrIndex(forDocPos: pos)
        guard let li = lineIndex(block, attrIndex) else { return nil }
        let line = block.lines[li]
        var end = line.stringRange.location + line.stringRange.length
        // Don't let "end of line" land past a trailing hard break.
        if toEnd, end > line.stringRange.location,
           let scalar = Unicode.Scalar((block.attributed.string as NSString).character(at: end - 1)),
           CharacterSet(charactersIn: "\n\r\u{2028}\u{2029}").contains(scalar) {
            end -= 1
        }
        let targetAttr = toEnd ? end : line.stringRange.location
        return block.docPos(forAttrIndex: targetAttr)
    }

    /// The document position nearest to a point in view coordinates.
    func position(at point: CGPoint) -> Int? {
        guard !blocks.isEmpty else { return nil }
        // Blocks whose vertical span contains the point. Several can match when
        // they sit side by side (table cells in a row), so disambiguate by x.
        let onRow = blocks.filter { point.y >= $0.frame.minY && point.y <= $0.frame.maxY }
        let block: TextBlock
        if !onRow.isEmpty {
            block = onRow.first { point.x >= $0.frame.minX && point.x <= $0.frame.maxX }
                ?? onRow.min(by: { abs($0.frame.midX - point.x) < abs($1.frame.midX - point.x) })!
        } else {
            // In the space BETWEEN blocks, by distance to the nearest edge — not
            // to the block's middle. A paragraph is as tall as it is long, so
            // measuring from the middle hands the whole gap beneath one to
            // whatever short block comes next: the end of a paragraph could not
            // be tapped, because the points just below its last line belonged to
            // the heading underneath. By edge, the gap splits down the middle.
            block = blocks.min(by: { verticalDistance(point.y, $0.frame) < verticalDistance(point.y, $1.frame) })!
        }
        // Find the line. The band is half open, so a line owns its own top edge
        // and not the next line's: lines abut, and a closed band answers that
        // shared edge with the line above.
        let line = block.lines.first { point.y >= $0.baselineOrigin.y - $0.ascent && point.y < $0.baselineOrigin.y - $0.ascent + $0.height }
            ?? block.lines.min(by: { abs($0.baselineOrigin.y - point.y) < abs($1.baselineOrigin.y - point.y) })
        guard let line else { return block.contentStart }
        // Ask about a point just *inside* the line rather than one exactly on
        // its leading edge. CoreText is asked for the nearest index, and at the
        // edge itself a line opening with an inline atom answered with the index
        // after the atom — so a tap there landed one position on, and moving
        // right moved the caret backwards.
        //
        // Nudging the point rather than naming an index is what keeps this
        // right in both directions: the position a line begins with is drawn on
        // the left only when the line reads that way, and on an Arabic line it
        // is the *last* position that sits at the left edge.
        let relative = CGPoint(x: Swift.max(point.x - line.baselineOrigin.x, 0.5), y: 0)
        var attrIndex = CTLineGetStringIndexForPosition(line.ctLine, relative)
        // A line that ends in a hard break owns the break, so the index after it
        // is the NEXT line's start. Without this a tap at the end of the line
        // lands past the break, one position on from the caret we drew there —
        // tap the caret and it moves. `lineBoundary` and `verticalPosition`
        // clamp the same way, for the same reason. A soft wrap is unaffected:
        // its line ends in a space, and the position either side of it is the
        // same one.
        let lineEnd = line.stringRange.location + line.stringRange.length
        if attrIndex >= lineEnd, lineEnd > line.stringRange.location,
           let scalar = Unicode.Scalar((block.attributed.string as NSString).character(at: lineEnd - 1)),
           CharacterSet(charactersIn: "\n\r\u{2028}\u{2029}").contains(scalar) {
            attrIndex = lineEnd - 1
        }
        return block.docPos(forAttrIndex: attrIndex)
    }

    /// How far `y` is from a block's frame — zero while inside it.
    private func verticalDistance(_ y: CGFloat, _ frame: CGRect) -> CGFloat {
        max(frame.minY - y, y - frame.maxY, 0)
    }

    /// The width of the text/content column (the page width minus its insets) —
    /// the maximum an image may be resized to.
    var contentWidth: CGFloat { width - theme.pageInsets.left - theme.pageInsets.right }

    /// The drawn rect of a block-level `image` (the image itself, or its
    /// placeholder box), if any, in document coordinates.
    private func blockImageRect(_ e: TopEntry) -> CGRect? {
        for d in e.decorations {
            if case let .image(_, r) = d { return r }
            if case let .stroke(r, _, _) = d { return r }
        }
        return nil
    }

    /// Block image draw rects paired with their document positions — for drawing
    /// and hit-testing resize handles.
    var imageRects: [(pos: Int, rect: CGRect)] {
        entries.compactMap { e in
            e.node.type.name == "image" ? blockImageRect(e).map { (e.docStart, $0) } : nil
        }
    }

    /// The document position of a block-level `image` whose drawn rect (the image
    /// itself, or its placeholder box) contains `point` — for starting a drag from
    /// an image. Inline images live inside text blocks and are found via
    /// `position(at:)` instead.
    func blockImage(at point: CGPoint) -> Int? {
        for e in entries where e.node.type.name == "image" {
            if let rect = blockImageRect(e), rect.contains(point) { return e.docStart }
        }
        return nil
    }

    /// Selection highlight rectangles for a document range.
    /// The rectangles covering `from..<to`, one per line of text.
    ///
    /// `clipY` bounds the work to a band of the document. Every rect costs two
    /// CoreText offset lookups, so a caller that only draws what's on screen
    /// must say so here rather than filter the result: with the whole of a long
    /// document selected, computing every rect and discarding all but the
    /// visible few is the cost of a scroll frame, repeated for every frame.
    ///
    /// The band keeps exactly the rects that intersect it, which is what those
    /// callers were selecting for by hand — clipping changes the cost, never
    /// the drawing.
    ///
    /// Nil means all of them, which is what UIKit wants when it asks for the
    /// selection's geometry — it is placing handles and a loupe, not drawing.
    func selectionRects(from: Int, to: Int, clipY: ClosedRange<CGFloat>? = nil) -> [CGRect] {
        var rects: [CGRect] = []
        forEachLineFragment(from: from, to: to, clipY: clipY) { rect, _, _, _ in rects.append(rect) }
        return rects
    }

    /// The line fragments covering `from..<to`, in document order: each one's
    /// rect, plus the block and the attr-index span it was cut from.
    ///
    /// Callers that want a fragment's *document* range convert the span
    /// themselves via `block.docPos(forAttrIndex:)`. That is a segment walk per
    /// call, and this runs on the scroll path, so the conversion is the caller's
    /// to pay — `selectionRects`, which only ever wanted geometry, pays nothing.
    private func forEachLineFragment(from: Int, to: Int, clipY: ClosedRange<CGFloat>?,
                                     _ body: (CGRect, TextBlock, Int, Int) -> Void) {
        guard to > from, !blocks.isEmpty else { return }
        // First block overlapping [from, to): smallest index with contentEnd > from.
        var lo = 0, hi = blocks.count
        while lo < hi { let mid = (lo + hi) / 2; if blocks[mid].contentEnd <= from { lo = mid + 1 } else { hi = mid } }
        var i = lo
        // Blocks run down the page in document order, so a clip band is a
        // contiguous run of them: skip to the first one that reaches it rather
        // than walking the selection's whole prefix, and stop at the far edge.
        if let clipY {
            var blo = lo, bhi = blocks.count
            while blo < bhi {
                let mid = (blo + bhi) / 2
                if blocks[mid].frame.maxY < clipY.lowerBound { blo = mid + 1 } else { bhi = mid }
            }
            i = max(lo, blo)
        }
        while i < blocks.count, blocks[i].contentStart < to {
            let block = blocks[i]
            i += 1
            if let clipY {
                if block.frame.minY > clipY.upperBound { break }
                if block.frame.maxY < clipY.lowerBound { continue }
            }
            guard from < block.contentEnd, to > block.contentStart else { continue }
            let blockFrom = max(from, block.contentStart)
            let blockTo = min(to, block.contentEnd)
            let aFrom = block.attrIndex(forDocPos: blockFrom)
            let aTo = block.attrIndex(forDocPos: blockTo)
            for line in block.lines {
                let lineStart = line.stringRange.location
                let lineEnd = line.stringRange.location + line.stringRange.length
                let s = max(aFrom, lineStart)
                let e = min(aTo, lineEnd)
                if e <= s { continue }
                let top = line.baselineOrigin.y - line.ascent
                // Clipping to blocks is not enough: a block can be far taller
                // than the screen — one paragraph of a long document runs to
                // hundreds of lines — and a highlight covering all of it makes
                // every one of those lines pass the character test above. The
                // two offset lookups are what a rect costs, so skip them here
                // rather than let the caller throw the rect away.
                if let clipY, top > clipY.upperBound || top + line.height < clipY.lowerBound { continue }
                let xStart = CTLineGetOffsetForStringIndex(line.ctLine, s, nil)
                let xEnd = CTLineGetOffsetForStringIndex(line.ctLine, e, nil)
                body(CGRect(x: line.baselineOrigin.x + xStart, y: top, width: xEnd - xStart, height: line.height),
                     block, s, e)
            }
        }
    }

    /// The document positions covered by the blocks that intersect `band`, or
    /// nil if the band falls outside the document entirely.
    ///
    /// Marks are stored as a flat list over the whole document, so drawing one
    /// kind of mark means walking all of them. This turns a band of the page
    /// into a range of positions once, so that walk can reject the off-screen
    /// ones on two integer compares instead of a geometry lookup each.
    func positionRange(intersecting band: ClosedRange<CGFloat>) -> Range<Int>? {
        var lo = 0, hi = blocks.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if blocks[mid].frame.maxY < band.lowerBound { lo = mid + 1 } else { hi = mid }
        }
        guard lo < blocks.count, blocks[lo].frame.minY <= band.upperBound else { return nil }
        var end = lo
        while end < blocks.count, blocks[end].frame.minY <= band.upperBound { end += 1 }
        return blocks[lo].contentStart ..< blocks[end - 1].contentEnd
    }

    /// Index of the block whose [contentStart, contentEnd] contains `pos`, via
    /// binary search (blocks are in document order, sorted by position).
    private func blockIndex(containing pos: Int) -> Int? {
        var lo = 0, hi = blocks.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let b = blocks[mid]
            if pos < b.contentStart { hi = mid - 1 }
            else if pos > b.contentEnd { lo = mid + 1 }
            else { return mid }
        }
        return nil
    }

    func blockContaining(_ pos: Int) -> TextBlock? {
        blockIndex(containing: pos).map { blocks[$0] }
    }

    private func nearestBlock(toPos pos: Int) -> TextBlock? {
        if let i = blockIndex(containing: pos) { return blocks[i] }
        guard !blocks.isEmpty else { return nil }
        // Binary-search the insertion point, then pick the nearer neighbour.
        var lo = 0, hi = blocks.count
        while lo < hi { let mid = (lo + hi) / 2; if blocks[mid].contentStart < pos { lo = mid + 1 } else { hi = mid } }
        let candidates = [lo - 1, lo].filter { $0 >= 0 && $0 < blocks.count }
        return candidates.min { abs(blocks[$0].contentStart - pos) < abs(blocks[$1].contentStart - pos) }.map { blocks[$0] }
    }

    // MARK: - Draw

    func draw(in ctx: CGContext, clipY: ClosedRange<CGFloat>? = nil,
              highlightRenderer: ((CGContext, [HighlightRun]) -> Void)? = nil) {
        func visible(_ minY: CGFloat, _ maxY: CGFloat) -> Bool {
            guard let clipY else { return true }
            return maxY >= clipY.lowerBound && minY <= clipY.upperBound
        }
        // `highlights` and `codeBackgrounds` cover the whole document, and a
        // document can carry one per paragraph. Asking `selectionRects` about
        // each of them costs a pair of binary searches even when the mark is
        // hundreds of screens away, which on a long document is most of the
        // time this method spends. Reject those on position first.
        var bandPos: Range<Int>?
        var bandIsEmpty = false
        if let clipY {
            if let r = positionRange(intersecting: clipY) { bandPos = r } else { bandIsEmpty = true }
        }
        func inBand(_ from: Int, _ to: Int) -> Bool {
            if bandIsEmpty { return false }
            guard let bandPos else { return true }
            return to > bandPos.lowerBound && from < bandPos.upperBound
        }
        // Decorations first (under text where they overlap, e.g. quote bars).
        for deco in decorations {
            switch deco {
            case let .fill(rect, color):
                guard visible(rect.minY, rect.maxY) else { continue }
                ctx.setFillColor(color.cgColor)
                ctx.fill(rect)
            case let .stroke(rect, color, w):
                guard visible(rect.minY, rect.maxY) else { continue }
                ctx.setStrokeColor(color.cgColor)
                ctx.setLineWidth(w)
                ctx.stroke(rect)
            case let .text(string, point, attrs):
                guard visible(point.y, point.y + 40) else { continue }
                let ns = NSAttributedString(string: string, attributes: attrs)
                ns.draw(at: point)
            case let .image(image, rect):
                guard visible(rect.minY, rect.maxY) else { continue }
                // A rounded picture is clipped rather than masked: the bytes are
                // drawn as they are and the corners simply aren't painted, which
                // costs nothing when the radius is 0 (the common case).
                if let radius = Self.imageCornerRadius(theme, in: rect) {
                    ctx.saveGState()
                    ctx.addPath(UIBezierPath(roundedRect: rect, cornerRadius: radius).cgPath)
                    ctx.clip()
                    image.draw(in: rect)
                    ctx.restoreGState()
                } else {
                    image.draw(in: rect)
                }
            case let .icon(image, rect):
                guard visible(rect.minY, rect.maxY) else { continue }
                image.draw(in: rect)
            case let .math(rendering, rect):
                guard visible(rect.minY, rect.maxY) else { continue }
                rendering.draw(ctx, rect.origin)
            case let .roundedFill(rect, color, radius):
                guard visible(rect.minY, rect.maxY) else { continue }
                color.setFill()
                UIBezierPath(roundedRect: rect, cornerRadius: radius).fill()
            case let .roundedStroke(rect, color, w, radius):
                guard visible(rect.minY, rect.maxY) else { continue }
                color.setStroke()
                let path = UIBezierPath(roundedRect: rect.insetBy(dx: w / 2, dy: w / 2), cornerRadius: radius)
                path.lineWidth = w
                path.stroke()
            case let .checkmark(rect, color, w):
                guard visible(rect.minY, rect.maxY) else { continue }
                let path = Self.checkmarkPath(in: rect)
                path.lineWidth = w
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                color.setStroke()
                path.stroke()
            }
        }
        // Inline-code background pills, behind the text. Always a flat rounded
        // fill (never routed through the host highlight renderer / ink effect).
        for code in codeBackgrounds where inBand(code.from, code.to) {
            for rect in selectionRects(from: code.from, to: code.to, clipY: clipY) where visible(rect.minY, rect.maxY) {
                code.color.setFill()
                UIBezierPath(roundedRect: rect.insetBy(dx: -theme.points(theme.code.inline.paddingX),
                                                       dy: -theme.points(theme.code.inline.paddingY)),
                             cornerRadius: theme.points(theme.code.inline.cornerRadius)).fill()
            }
        }
        // Highlight-mark backgrounds, behind the text (CoreText won't draw them).
        if let highlightRenderer {
            // Host-drawn (e.g. a textured "drying ink" effect): hand it the visible runs.
            var runs: [HighlightRun] = []
            for highlight in highlights where inBand(highlight.from, highlight.to) {
                forEachLineFragment(from: highlight.from, to: highlight.to, clipY: clipY) { rect, block, s, e in
                    guard visible(rect.minY, rect.maxY) else { return }
                    runs.append(HighlightRun(from: highlight.from, to: highlight.to,
                                             lineFrom: block.docPos(forAttrIndex: s),
                                             lineTo: block.docPos(forAttrIndex: e),
                                             rect: rect, color: highlight.color))
                }
            }
            if !runs.isEmpty { highlightRenderer(ctx, runs) }
        } else {
            for highlight in highlights where inBand(highlight.from, highlight.to) {
                for rect in selectionRects(from: highlight.from, to: highlight.to, clipY: clipY) where visible(rect.minY, rect.maxY) {
                    let r = rect.insetBy(dx: -1, dy: -1)
                    highlight.color.setFill()
                    UIBezierPath(roundedRect: r, cornerRadius: 3).fill()
                }
            }
        }
        // Text blocks via CoreText.
        for block in blocks where visible(block.frame.minY, block.frame.maxY) {
            for line in block.lines {
                ctx.textPosition = .zero
                ctx.textMatrix = .identity
                ctx.saveGState()
                ctx.translateBy(x: line.baselineOrigin.x, y: line.baselineOrigin.y)
                ctx.scaleBy(x: 1, y: -1)
                ctx.textPosition = .zero
                CTLineDraw(line.ctLine, ctx)
                ctx.restoreGState()
            }
        }
    }
}

/// Whether a string's base writing direction is right-to-left, decided by its
/// first strong directional character (Hebrew/Arabic blocks).
private func isRightToLeft(_ text: String) -> Bool {
    for scalar in text.unicodeScalars {
        let v = scalar.value
        // Hebrew, Arabic, Syriac, Thaana, and Arabic presentation forms.
        if (0x0590...0x05FF).contains(v) || (0x0600...0x07BF).contains(v)
            || (0x08A0...0x08FF).contains(v) || (0xFB1D...0xFDFF).contains(v) || (0xFE70...0xFEFF).contains(v) {
            return true
        }
        // A strong LTR letter ends the search.
        if (0x0041...0x005A).contains(v) || (0x0061...0x007A).contains(v) || (0x00C0...0x024F).contains(v) {
            return false
        }
    }
    return false
}

/// Holds an inline atom's reserved metrics for its CoreText run delegate.
private final class AtomRunBox {
    let width: CGFloat
    let ascent: CGFloat
    let descent: CGFloat
    init(width: CGFloat, ascent: CGFloat, descent: CGFloat) {
        self.width = width
        self.ascent = ascent
        self.descent = descent
    }
}

/// Build a CoreText run delegate that reserves a box of the given metrics, so
/// the typesetter lays out around an inline atom it can't measure itself.
private func makeBoxRunDelegate(width: CGFloat, ascent: CGFloat, descent: CGFloat) -> CTRunDelegate {
    let box = AtomRunBox(width: width, ascent: ascent, descent: descent)
    var callbacks = unsafe CTRunDelegateCallbacks(
        version: kCTRunDelegateCurrentVersion,
        dealloc: { refCon in unsafe Unmanaged<AtomRunBox>.fromOpaque(refCon).release() },
        getAscent: { refCon in unsafe Unmanaged<AtomRunBox>.fromOpaque(refCon).takeUnretainedValue().ascent },
        getDescent: { refCon in unsafe Unmanaged<AtomRunBox>.fromOpaque(refCon).takeUnretainedValue().descent },
        getWidth: { refCon in unsafe Unmanaged<AtomRunBox>.fromOpaque(refCon).takeUnretainedValue().width })
    return unsafe CTRunDelegateCreate(&callbacks, Unmanaged.passRetained(box).toOpaque())!
}

/// An inline image hangs from the baseline, so it reserves height above it only.
private func makeImageRunDelegate(_ size: CGSize) -> CTRunDelegate {
    makeBoxRunDelegate(width: size.width, ascent: size.height, descent: 0)
}
#endif

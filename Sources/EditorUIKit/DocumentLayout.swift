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

/// A laid-out text block (paragraph, heading, code block, list-item paragraph).
struct TextBlock {
    let contentStart: Int          // doc position of the first inline position
    let contentEnd: Int            // doc position after the last inline position
    let frame: CGRect              // text frame in view coordinates
    let lines: [LineLayout]
    let segments: [Segment]
    let attributed: NSAttributedString

    func attrIndex(forDocPos pos: Int) -> Int {
        for seg in segments where pos >= seg.docStart && pos <= seg.docStart + seg.docLen {
            if let text = seg.text {
                // Grapheme offset → UTF-16 index within the run.
                let graphemeOffset = pos - seg.docStart
                let prefix = String(text.prefix(graphemeOffset))
                return seg.attrStart + (prefix as NSString).length
            }
            return pos <= seg.docStart ? seg.attrStart : seg.attrStart + seg.attrLen
        }
        return segments.last.map { $0.attrStart + $0.attrLen } ?? 0
    }

    func docPos(forAttrIndex index: Int) -> Int {
        for seg in segments where index >= seg.attrStart && index <= seg.attrStart + seg.attrLen {
            if let text = seg.text {
                // UTF-16 index → grapheme offset within the run.
                let utf16Offset = index - seg.attrStart
                let ns = text as NSString
                let prefix = ns.substring(to: min(utf16Offset, ns.length))
                return seg.docStart + prefix.count
            }
            return index < seg.attrStart + (seg.attrLen + 1) / 2 ? seg.docStart : seg.docStart + seg.docLen
        }
        return contentEnd
    }
}

/// A non-text drawing primitive (rule, list marker, quote bar, box).
enum DecorationItem {
    case fill(CGRect, UIColor)
    case text(String, CGPoint, [NSAttributedString.Key: Any])
    case stroke(CGRect, UIColor, CGFloat)
    case image(UIImage, CGRect)
    case roundedFill(CGRect, UIColor, CGFloat)
    case roundedStroke(CGRect, UIColor, CGFloat, CGFloat)
    case checkmark(CGRect, UIColor, CGFloat)
}

/// A text block typeset in local coordinates (block top at y = 0), cached and
/// reused across layouts so unchanged blocks don't re-run CoreText line breaking
/// — the expensive per-keystroke cost on large documents.
struct LocalTextBlock {
    let lines: [LineLayout]   // baselineOrigin relative to (0, 0)
    let segments: [Segment]
    let attributed: NSAttributedString
    let height: CGFloat
    let imageAtoms: [(attrIndex: Int, image: UIImage, size: CGSize)]
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
    }
    private struct Entry {
        let node: Node // retains the keyed buffer
        let block: LocalTextBlock
        var generation: Int
    }
    private var entries: [Key: Entry] = [:]
    private var generation = 0

    var debugEntryCount: Int { entries.count }

    private static func key(_ node: Node, _ width: CGFloat) -> Key {
        let buffer = node.content.content.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
        return Key(type: ObjectIdentifier(node.type), attrs: node.attrs, marks: node.marks,
                   buffer: buffer, width: width)
    }

    func lookup(_ node: Node, width: CGFloat) -> LocalTextBlock? {
        let key = Self.key(node, width)
        guard var entry = entries[key] else { return nil }
        entry.generation = generation
        entries[key] = entry
        return entry.block
    }
    func store(_ node: Node, width: CGFloat, _ block: LocalTextBlock) {
        entries[Self.key(node, width)] = Entry(node: node, block: block, generation: generation)
    }
    func beginPass() { generation += 1 }
    /// Drop everything (e.g. when the syntax highlighter changes).
    func clear() { entries.removeAll() }
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
    let theme: TextTheme
    let width: CGFloat
    private(set) var height: CGFloat = 0
    private(set) var blocks: [TextBlock] = []
    private(set) var decorations: [DecorationItem] = []
    /// Tappable task-item checkboxes: their hit rect, the task item's document
    /// position, and current checked state.
    private(set) var checkboxes: [(rect: CGRect, pos: Int, checked: Bool)] = []
    /// Highlight-mark ranges (document positions) and their colors, drawn as a
    /// background behind the text (CoreText ignores `.backgroundColor`).
    private(set) var highlights: [(from: Int, to: Int, color: UIColor)] = []
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
        let highlights: [(from: Int, to: Int, color: UIColor)]
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

    init(doc: Node, width: CGFloat, theme: TextTheme, imageProvider: @escaping (Node) -> UIImage? = { _ in nil },
         blockCache: TextBlockLayoutCache? = nil, previous: DocumentLayout? = nil,
         realizeWindow: ClosedRange<CGFloat>? = nil, syntaxHighlighter: SyntaxHighlighter? = nil,
         codeLanguageLabel: ((String, String?) -> String?)? = nil) {
        self.theme = theme
        self.width = width
        self.imageProvider = imageProvider
        self.blockCache = blockCache
        self.syntaxHighlighter = syntaxHighlighter
        self.codeLanguageLabel = codeLanguageLabel
        blockCache?.beginPass()
        let contentWidth = width - theme.pageInsets.left - theme.pageInsets.right
        let x = theme.pageInsets.left
        if let previous, previous.width == width, let (front, back) = diff(doc, previous), front + back > 0 {
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
        return (front, back)
    }

    private func buildFull(_ doc: Node, x: CGFloat, width contentWidth: CGFloat) {
        var y = theme.pageInsets.top
        var pos = 0
        for i in 0..<doc.childCount {
            entries.append(layoutTopChild(doc.child(i), docPos: pos, x: x, width: contentWidth, y: &y, isFirst: i == 0))
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
            entries.append(layoutTopChild(doc.child(i), docPos: pos, x: x, width: contentWidth, y: &y, isFirst: i == 0))
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
    private func layoutTopChild(_ child: Node, docPos: Int, x: CGFloat, width: CGFloat, y: inout CGFloat, isFirst: Bool) -> TopEntry {
        let topY = y
        let (b0, d0, c0, h0, t0) = (blocks.count, decorations.count, checkboxes.count, highlights.count, tables.count)
        y += theme.spacingBefore(child, isFirst: isFirst)
        y = layoutBlock(child, docPos: docPos, x: x, width: width, y: y)
        return TopEntry(node: child, docStart: docPos, topY: topY, height: y - topY,
                        blocks: Array(blocks[b0...]), decorations: Array(decorations[d0...]),
                        checkboxes: Array(checkboxes[c0...]), highlights: Array(highlights[h0...]),
                        tables: Array(tables[t0...]))
    }

    private func append(_ e: TopEntry) {
        blocks += e.blocks; decorations += e.decorations; checkboxes += e.checkboxes
        highlights += e.highlights; tables += e.tables
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
                        highlights: e.highlights.isEmpty ? e.highlights : e.highlights.map { (from: $0.from + dPos, to: $0.to + dPos, color: $0.color) },
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
            let spacing = theme.spacingBefore(child, isFirst: i == 0)
            let estimated = spacing + estimatedContentHeight(of: child)
            // Realize if the child's (estimated) span is anywhere near the window.
            if y + estimated >= window.lowerBound && y <= window.upperBound {
                entries.append(layoutTopChild(child, docPos: pos, x: x, width: contentWidth, y: &y, isFirst: i == 0))
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
        let font = theme.blockFont(child)
        let lineHeight = font.lineHeight + theme.lineSpacing
        let avgChar = max(font.pointSize * 0.5, 1)
        let usableWidth = max(width - theme.pageInsets.left - theme.pageInsets.right, avgChar)
        let charsPerLine = max(Int(usableWidth / avgChar), 1)
        let textLength = max(child.textContent.count, 1)
        let lines = Int(ceil(Double(textLength) / Double(charsPerLine)))
        return CGFloat(max(lines, 1)) * lineHeight + theme.paragraphSpacing
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
        entries = []; blocks = []; decorations = []; checkboxes = []; highlights = []; tables = []; pendingImages = []
        let x = theme.pageInsets.left
        let contentWidth = width - theme.pageInsets.left - theme.pageInsets.right
        var y = theme.pageInsets.top
        for (i, e) in old.enumerated() {
            if e.estimated, y + e.height >= window.lowerBound, y <= window.upperBound {
                entries.append(layoutTopChild(e.node, docPos: e.docStart, x: x, width: contentWidth, y: &y, isFirst: i == 0))
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
        case let .roundedFill(r, c, rad): return .roundedFill(r.offsetBy(dx: 0, dy: dy), c, rad)
        case let .roundedStroke(r, c, w, rad): return .roundedStroke(r.offsetBy(dx: 0, dy: dy), c, w, rad)
        case let .checkmark(r, c, w): return .checkmark(r.offsetBy(dx: 0, dy: dy), c, w)
        }
    }

    // MARK: - Layout

    @discardableResult
    private func layoutFragment(_ fragment: Fragment, docPos: Int, x: CGFloat, width: CGFloat, y: CGFloat, isFirst firstArg: Bool) -> CGFloat {
        var y = y
        var pos = docPos
        var isFirst = firstArg
        for i in 0..<fragment.childCount {
            let child = fragment.child(i)
            y += theme.spacingBefore(child, isFirst: isFirst)
            isFirst = false
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
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: theme.codeColor]
        let textSize = (label as NSString).size(withAttributes: attrs)
        let padX: CGFloat = 6, padY: CGFloat = 2
        let badge = CGRect(x: frame.maxX - textSize.width - padX * 2, y: frame.minY,
                           width: textSize.width + padX * 2, height: textSize.height + padY * 2)
        decorations.append(.roundedFill(badge, theme.quoteBarColor.withAlphaComponent(0.25), 4))
        decorations.append(.text(label, CGPoint(x: badge.minX + padX, y: badge.minY + padY), attrs))
    }

    private func layoutBlock(_ node: Node, docPos: Int, x: CGFloat, width: CGFloat, y: CGFloat) -> CGFloat {
        switch node.type.name {
        case "codeBlock":
            let endY = layoutTextBlock(node, docPos: docPos, x: x, width: width, y: y)
            addCodeLanguageBadge(node, blockFrame: blocks.last?.frame)
            return endY
        case "paragraph", "heading":
            return layoutTextBlock(node, docPos: docPos, x: x, width: width, y: y)
        case "blockquote":
            let barX = x
            let innerX = x + theme.quoteIndent
            let startY = y
            let endY = layoutFragment(node.content, docPos: docPos + 1, x: innerX, width: width - theme.quoteIndent, y: y, isFirst: true)
            decorations.append(.fill(CGRect(x: barX, y: startY, width: 3, height: endY - startY), theme.quoteBarColor))
            return endY
        case "bulletList", "orderedList":
            return layoutList(node, docPos: docPos, x: x, width: width, y: y)
        case "taskList":
            return layoutTaskList(node, docPos: docPos, x: x, width: width, y: y)
        case "listItem", "taskItem":
            return layoutFragment(node.content, docPos: docPos + 1, x: x, width: width, y: y, isFirst: true)
        case "horizontalRule":
            let lineY = y + 8
            decorations.append(.fill(CGRect(x: x, y: lineY, width: width, height: 1), theme.quoteBarColor))
            return lineY + 9
        case "image":
            let src = node.attrs["src"]?.stringValue ?? ""
            // An explicit width attr (drag-to-resize) wins, always capped to the
            // content area; otherwise fall back to the natural width.
            let attrWidth = node.attrs["width"]?.intValue.map { CGFloat($0) }
            if let image = imageProvider(node) {
                let target = attrWidth ?? image.size.width
                let displayWidth = min(max(target, 1), width)
                let scale = image.size.width > 0 ? displayWidth / image.size.width : 1
                let size = CGSize(width: displayWidth, height: image.size.height * scale)
                decorations.append(.image(image, CGRect(x: x, y: y, width: size.width, height: size.height)))
                return y + size.height
            }
            let h: CGFloat = 120
            let displayWidth = min(max(attrWidth ?? 200, 1), width)
            decorations.append(.stroke(CGRect(x: x, y: y, width: displayWidth, height: h), theme.quoteBarColor, 1))
            let alt = node.attrs["alt"]?.stringValue ?? src
            decorations.append(.text("🖼 \(alt)", CGPoint(x: x + 8, y: y + 8), [.font: theme.bodyFont, .foregroundColor: theme.codeColor]))
            if !src.isEmpty { pendingImages.append(node) }
            return y + h
        case "table":
            return layoutTable(node, docPos: docPos, x: x, width: width, y: y)
        default:
            return layoutFragment(node.content, docPos: docPos + 1, x: x, width: width, y: y, isFirst: true)
        }
    }

    private func layoutList(_ node: Node, docPos: Int, x: CGFloat, width: CGFloat, y: CGFloat) -> CGFloat {
        var y = y
        var pos = docPos + 1
        let ordered = node.type.name == "orderedList"
        let start = node.attrs["order"]?.intValue ?? 1
        let markerAttrs: [NSAttributedString.Key: Any] = [.font: theme.bodyFont, .foregroundColor: theme.textColor]
        for i in 0..<node.childCount {
            let item = node.child(i)
            y += theme.spacingBefore(item, isFirst: i == 0)
            // The marker sits on the first line of the item's content, right-
            // aligned in the indent gutter.
            let marker = ordered ? "\(start + i)." : "•"
            let markerWidth = (marker as NSString).size(withAttributes: markerAttrs).width
            let markerX = x + theme.listIndent - markerWidth - 8
            decorations.append(.text(marker, CGPoint(x: markerX, y: y), markerAttrs))
            y = layoutFragment(item.content, docPos: pos + 1, x: x + theme.listIndent, width: width - theme.listIndent, y: y, isFirst: true)
            pos += item.nodeSize
        }
        return y
    }

    private func layoutTaskList(_ node: Node, docPos: Int, x: CGFloat, width: CGFloat, y: CGFloat) -> CGFloat {
        var y = y
        var pos = docPos + 1
        let boxSize: CGFloat = 18
        for i in 0..<node.childCount {
            let item = node.child(i)
            let checked = item.attrs["checked"]?.boolValue ?? false
            y += theme.spacingBefore(item, isFirst: i == 0)
            let boxRect = CGRect(x: x + theme.listIndent - boxSize - 8, y: y + 1, width: boxSize, height: boxSize)
            // The checkbox itself is a managed UIView (see EditorTextView's
            // checkbox-view recycling) positioned over this rect — the layout
            // only reserves its (touch-padded) box for positioning + hit-test.
            checkboxes.append((rect: boxRect.insetBy(dx: -6, dy: -6), pos: pos, checked: checked))
            y = layoutFragment(item.content, docPos: pos + 1, x: x + theme.listIndent, width: width - theme.listIndent, y: y, isFirst: true)
            pos += item.nodeSize
        }
        return y
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
        let padding: CGFloat = 6
        var pos = docPos + 1 // inside the table, before the first row
        for r in 0..<rows {
            let row = node.child(r)
            var cellPos = pos + 1 // inside the row, before the first cell
            var rowHeight: CGFloat = 28
            // Lay each cell's content out as real text blocks so the cell is
            // clickable, caret-able, and editable (top-aligned within the cell).
            for c in 0..<row.childCount {
                let cell = row.child(c)
                let cellX = edges[min(c, edges.count - 1)]
                let cellW = c < widths.count ? widths[c] : (width / CGFloat(max(cols, 1)))
                let bottom = layoutFragment(cell.content, docPos: cellPos + 1,
                                            x: cellX + padding, width: cellW - 2 * padding,
                                            y: y0 + padding, isFirst: true)
                rowHeight = max(rowHeight, bottom - y0 + padding)
                cellPos += cell.nodeSize
            }
            // Cell borders, drawn under the text.
            for c in 0..<row.childCount {
                let cellX = edges[min(c, edges.count - 1)]
                let cellW = c < widths.count ? widths[c] : (width / CGFloat(max(cols, 1)))
                decorations.append(.stroke(CGRect(x: cellX, y: y0, width: cellW, height: rowHeight), theme.quoteBarColor, 1))
            }
            y0 += rowHeight
            pos += row.nodeSize
        }
        // Record the table geometry so the view can hit-test column borders.
        tables.append(TableInfo(tablePos: docPos, originX: x, widths: widths, top: y, bottom: y0))
        return y0 + 6
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
        let local = blockCache?.lookup(node, width: width) ?? {
            let built = typesetBlock(node, contentStart: contentStart, width: width)
            blockCache?.store(node, width: width, built)
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

        let frame = CGRect(x: x, y: y, width: width, height: local.height)
        blocks.append(TextBlock(
            contentStart: contentStart,
            contentEnd: contentStart + node.content.size,
            frame: frame,
            lines: lines,
            segments: local.segments.isEmpty ? [Segment(docStart: contentStart, docLen: 0, attrStart: 0, attrLen: 0, text: "")] : local.segments,
            attributed: local.attributed))
        return y + local.height
    }

    /// Typeset a text block in LOCAL coordinates (top at y = 0), independent of
    /// its eventual position — cacheable by (node, width).
    private func typesetBlock(_ node: Node, contentStart: Int, width: CGFloat) -> LocalTextBlock {
        let (attr, segments, imageAtoms) = buildAttributed(node, contentStart: contentStart, width: width)
        let rtl = isRightToLeft(attr.string)
        let base = NSMutableAttributedString(attributedString:
            attr.length == 0 ? NSAttributedString(string: " ", attributes: [.font: theme.blockFont(node)]) : attr)
        let para = NSMutableParagraphStyle()
        para.baseWritingDirection = rtl ? .rightToLeft : .leftToRight
        para.alignment = rtl ? .right : .natural
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
            CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading)
            let lineHeight = ascent + descent + leading + theme.lineSpacing
            let penOffset = rtl ? CGFloat(CTLineGetPenOffsetForFlush(ctLine, 1, Double(width))) : 0
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
            let lineHeight = ascent + descent + theme.lineSpacing
            let empty = CTLineCreateWithAttributedString(NSAttributedString(string: "", attributes: [.font: font]))
            lines.append(LineLayout(ctLine: empty, baselineOrigin: CGPoint(x: 0, y: lineY + ascent),
                                    stringRange: NSRange(location: length, length: 0), height: lineHeight, ascent: ascent))
            lineY += lineHeight
        }
        return LocalTextBlock(lines: lines, segments: segments, attributed: base, height: lineY, imageAtoms: imageAtoms)
    }

    private func buildAttributed(_ node: Node, contentStart: Int, width: CGFloat) -> (NSMutableAttributedString, [Segment], [(attrIndex: Int, image: UIImage, size: CGSize)]) {
        let result = NSMutableAttributedString()
        var segments: [Segment] = []
        var imageAtoms: [(attrIndex: Int, image: UIImage, size: CGSize)] = []
        let blockFont = theme.blockFont(node)
        var docPos = contentStart

        func appendText(_ text: String, marks: [Mark]) {
            let attrs = node.type.name == "codeBlock"
                ? [NSAttributedString.Key.font: theme.monoFont, .foregroundColor: theme.textColor]
                : theme.attributes(for: marks, baseFont: blockFont)
            // Highlight marks paint a background behind the run (drawn separately
            // since CoreText ignores `.backgroundColor`).
            if let mark = marks.first(where: { $0.type.name == "highlight" }), !text.isEmpty {
                highlights.append((from: docPos, to: docPos + text.count,
                                   color: theme.highlightColor(mark.attrs["color"]?.stringValue)))
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
            } else if child.type.name == "image", let image = imageProvider(child) {
                // Inline image: reserve its (scaled) box via a run delegate, and
                // record it to draw at its run position after line breaking.
                let maxWidth = min(width, image.size.width)
                let scale = image.size.width > 0 ? maxWidth / image.size.width : 1
                let size = CGSize(width: maxWidth, height: image.size.height * scale)
                let delegate = makeImageRunDelegate(size)
                let attrStart = result.length
                result.append(NSAttributedString(string: "\u{fffc}", attributes: [kCTRunDelegateAttributeName as NSAttributedString.Key: delegate]))
                imageAtoms.append((attrIndex: attrStart, image: image, size: size))
                segments.append(Segment(docStart: docPos, docLen: 1, attrStart: attrStart, attrLen: 1, text: nil))
                docPos += 1
            } else {
                // wikiLink, or an image still loading: show a text placeholder.
                let display = child.type.name == "wikiLink"
                    ? (child.attrs["label"]?.stringValue ?? child.attrs["target"]?.stringValue ?? "link")
                    : "🖼"
                let atomAttrs: [NSAttributedString.Key: Any] = child.type.name == "wikiLink"
                    ? [.font: blockFont, .foregroundColor: theme.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
                    : [.font: blockFont, .foregroundColor: theme.codeColor]
                let attrStart = result.length
                result.append(NSAttributedString(string: display, attributes: atomAttrs))
                segments.append(Segment(docStart: docPos, docLen: 1, attrStart: attrStart, attrLen: (display as NSString).length, text: nil))
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
            for token in highlighter(code, node.attrs["language"]?.stringValue) {
                guard let lo = code.index(code.startIndex, offsetBy: token.range.lowerBound, limitedBy: code.endIndex),
                      let hi = code.index(code.startIndex, offsetBy: token.range.upperBound, limitedBy: code.endIndex),
                      lo < hi else { continue }
                let nsRange = NSRange(lo..<hi, in: code)
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
        return (result, segments, imageAtoms)
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
        // The target line's range includes a trailing hard break ("\n"); the
        // index AFTER it is the NEXT line's start, which would bounce the caret
        // straight back (the "stuck" arrow). Clamp to before that break.
        let lineEnd = target.line.stringRange.location + target.line.stringRange.length
        if attr >= lineEnd, lineEnd > target.line.stringRange.location,
           let scalar = Unicode.Scalar((target.block.attributed.string as NSString).character(at: lineEnd - 1)),
           CharacterSet(charactersIn: "\n\r\u{2028}\u{2029}").contains(scalar) {
            attr = lineEnd - 1
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
            block = blocks.min(by: { abs($0.frame.midY - point.y) < abs($1.frame.midY - point.y) })!
        }
        // Find the line.
        let line = block.lines.first { point.y >= $0.baselineOrigin.y - $0.ascent && point.y <= $0.baselineOrigin.y - $0.ascent + $0.height }
            ?? block.lines.min(by: { abs($0.baselineOrigin.y - point.y) < abs($1.baselineOrigin.y - point.y) })
        guard let line else { return block.contentStart }
        let relative = CGPoint(x: point.x - line.baselineOrigin.x, y: 0)
        let attrIndex = CTLineGetStringIndexForPosition(line.ctLine, relative)
        return block.docPos(forAttrIndex: attrIndex)
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
    func selectionRects(from: Int, to: Int) -> [CGRect] {
        guard to > from, !blocks.isEmpty else { return [] }
        var rects: [CGRect] = []
        // First block overlapping [from, to): smallest index with contentEnd > from.
        var lo = 0, hi = blocks.count
        while lo < hi { let mid = (lo + hi) / 2; if blocks[mid].contentEnd <= from { lo = mid + 1 } else { hi = mid } }
        var i = lo
        while i < blocks.count, blocks[i].contentStart < to {
            let block = blocks[i]
            i += 1
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
                let xStart = CTLineGetOffsetForStringIndex(line.ctLine, s, nil)
                let xEnd = CTLineGetOffsetForStringIndex(line.ctLine, e, nil)
                let top = line.baselineOrigin.y - line.ascent
                rects.append(CGRect(x: line.baselineOrigin.x + xStart, y: top, width: xEnd - xStart, height: line.height))
            }
        }
        return rects
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

    func draw(in ctx: CGContext, clipY: ClosedRange<CGFloat>? = nil) {
        func visible(_ minY: CGFloat, _ maxY: CGFloat) -> Bool {
            guard let clipY else { return true }
            return maxY >= clipY.lowerBound && minY <= clipY.upperBound
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
                image.draw(in: rect)
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
        // Highlight-mark backgrounds, behind the text (CoreText won't draw them).
        for highlight in highlights {
            for rect in selectionRects(from: highlight.from, to: highlight.to) where visible(rect.minY, rect.maxY) {
                let r = rect.insetBy(dx: -1, dy: -1)
                highlight.color.setFill()
                UIBezierPath(roundedRect: r, cornerRadius: 3).fill()
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

/// Holds an inline image's reserved size for its CoreText run delegate.
private final class ImageRunBox {
    let size: CGSize
    init(_ size: CGSize) { self.size = size }
}

/// Build a CoreText run delegate that reserves a box of the given size for an
/// inline image, so the typesetter lays out around it.
private func makeImageRunDelegate(_ size: CGSize) -> CTRunDelegate {
    let box = ImageRunBox(size)
    var callbacks = CTRunDelegateCallbacks(
        version: kCTRunDelegateCurrentVersion,
        dealloc: { refCon in Unmanaged<ImageRunBox>.fromOpaque(refCon).release() },
        getAscent: { refCon in Unmanaged<ImageRunBox>.fromOpaque(refCon).takeUnretainedValue().size.height },
        getDescent: { _ in CGFloat(0) },
        getWidth: { refCon in Unmanaged<ImageRunBox>.fromOpaque(refCon).takeUnretainedValue().size.width })
    return CTRunDelegateCreate(&callbacks, Unmanaged.passRetained(box).toOpaque())!
}
#endif

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
    /// Image sources referenced by the document that the provider didn't have
    /// cached — the view loads these and rebuilds.
    private(set) var pendingImageSources: [String] = []
    private let imageProvider: (String) -> UIImage?

    init(doc: Node, width: CGFloat, theme: TextTheme, imageProvider: @escaping (String) -> UIImage? = { _ in nil }) {
        self.theme = theme
        self.width = width
        self.imageProvider = imageProvider
        let contentWidth = width - theme.pageInsets.left - theme.pageInsets.right
        var y = theme.pageInsets.top
        y = layoutFragment(doc.content, docPos: 0, x: theme.pageInsets.left, width: contentWidth, y: y, isFirst: true)
        height = y + theme.pageInsets.bottom
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

    private func layoutBlock(_ node: Node, docPos: Int, x: CGFloat, width: CGFloat, y: CGFloat) -> CGFloat {
        switch node.type.name {
        case "paragraph", "heading", "codeBlock":
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
            if let image = imageProvider(src) {
                // Scale to fit the content width, preserving aspect ratio.
                let maxWidth = min(width, image.size.width)
                let scale = image.size.width > 0 ? maxWidth / image.size.width : 1
                let size = CGSize(width: maxWidth, height: image.size.height * scale)
                decorations.append(.image(image, CGRect(x: x, y: y, width: size.width, height: size.height)))
                return y + size.height
            }
            let h: CGFloat = 120
            decorations.append(.stroke(CGRect(x: x, y: y, width: min(width, 200), height: h), theme.quoteBarColor, 1))
            let alt = node.attrs["alt"]?.stringValue ?? src
            decorations.append(.text("🖼 \(alt)", CGPoint(x: x + 8, y: y + 8), [.font: theme.bodyFont, .foregroundColor: theme.codeColor]))
            if !src.isEmpty { pendingImageSources.append(src) }
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
            // Checkbox: rounded square, filled + check glyph when checked.
            decorations.append(.stroke(boxRect.insetBy(dx: 1, dy: 1), checked ? theme.caretColor : theme.quoteBarColor, 1.5))
            if checked {
                decorations.append(.fill(boxRect.insetBy(dx: 1, dy: 1), theme.caretColor.withAlphaComponent(0.15)))
                decorations.append(.text("✓", CGPoint(x: boxRect.minX + 3, y: boxRect.minY), [.font: UIFont.systemFont(ofSize: boxSize - 4, weight: .bold), .foregroundColor: theme.caretColor]))
            }
            checkboxes.append((rect: boxRect.insetBy(dx: -6, dy: -6), pos: pos, checked: checked))
            y = layoutFragment(item.content, docPos: pos + 1, x: x + theme.listIndent, width: width - theme.listIndent, y: y, isFirst: true)
            pos += item.nodeSize
        }
        return y
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
        let colW = width / CGFloat(max(cols, 1))
        for r in 0..<rows {
            let row = node.child(r)
            var rowHeight: CGFloat = 0
            var cellLayouts: [(CGRect, CGFloat)] = []
            for c in 0..<row.childCount {
                let cell = row.child(c)
                let cellX = x + CGFloat(c) * colW
                let text = cell.textContent
                let attr = NSAttributedString(string: text, attributes: [.font: theme.bodyFont, .foregroundColor: theme.textColor])
                let h = max(28, ceil(attr.boundingRect(with: CGSize(width: colW - 12, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin], context: nil).height) + 12)
                cellLayouts.append((CGRect(x: cellX, y: y0, width: colW, height: h), 0))
                rowHeight = max(rowHeight, h)
                decorations.append(.text(text, CGPoint(x: cellX + 6, y: y0 + 6), [.font: theme.bodyFont, .foregroundColor: theme.textColor]))
            }
            for c in 0..<row.childCount {
                let cellX = x + CGFloat(c) * colW
                decorations.append(.stroke(CGRect(x: cellX, y: y0, width: colW, height: rowHeight), theme.quoteBarColor, 1))
            }
            y0 += rowHeight
        }
        return y0 + 6
    }

    private func layoutTextBlock(_ node: Node, docPos: Int, x: CGFloat, width: CGFloat, y: CGFloat) -> CGFloat {
        let contentStart = docPos + 1
        let (attr, segments, imageAtoms) = buildAttributed(node, contentStart: contentStart, width: width)
        // Determine the paragraph's base writing direction (RTL for Hebrew/Arabic).
        let rtl = isRightToLeft(attr.string)
        let base = NSMutableAttributedString(attributedString:
            attr.length == 0 ? NSAttributedString(string: " ", attributes: [.font: theme.blockFont(node)]) : attr)
        let para = NSMutableParagraphStyle()
        para.baseWritingDirection = rtl ? .rightToLeft : .leftToRight
        para.alignment = rtl ? .right : .natural
        base.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: base.length))
        let attrForLayout: NSAttributedString = base

        let typesetter = CTTypesetterCreateWithAttributedString(attrForLayout as CFAttributedString)
        let length = attrForLayout.length
        var lines: [LineLayout] = []
        var lineStart = 0
        var lineY = y
        var maxLineBottom = y
        while lineStart < length {
            let count = CTTypesetterSuggestLineBreak(typesetter, lineStart, Double(width))
            let range = CFRangeMake(lineStart, count)
            let ctLine = CTTypesetterCreateLine(typesetter, range)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading)
            let lineHeight = ascent + descent + leading + theme.lineSpacing
            // Right-align RTL lines so the text reads from the right edge.
            let penOffset = rtl ? CGFloat(CTLineGetPenOffsetForFlush(ctLine, 1, Double(width))) : 0
            let baseline = CGPoint(x: x + penOffset, y: lineY + ascent)
            lines.append(LineLayout(
                ctLine: ctLine,
                baselineOrigin: baseline,
                stringRange: NSRange(location: lineStart, length: count),
                height: lineHeight,
                ascent: ascent))
            lineY += lineHeight
            maxLineBottom = lineY
            lineStart += count
            if count == 0 { break }
        }

        // Draw inline images at their run positions.
        for atom in imageAtoms {
            guard let line = lines.first(where: { NSLocationInRange(atom.attrIndex, $0.stringRange) }) else { continue }
            let xOffset = CTLineGetOffsetForStringIndex(line.ctLine, atom.attrIndex, nil)
            let top = line.baselineOrigin.y - atom.size.height
            decorations.append(.image(atom.image, CGRect(x: line.baselineOrigin.x + xOffset, y: top, width: atom.size.width, height: atom.size.height)))
        }

        let frame = CGRect(x: x, y: y, width: width, height: maxLineBottom - y)
        blocks.append(TextBlock(
            contentStart: contentStart,
            contentEnd: contentStart + node.content.size,
            frame: frame,
            lines: lines,
            segments: segments.isEmpty ? [Segment(docStart: contentStart, docLen: 0, attrStart: 0, attrLen: 0, text: "")] : segments,
            attributed: attrForLayout))
        return maxLineBottom
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
            } else if child.type.name == "image", let src = child.attrs["src"]?.stringValue, let image = imageProvider(src) {
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
                    pendingImageSources.append(src)
                }
            }
        }
        return (result, segments, imageAtoms)
    }

    // MARK: - Geometry queries

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
        let line = block.lines.first { NSLocationInRange(attrIndex, $0.stringRange) || attrIndex == $0.stringRange.location + $0.stringRange.length } ?? block.lines.last
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
        // All lines across all blocks, in vertical order, tagged with their block.
        var entries: [(block: TextBlock, line: LineLayout)] = []
        for block in blocks {
            for line in block.lines { entries.append((block, line)) }
        }
        entries.sort { $0.line.baselineOrigin.y < $1.line.baselineOrigin.y }
        guard let block = blocks.first(where: { pos >= $0.contentStart && pos <= $0.contentEnd }) else { return nil }
        let attrIndex = block.attrIndex(forDocPos: pos)
        guard let current = entries.firstIndex(where: { entry in
            entry.block.contentStart == block.contentStart &&
                (NSLocationInRange(attrIndex, entry.line.stringRange)
                    || attrIndex == entry.line.stringRange.location + entry.line.stringRange.length)
        }) else { return nil }
        let targetIndex = up ? current - 1 : current + 1
        guard targetIndex >= 0, targetIndex < entries.count else { return nil }
        let target = entries[targetIndex]
        let relative = CGPoint(x: preferredX - target.line.baselineOrigin.x, y: 0)
        let attr = CTLineGetStringIndexForPosition(target.line.ctLine, relative)
        return target.block.docPos(forAttrIndex: attr)
    }

    /// The document position at the start or end of the *visual* line that
    /// contains `pos` (the wrapped line, not the whole textblock).
    func lineBoundary(from pos: Int, toEnd: Bool) -> Int? {
        guard let block = blocks.first(where: { pos >= $0.contentStart && pos <= $0.contentEnd }) else { return nil }
        let attrIndex = block.attrIndex(forDocPos: pos)
        guard let line = block.lines.first(where: {
            NSLocationInRange(attrIndex, $0.stringRange) || attrIndex == $0.stringRange.location + $0.stringRange.length
        }) else { return nil }
        let targetAttr = toEnd ? line.stringRange.location + line.stringRange.length : line.stringRange.location
        return block.docPos(forAttrIndex: targetAttr)
    }

    /// The document position nearest to a point in view coordinates.
    func position(at point: CGPoint) -> Int? {
        guard !blocks.isEmpty else { return nil }
        // Find the block whose vertical span contains the point (or nearest).
        let block = blocks.first { point.y >= $0.frame.minY && point.y <= $0.frame.maxY }
            ?? blocks.min(by: { abs($0.frame.midY - point.y) < abs($1.frame.midY - point.y) })!
        // Find the line.
        let line = block.lines.first { point.y >= $0.baselineOrigin.y - $0.ascent && point.y <= $0.baselineOrigin.y - $0.ascent + $0.height }
            ?? block.lines.min(by: { abs($0.baselineOrigin.y - point.y) < abs($1.baselineOrigin.y - point.y) })
        guard let line else { return block.contentStart }
        let relative = CGPoint(x: point.x - line.baselineOrigin.x, y: 0)
        let attrIndex = CTLineGetStringIndexForPosition(line.ctLine, relative)
        return block.docPos(forAttrIndex: attrIndex)
    }

    /// Selection highlight rectangles for a document range.
    func selectionRects(from: Int, to: Int) -> [CGRect] {
        guard to > from else { return [] }
        var rects: [CGRect] = []
        for block in blocks where from < block.contentEnd && to > block.contentStart {
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

    private func blockContaining(_ pos: Int) -> TextBlock? {
        blocks.first { pos >= $0.contentStart && pos <= $0.contentEnd }
    }

    private func nearestBlock(toPos pos: Int) -> TextBlock? {
        blocks.min(by: { abs($0.contentStart - pos) < abs($1.contentStart - pos) })
    }

    // MARK: - Draw

    func draw(in ctx: CGContext) {
        // Decorations first (under text where they overlap, e.g. quote bars).
        for deco in decorations {
            switch deco {
            case let .fill(rect, color):
                ctx.setFillColor(color.cgColor)
                ctx.fill(rect)
            case let .stroke(rect, color, w):
                ctx.setStrokeColor(color.cgColor)
                ctx.setLineWidth(w)
                ctx.stroke(rect)
            case let .text(string, point, attrs):
                let ns = NSAttributedString(string: string, attributes: attrs)
                ns.draw(at: point)
            case let .image(image, rect):
                image.draw(in: rect)
            }
        }
        // Text blocks via CoreText.
        for block in blocks {
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

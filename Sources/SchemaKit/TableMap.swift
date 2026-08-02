public import DocumentModel

// A Swift port of prosemirror-tables' tablemap.ts — a descriptive structure of a
// table node that accounts for col/row spans. Positions are table-relative (i.e.
// relative to the start of the table's content), so callers offset by the table's
// document start position.

/// A rectangle of cells, in column/row coordinates.
public struct TableRect: Equatable {
    public var left: Int, top: Int, right: Int, bottom: Int
    public init(left: Int, top: Int, right: Int, bottom: Int) {
        self.left = left; self.top = top; self.right = right; self.bottom = bottom
    }
}

/// A structural problem found while computing a table map (used by the normalizer).
public enum TableProblem {
    case colwidthMismatch(pos: Int, colwidth: [Int])
    case collision(pos: Int, row: Int, n: Int)
    case missing(row: Int, n: Int)
    case overlongRowspan(pos: Int, n: Int)
    case zeroSized
}

public enum TableAxis: Sendable { case horiz, vert }

// Cell attribute accessors (colspan/rowspan default 1; colwidth is an int array or nil).
func cellColspan(_ node: Node) -> Int { node.attrs["colspan"]?.intValue ?? 1 }
func cellRowspan(_ node: Node) -> Int { node.attrs["rowspan"]?.intValue ?? 1 }
func cellColwidth(_ node: Node) -> [Int]? {
    if case let .array(arr)? = node.attrs["colwidth"] { return arr.map { $0.intValue ?? 0 } }
    return nil
}

public final class TableMap: @unchecked Sendable {
    /// Number of columns.
    public let width: Int
    /// Number of rows.
    public let height: Int
    /// A width*height array with the start position (table-relative) of the cell
    /// covering each slot.
    public let map: [Int]
    public var problems: [TableProblem]?

    init(width: Int, height: Int, map: [Int], problems: [TableProblem]?) {
        self.width = width; self.height = height; self.map = map; self.problems = problems
    }

    /// The dimensions of the cell at the given position.
    public func findCell(_ pos: Int) -> TableRect {
        for i in map.indices where map[i] == pos {
            let left = i % width
            let top = i / width
            var right = left + 1
            var bottom = top + 1
            var j = 1
            while right < width && map[i + j] == pos { right += 1; j += 1 }
            j = 1
            while bottom < height && map[i + width * j] == pos { bottom += 1; j += 1 }
            return TableRect(left: left, top: top, right: right, bottom: bottom)
        }
        fatalError("No cell with offset \(pos) found")
    }

    /// The left column of the cell at the given position.
    public func colCount(_ pos: Int) -> Int {
        for i in map.indices where map[i] == pos { return i % width }
        fatalError("No cell with offset \(pos) found")
    }

    /// The next cell in the given direction from the cell at `pos`, if any.
    public func nextCell(_ pos: Int, _ axis: TableAxis, _ dir: Int) -> Int? {
        let r = findCell(pos)
        if axis == .horiz {
            if dir < 0 ? r.left == 0 : r.right == width { return nil }
            return map[r.top * width + (dir < 0 ? r.left - 1 : r.right)]
        } else {
            if dir < 0 ? r.top == 0 : r.bottom == height { return nil }
            return map[r.left + width * (dir < 0 ? r.top - 1 : r.bottom)]
        }
    }

    /// The rectangle spanning the two given cells.
    public func rectBetween(_ a: Int, _ b: Int) -> TableRect {
        let ra = findCell(a), rb = findCell(b)
        return TableRect(left: min(ra.left, rb.left), top: min(ra.top, rb.top),
                         right: max(ra.right, rb.right), bottom: max(ra.bottom, rb.bottom))
    }

    /// The positions of all cells whose top-left corner is in the given rectangle.
    public func cellsInRect(_ rect: TableRect) -> [Int] {
        var result: [Int] = []
        var seen = Set<Int>()
        for row in rect.top..<rect.bottom {
            for col in rect.left..<rect.right {
                let index = row * width + col
                let pos = map[index]
                if seen.contains(pos) { continue }
                seen.insert(pos)
                if (col == rect.left && col != 0 && map[index - 1] == pos) ||
                    (row == rect.top && row != 0 && map[index - width] == pos) {
                    continue
                }
                result.append(pos)
            }
        }
        return result
    }

    /// The position at which the cell at the given row/col starts (or would start).
    public func positionAt(_ row: Int, _ col: Int, _ table: Node) -> Int {
        var i = 0
        var rowStart = 0
        while true {
            let rowEnd = rowStart + table.child(i).nodeSize
            if i == row {
                var index = col + row * width
                let rowEndIndex = (row + 1) * width
                while index < rowEndIndex && map[index] < rowStart { index += 1 }
                return index == rowEndIndex ? rowEnd - 1 : map[index]
            }
            rowStart = rowEnd
            i += 1
        }
    }

    /// The table map for the given table node (recomputed each call).
    public static func get(_ table: Node) -> TableMap { computeMap(table) }
}

private func computeMap(_ table: Node) -> TableMap {
    precondition(table.type.name == "table", "Not a table node: \(table.type.name)")
    let width = findWidth(table)
    let height = table.childCount
    var map = [Int](repeating: 0, count: width * height)
    var mapPos = 0
    var problems: [TableProblem]?
    var colWidths: [Int?] = []
    func ensureColWidth(_ i: Int) { while colWidths.count <= i { colWidths.append(nil) } }

    var pos = 0
    for row in 0..<height {
        let rowNode = table.child(row)
        pos += 1
        var i = 0
        while true {
            while mapPos < map.count && map[mapPos] != 0 { mapPos += 1 }
            if i == rowNode.childCount { break }
            let cellNode = rowNode.child(i)
            let colspan = cellColspan(cellNode), rowspan = cellRowspan(cellNode)
            let colwidth = cellColwidth(cellNode)
            var h = 0
            while h < rowspan {
                if h + row >= height {
                    problems = (problems ?? []) + [.overlongRowspan(pos: pos, n: rowspan - h)]
                    break
                }
                let start = mapPos + h * width
                for w in 0..<colspan {
                    if map[start + w] == 0 { map[start + w] = pos }
                    else { problems = (problems ?? []) + [.collision(pos: pos, row: row, n: colspan - w)] }
                    let colW = (colwidth != nil && w < colwidth!.count) ? colwidth![w] : 0
                    if colW != 0 {
                        let widthIndex = ((start + w) % width) * 2
                        ensureColWidth(widthIndex + 1)
                        let prev = colWidths[widthIndex]
                        if prev == nil || (prev != colW && colWidths[widthIndex + 1] == 1) {
                            colWidths[widthIndex] = colW
                            colWidths[widthIndex + 1] = 1
                        } else if prev == colW {
                            colWidths[widthIndex + 1] = (colWidths[widthIndex + 1] ?? 0) + 1
                        }
                    }
                }
                h += 1
            }
            mapPos += colspan
            pos += cellNode.nodeSize
            i += 1
        }
        let expectedPos = (row + 1) * width
        var missing = 0
        while mapPos < expectedPos { if map[mapPos] == 0 { missing += 1 }; mapPos += 1 }
        if missing > 0 { problems = (problems ?? []) + [.missing(row: row, n: missing)] }
        pos += 1
    }

    if width == 0 || height == 0 { problems = (problems ?? []) + [.zeroSized] }

    let tableMap = TableMap(width: width, height: height, map: map, problems: problems)
    var badWidths = false
    var i = 0
    while !badWidths && i < colWidths.count {
        if colWidths[i] != nil && (colWidths[i + 1] ?? 0) < height { badWidths = true }
        i += 2
    }
    if badWidths { findBadColWidths(tableMap, colWidths, table) }
    return tableMap
}

private func findWidth(_ table: Node) -> Int {
    var width = -1
    var hasRowSpan = false
    for row in 0..<table.childCount {
        let rowNode = table.child(row)
        var rowWidth = 0
        if hasRowSpan {
            for j in 0..<row {
                let prevRow = table.child(j)
                for i in 0..<prevRow.childCount {
                    let cell = prevRow.child(i)
                    if j + cellRowspan(cell) > row { rowWidth += cellColspan(cell) }
                }
            }
        }
        for i in 0..<rowNode.childCount {
            let cell = rowNode.child(i)
            rowWidth += cellColspan(cell)
            if cellRowspan(cell) > 1 { hasRowSpan = true }
        }
        if width == -1 { width = rowWidth }
        else if width != rowWidth { width = max(width, rowWidth) }
    }
    return width
}

private func findBadColWidths(_ map: TableMap, _ colWidths: [Int?], _ table: Node) {
    if map.problems == nil { map.problems = [] }
    var seen = Set<Int>()
    for i in map.map.indices {
        let pos = map.map[i]
        if seen.contains(pos) { continue }
        seen.insert(pos)
        guard let node = table.nodeAt(pos) else { fatalError("No cell with offset \(pos) found") }
        var updated: [Int]?
        let colspan = cellColspan(node)
        for j in 0..<colspan {
            let col = (i + j) % map.width
            let widthIndex = col * 2
            let colWidth = widthIndex < colWidths.count ? colWidths[widthIndex] : nil
            if let colWidth {
                let existing = cellColwidth(node)
                if existing == nil || j >= existing!.count || existing![j] != colWidth {
                    if updated == nil { updated = freshColWidth(node) }
                    updated![j] = colWidth
                }
            }
        }
        if let updated {
            map.problems!.insert(.colwidthMismatch(pos: pos, colwidth: updated), at: 0)
        }
    }
}

private func freshColWidth(_ node: Node) -> [Int] {
    if let cw = cellColwidth(node) { return cw }
    return [Int](repeating: 0, count: cellColspan(node))
}

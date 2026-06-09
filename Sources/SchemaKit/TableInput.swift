import DocumentModel
import EditorStateKit
import EditorCommands

// Keyboard cell navigation/selection, ported from prosemirror-tables' input.ts.
// ProseMirror gates cell-exit on `view.endOfTextblock`; with no view here we
// approximate it with the cursor being at the textblock boundary (parentOffset),
// which is exact for single-line cells.

private func maybeSetSelection(_ state: EditorState, _ dispatch: Dispatch?, _ selection: Selection) -> Bool {
    if selection.eq(state.selection) { return false }
    if let dispatch { dispatch(state.tr.setSelection(selection).scrollIntoView()) }
    return true
}

/// If the cursor is at the edge of a cell (so further motion leaves it), return
/// the position before that cell; else nil.
private func atEndOfCell(_ state: EditorState, _ axis: TableAxis, _ dir: Int) -> Int? {
    guard let sel = state.selection as? TextSelection else { return nil }
    let head = sel.resolvedHead
    var d = head.depth - 1
    while d >= 0 {
        let parent = head.node(d)
        let index = dir < 0 ? head.index(d) : head.indexAfter(d)
        if index != (dir < 0 ? 0 : parent.childCount) { return nil }
        let role = tableRole(parent)
        if role == "cell" || role == "header_cell" {
            let cellPos = head.before(d)
            let atBoundary = dir < 0 ? head.parentOffset == 0 : head.parentOffset == head.parent.content.size
            return atBoundary ? cellPos : nil
        }
        d -= 1
    }
    return nil
}

/// Move the cursor by one cell in `axis`/`dir` when at a cell edge (else fall
/// through). Collapses a cell selection to its head.
public func tableArrow(_ axis: TableAxis, _ dir: Int) -> Command {
    { state, dispatch, _ in
        let sel = state.selection
        if let cs = sel as? CellSelection {
            return maybeSetSelection(state, dispatch, Selection.near(cs.headCell, dir))
        }
        if axis != .horiz && !sel.empty { return false }
        guard let end = atEndOfCell(state, axis, dir) else { return false }
        if axis == .horiz {
            return maybeSetSelection(state, dispatch, Selection.near(state.doc.resolve(sel.head + dir), dir))
        }
        let cell = state.doc.resolve(end)
        if let next = nextCell(cell, axis, dir) {
            return maybeSetSelection(state, dispatch, Selection.near(next, 1))
        } else if dir < 0 {
            return maybeSetSelection(state, dispatch, Selection.near(state.doc.resolve(cell.before(-1)), -1))
        } else {
            return maybeSetSelection(state, dispatch, Selection.near(state.doc.resolve(cell.after(-1)), 1))
        }
    }
}

/// Extend (or start) a cell selection by one cell in `axis`/`dir`.
public func tableShiftArrow(_ axis: TableAxis, _ dir: Int) -> Command {
    { state, dispatch, _ in
        let sel = state.selection
        let cellSel: CellSelection
        if let cs = sel as? CellSelection { cellSel = cs }
        else {
            guard let end = atEndOfCell(state, axis, dir) else { return false }
            cellSel = CellSelection(state.doc.resolve(end))
        }
        guard let head = nextCell(cellSel.headCell, axis, dir) else { return false }
        return maybeSetSelection(state, dispatch, CellSelection(cellSel.anchorCell, head))
    }
}

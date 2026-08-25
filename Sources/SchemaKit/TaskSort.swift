import DocumentModel
import DocumentTransform
public import EditorStateKit

// Apple Notes' "sort checked items automatically": checking a task drops it to
// the bottom of its list, and unchecking it puts it back where it was.
//
// The "where it was" is the whole design problem — the editor has to remember a
// position it no longer stores. It lives in plugin state for the session, keyed
// by the item's document position and carried across every transaction by the
// mapping, so the document itself is untouched: no attribute is added to
// `taskItem`, nothing new is written to a saved file, and a check that doesn't
// move anything costs no steps at all.
//
// Session-scoped is the deal that buys that. Reload a document and its checked
// items have no home to go back to — unchecking one leaves it where it is. So
// does unchecking after a redo, which replays the move as recorded steps that
// the mapping can't follow an entry through.
//
// The move takes one of two routes. A check made through `setTaskChecked` or
// `toggleTaskChecked` — which is every check a person makes, tapping a checkbox
// or pressing the shortcut — folds the reorder into the same transaction, so it
// is one dispatch, one undo step, and no second pass over the editor state. A
// check that arrives any other way (a collab step, a paste, a script setting the
// attribute) is caught by the plugin's `appendTransaction`, which does the same
// work in a transaction of its own. Same result either way; the first is about
// twice as cheap, which is why the common path takes it.

/// Options for the task-list extensions.
public struct TaskListOptions: Sendable {
    /// Move a task to the bottom of its list when it is checked, and back to
    /// where it came from when it is unchecked — Apple Notes' behaviour.
    ///
    /// Off by default. When off, nothing here is built: no plugin is installed,
    /// and no transaction pays for a check.
    public var sortCompletedToBottom: Bool

    public init(sortCompletedToBottom: Bool = false) {
        self.sortCompletedToBottom = sortCompletedToBottom
    }
}

/// Where each checked task item goes back to: the item's position in the
/// current document → the index it held in its list before it was checked.
public typealias TaskHomes = [Int: Int]

/// The homes a sorted task list is remembering, for anyone who wants to look.
public let taskSortKey = PluginKey<TaskHomes>("taskSort")

/// Set on a transaction that carries a reorder, holding the table that goes with
/// the result — a reorder moves entries the mapping can't follow, so whoever
/// does one hands the finished table over rather than letting it be mapped. It
/// also marks the transaction as already sorted.
let taskHomesMeta = "taskSortHomes"

// MARK: - The plugin

/// The plugin that keeps checked items at the bottom of their list.
///
/// It reacts to one thing only: a transaction that set a `checked` attribute and
/// didn't sort itself. Typing, pasting, and every other edit cost it a scan of
/// the transaction's steps — the handful a keystroke produces — and no document
/// traversal at all.
func taskSortPlugin() -> Plugin {
    Plugin(
        key: taskSortKey.key,
        stateField: PluginStateField(
            initialize: { _, _ in TaskHomes() },
            apply: { tr, value, _, newState in
                if let handed = tr.getMeta(taskHomesMeta) as? TaskHomes { return handed }
                var homes = value as? TaskHomes ?? [:]
                guard tr.docChanged else { return homes }
                if !homes.isEmpty {
                    var mapped = TaskHomes(minimumCapacity: homes.count)
                    for (pos, home) in homes {
                        let result = tr.mapping.mapResult(pos, 1)
                        if !result.deletedAfter { mapped[result.pos] = home }
                    }
                    homes = mapped
                }
                // Remember where anything just checked is standing, here rather
                // than in the reorder that may follow — a check at the bottom of
                // a list moves nothing, and shouldn't cost a transaction just to
                // write down where it was.
                for pos in checkedItemPositions([tr]) {
                    guard pos >= 0, pos < newState.doc.content.size else { continue }
                    // One resolve answers all three questions — is this a task
                    // item, is it checked, and where in its list is it — and a
                    // resolve down a long list is not free.
                    let resolved = newState.doc.resolve(pos)
                    guard resolved.parent.type.name == "taskList" else { continue }
                    let index = resolved.index()
                    guard resolved.parent.child(index).attrs["checked"]?.boolValue == true else { continue }
                    homes[pos] = index
                }
                return homes
            }),
        appendTransaction: { trs, _, newState in
            // The safety net: a check that arrived without going through
            // `sortTasksInPlace` — a collab step, a paste, a raw AttrStep.
            let positions = checkedItemPositions(trs)
            guard !positions.isEmpty else { return nil }
            let tr = newState.tr
            guard let table = sortTasks(into: tr, doc: newState.doc, selection: newState.selection,
                                        homes: taskSortKey.getState(newState) ?? [:],
                                        itemPositions: positions),
                  tr.docChanged else { return nil }
            return tr.setMeta(taskHomesMeta, table)
        })
}

/// The positions — in the document the batch produced — of the task items whose
/// `checked` attribute the batch set.
func checkedItemPositions(_ trs: [Transaction]) -> [Int] {
    var positions: [Int] = []
    for (ti, tr) in trs.enumerated() {
        // A transaction that sorted itself (see `sortTasksInPlace`) is done.
        if tr.getMeta(taskHomesMeta) != nil { continue }
        for (si, step) in tr.steps.enumerated() {
            guard let attrStep = step as? AttrStep, attrStep.attr == "checked" else { continue }
            // Through the rest of this transaction, then through the ones after it.
            var pos = tr.mapping.slice(si + 1).map(attrStep.pos, 1)
            for later in trs[(ti + 1)...] { pos = later.mapping.map(pos, 1) }
            positions.append(pos)
        }
    }
    return positions
}

/// Fold the reordering the given checks call for into `tr`: the steps that move
/// the items, and the table of homes the result implies. Returns that table, or
/// nil when there is nothing to do.
func sortTasks(into tr: Transaction, doc: Node, selection: Selection,
               homes: TaskHomes, itemPositions: [Int]) -> TaskHomes? {
    var table = homes
    var lists: [Int: (list: Node, changed: Set<Int>)] = [:]
    for pos in itemPositions {
        guard pos >= 0, pos < doc.content.size else { continue }
        // One resolve answers all of it — is this a task item, is it checked
        // now, and where in its list is it standing — and a resolve down a long
        // list is not free.
        let resolved = doc.resolve(pos)
        guard resolved.depth > 0, resolved.parent.type.name == "taskList" else { continue }
        let index = resolved.index()
        if resolved.parent.child(index).attrs["checked"]?.boolValue == true { table[pos] = index }
        var entry = lists[resolved.before()] ?? (resolved.parent, [])
        entry.changed.insert(index)
        lists[resolved.before()] = entry
    }
    guard !lists.isEmpty else { return nil }

    // Reordering a list neither adds nor removes content, so every position
    // outside the list it happens in survives it — the lists can be handled in
    // any order, against positions and a table all taken from one document.
    let stepsBefore = tr.steps.count
    var remaps: [ListRemap] = []
    for (listPos, entry) in lists {
        guard let sorted = sortList(tr, listPos: listPos, list: entry.list,
                                    changed: entry.changed, homes: table) else { continue }
        let content = listPos + 1 ..< listPos + 1 + entry.list.content.size
        table = table.filter { !content.contains($0.key) }
        table.merge(sorted.homes) { _, new in new }
        if let remap = sorted.remap { remaps.append(remap) }
    }
    guard tr.steps.count > stepsBefore else { return table == homes ? nil : table }
    restoreSelection(tr, selection, remaps)
    return table
}

/// Fold the reorder a just-made check calls for into the transaction making it,
/// so a tap on a checkbox is one transaction and one undo step instead of two.
/// A no-op unless the editor was built with `sortCompletedToBottom`.
public func sortTasksInPlace(_ tr: Transaction, _ state: EditorState) {
    guard let homes = taskSortKey.getState(state) else { return }
    let positions = checkedItemPositions([tr])
    guard !positions.isEmpty else { return }
    var mapped = TaskHomes(minimumCapacity: homes.count)
    for (pos, home) in homes {
        let result = tr.mapping.mapResult(pos, 1)
        if !result.deletedAfter { mapped[result.pos] = home }
    }
    guard let table = sortTasks(into: tr, doc: tr.doc, selection: tr.selection,
                                homes: mapped, itemPositions: positions) else { return }
    tr.setMeta(taskHomesMeta, table)
}

// MARK: - The order

/// Where a list's children should sit and what each one's home becomes.
/// `order` holds old indices in their new order; `home` is indexed by old index.
/// Nil when the list holds something that isn't a task item.
func taskSortPlan(_ list: Node, starts: [Int], changed: Set<Int>, homes: TaskHomes)
    -> (order: [Int], home: [Int?])? {
    let count = list.childCount
    var unchecked: [Int] = []       // in document order
    var settled: [Int] = []         // checked before this batch, already at the bottom
    var newlyChecked: [Int] = []    // checked by this batch — they go last
    var returning: [(home: Int, index: Int)] = []
    var home = [Int?](repeating: nil, count: count)

    for i in 0..<count {
        let child = list.child(i)
        guard child.type.name == "taskItem" else { return nil }
        let checked = child.attrs["checked"]?.boolValue ?? false
        let remembered = homes[starts[i]]
        switch (checked, changed.contains(i)) {
        case (true, true):
            // Just checked. Its home — where it was standing when it was
            // checked, after any item checked earlier had already moved down —
            // was written down as the transaction applied.
            home[i] = remembered
            newlyChecked.append(i)
        case (true, false):
            // Checked before this batch, or when the document was loaded. It
            // keeps whatever home it has (possibly none) and stays put.
            home[i] = remembered
            settled.append(i)
        case (false, true):
            // Just unchecked: go home, if this session remembers one.
            if let remembered { returning.append((remembered, i)) } else { unchecked.append(i) }
        case (false, false):
            unchecked.append(i)
        }
    }

    // Send each returning item home, lowest index first so several unchecked at
    // once keep their order relative to each other.
    for item in returning.sorted(by: { $0.home < $1.home }) {
        unchecked.insert(item.index, at: min(max(item.home, 0), unchecked.count))
    }
    return (unchecked + settled + newlyChecked, home)
}

// MARK: - Applying it

/// What a list's reorder did to positions inside it, so the selection can be
/// carried across a step that (as far as the mapping is concerned) deleted the
/// text the caret was in and inserted it again somewhere else.
struct ListRemap {
    let from: Int, to: Int
    let oldStarts: [Int], newStarts: [Int], sizes: [Int]
    let newIndexOfOld: [Int]

    /// The position `pos` moved to, or nil if it isn't inside a moved item.
    func map(_ pos: Int) -> Int? {
        guard pos > from, pos < to else { return nil }
        for i in oldStarts.indices where pos > oldStarts[i] && pos < oldStarts[i] + sizes[i] {
            return newStarts[newIndexOfOld[i]] + (pos - oldStarts[i])
        }
        return nil
    }
}

/// Reorder one list on `tr`, returning its new homes and — when the order
/// actually changed — how positions inside it moved. Only the span between the
/// first and last index that changed is replaced, so checking the last item of
/// a long list is a step over one item, not over the list.
func sortList(_ tr: Transaction, listPos: Int, list: Node, changed: Set<Int>, homes: TaskHomes)
    -> (remap: ListRemap?, homes: TaskHomes)? {
    let count = list.childCount
    var sizes = [Int](repeating: 0, count: count)
    var oldStarts = [Int](repeating: 0, count: count)
    var offset = listPos + 1
    for i in 0..<count {
        sizes[i] = list.child(i).nodeSize
        oldStarts[i] = offset
        offset += sizes[i]
    }
    guard let plan = taskSortPlan(list, starts: oldStarts, changed: changed, homes: homes) else { return nil }

    var newStarts = [Int](repeating: 0, count: count)
    var newIndexOfOld = [Int](repeating: 0, count: count)
    var newHomes = TaskHomes()
    var pos = listPos + 1
    var moved = false
    for i in 0..<count {
        let old = plan.order[i]
        newStarts[i] = pos
        newIndexOfOld[old] = i
        if let home = plan.home[old] { newHomes[pos] = home }
        pos += sizes[old]
        moved = moved || old != i
    }
    guard moved else { return (nil, newHomes) }

    var lo = 0
    while plan.order[lo] == lo { lo += 1 }
    var hi = count - 1
    while plan.order[hi] == hi { hi -= 1 }

    var nodes: [Node] = []
    nodes.reserveCapacity(hi - lo + 1)
    for i in lo...hi { nodes.append(list.child(plan.order[i])) }

    let from = oldStarts[lo], to = oldStarts[hi] + sizes[hi]
    let slice = Slice(content: Fragment.from(nodes), openStart: 0, openEnd: 0)
    guard (try? tr.step(ReplaceStep(from, to, slice))) != nil else { return nil }

    return (ListRemap(from: from, to: to, oldStarts: oldStarts, newStarts: newStarts,
                      sizes: sizes, newIndexOfOld: newIndexOfOld), newHomes)
}

/// Keep the caret in the text it was in. Without this the caret lands at the top
/// of the list every time you check the item you are typing in — the reorder is
/// a replace, and a replace drops what was inside it.
func restoreSelection(_ tr: Transaction, _ selection: Selection, _ remaps: [ListRemap]) {
    guard selection is TextSelection else { return }
    for remap in remaps {
        guard let anchor = remap.map(selection.anchor), let head = remap.map(selection.head) else { continue }
        tr.setSelection(TextSelection.create(tr.doc, anchor, head))
        return
    }
}

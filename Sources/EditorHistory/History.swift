import Foundation
import DocumentModel
import DocumentTransform
public import EditorStateKit

// A port of prosemirror-history. The history is not a stack of document
// snapshots: each branch (undo and redo) is a list of Items that always hold a
// position map and optionally an inverted step, so changes that must not be
// undoable (remote collab steps) can still be mapped through. An item that
// carries a selection bookmark starts an "event" — the group of changes one
// undo command reverts. Items are always preserved un-merged (upstream's
// `preserveItems` mode), since this editor ships with collab support that
// needs to rebase them.

struct HistoryItem {
    /// The (forward) step map for this item.
    let map: StepMap
    /// The inverted step, if this item holds an undoable change.
    let step: (any Step)?
    /// Set on the first item of an event: the selection before the event.
    let selection: (any SelectionBookmark)?
    /// If this item is the inverse of a previous map on the stack, the offset
    /// back to it (used to build remappings with mirror information).
    let mirrorOffset: Int?

    init(map: StepMap, step: (any Step)? = nil, selection: (any SelectionBookmark)? = nil, mirrorOffset: Int? = nil) {
        self.map = map
        self.step = step
        self.selection = selection
        self.mirrorOffset = mirrorOffset
    }

    /// Merge with a newer step item that doesn't start an event (upstream
    /// Item.merge) — used by compression to collapse adjacent typing steps.
    func merge(_ other: HistoryItem) -> HistoryItem? {
        guard let step, let otherStep = other.step, other.selection == nil,
              let merged = otherStep.merge(step) else { return nil }
        return HistoryItem(map: merged.getMap().invert(), step: merged, selection: selection)
    }
}

/// Schedule compression when this many map-only items have accumulated
/// (upstream max_empty_items). During collab every remote change adds one.
private let maxEmptyItems = 500

private let depthOverflow = 20

struct Branch {
    var items: [HistoryItem]
    var eventCount: Int

    static var empty: Branch { Branch(items: [], eventCount: 0) }

    /// Pop the latest event off the branch: build a transaction that applies
    /// its inverted steps (remapped over everything that happened since), the
    /// branch that remains, and the selection to restore.
    func popEvent(_ state: EditorState) -> (remaining: Branch, transform: Transaction, selection: any SelectionBookmark)? {
        guard eventCount > 0 else { return nil }

        // The index of the item that starts the latest event.
        var end = items.count
        while true {
            if items[end - 1].selection != nil { end -= 1; break }
            end -= 1
        }

        let remap = remapping(end, items.count)
        var mapFrom = remap.maps.count
        let transform = state.tr
        var addAfter: [HistoryItem] = []
        var addBefore: [HistoryItem] = []

        var i = items.count - 1
        while i >= 0 {
            let item = items[i]
            guard let itemStep = item.step else {
                mapFrom -= 1
                addBefore.append(item)
                i -= 1
                continue
            }
            addBefore.append(HistoryItem(map: item.map))
            let mapped = itemStep.map(remap.slice(mapFrom))
            var map: StepMap?
            if let mapped, transform.maybeStep(mapped).failed == nil {
                map = transform.mapping.maps[transform.mapping.maps.count - 1]
                addAfter.append(HistoryItem(map: map!, mirrorOffset: addAfter.count + addBefore.count))
            }
            mapFrom -= 1
            if let map { remap.appendMap(map, mapFrom) }

            if let sel = item.selection {
                let selection = sel.map(remap.slice(mapFrom))
                let remaining = Branch(items: Array(items[0..<end]) + (addBefore.reversed() + addAfter),
                                       eventCount: eventCount - 1)
                return (remaining, transform, selection)
            }
            i -= 1
        }
        return nil
    }

    /// A new branch with the given transform's inverted steps appended.
    /// `selection` marks the start of a new event (nil continues the last one).
    func addTransform(_ transform: Transform, _ selection: (any SelectionBookmark)?, _ depth: Int) -> Branch {
        var newItems: [HistoryItem] = []
        var eventCount = self.eventCount
        var selection = selection
        for i in 0..<transform.steps.count {
            let step = transform.steps[i].invert(transform.docs[i])
            newItems.append(HistoryItem(map: transform.mapping.maps[i], step: step, selection: selection))
            if selection != nil {
                eventCount += 1
                selection = nil
            }
        }
        var oldItems = items
        let overflow = eventCount - depth
        if overflow > depthOverflow {
            oldItems = cutOffEvents(oldItems, overflow)
            eventCount -= overflow
        }
        return Branch(items: oldItems + newItems, eventCount: eventCount)
    }

    /// The combined mapping of items[from..<to], with mirror info.
    func remapping(_ from: Int, _ to: Int) -> Mapping {
        let maps = Mapping()
        for i in from..<to {
            let item = items[i]
            if let offset = item.mirrorOffset, i - offset >= from {
                maps.appendMap(item.map, maps.maps.count - offset)
            } else {
                maps.appendMap(item.map)
            }
        }
        return maps
    }

    /// Record maps for changes that aren't part of the history (remote steps).
    func addMaps(_ array: [StepMap]) -> Branch {
        if eventCount == 0 { return self }
        return Branch(items: items + array.map { HistoryItem(map: $0) }, eventCount: eventCount)
    }

    /// When the collab module rebases unconfirmed local steps over remote ones,
    /// the items corresponding to those steps must be rewritten to their
    /// rebased versions, and the remote changes' maps recorded.
    func rebased(_ rebasedTransform: Transform, _ rebasedCount: Int) -> Branch {
        guard eventCount > 0 else { return self }

        var rebasedItems: [HistoryItem] = []
        let start = max(0, items.count - rebasedCount)
        let mapping = rebasedTransform.mapping
        var newUntil = rebasedTransform.steps.count
        var eventCount = self.eventCount
        for item in items[start...] where item.selection != nil { eventCount -= 1 }

        var iRebased = rebasedCount
        for item in items[start...] {
            iRebased -= 1
            guard let pos = mapping.getMirror(iRebased) else { continue }
            newUntil = min(newUntil, pos)
            let map = mapping.maps[pos]
            if item.step != nil {
                let step = rebasedTransform.steps[pos].invert(rebasedTransform.docs[pos])
                let selection = item.selection.map { $0.map(mapping.slice(iRebased + 1, pos)) }
                if selection != nil { eventCount += 1 }
                rebasedItems.append(HistoryItem(map: map, step: step, selection: selection))
            } else {
                rebasedItems.append(HistoryItem(map: map))
            }
        }

        var newMaps: [HistoryItem] = []
        for i in rebasedCount..<newUntil { newMaps.append(HistoryItem(map: mapping.maps[i])) }
        var branch = Branch(items: Array(items[0..<start]) + newMaps + rebasedItems, eventCount: eventCount)
        if branch.emptyItemCount() > maxEmptyItems {
            // `rebased` relies on a clean tail to associate items with rebased
            // steps, so only the items below it are compressed.
            branch = branch.compress(items.count - rebasedItems.count)
        }
        return branch
    }

    func emptyItemCount() -> Int {
        items.count(where: { $0.step == nil })
    }

    /// Rewrite the branch to push out the "air" — map-only items that
    /// accumulate from remote changes during collab. Steps are remapped through
    /// the dropped maps and adjacent ones merged. Only items below `upto` are
    /// compressed (see `rebased`).
    func compress(_ upto: Int? = nil) -> Branch {
        let upto = upto ?? items.count
        let remap = remapping(0, upto)
        var mapFrom = remap.maps.count
        var newItems: [HistoryItem] = []
        var events = 0
        var i = items.count - 1
        while i >= 0 {
            let item = items[i]
            if i >= upto {
                newItems.append(item)
                if item.selection != nil { events += 1 }
            } else if let itemStep = item.step {
                let step = itemStep.map(remap.slice(mapFrom))
                let map = step?.getMap()
                mapFrom -= 1
                if let map { remap.appendMap(map, mapFrom) }
                if let step {
                    let selection = item.selection.map { $0.map(remap.slice(mapFrom)) }
                    if selection != nil { events += 1 }
                    let newItem = HistoryItem(map: map!.invert(), step: step, selection: selection)
                    if let last = newItems.last, let merged = last.merge(newItem) {
                        newItems[newItems.count - 1] = merged
                    } else {
                        newItems.append(newItem)
                    }
                }
            } else {
                mapFrom -= 1
            }
            i -= 1
        }
        return Branch(items: Array(newItems.reversed()), eventCount: events)
    }
}

private func cutOffEvents(_ items: [HistoryItem], _ n: Int) -> [HistoryItem] {
    var n = n
    for (i, item) in items.enumerated() where item.selection != nil {
        if n == 0 { return Array(items[i...]) }
        n -= 1
    }
    return []
}

/// The plugin state for undo/redo.
public final class HistoryState {
    var done: Branch
    var undone: Branch
    /// The document ranges (new coords) touched by the latest event, used to
    /// decide whether the next change merges into it. nil = no context.
    let prevRanges: [Int]?
    /// The time of the latest recorded change; nil = no context (fresh state,
    /// after closeHistory, or after an undo/redo), which forces a new group.
    /// (Upstream uses 0 as the sentinel, but this port's transactions default
    /// to time 0, so nil keeps "no timestamp" distinct from "no context".)
    let prevTime: Double?
    let options: HistoryOptions

    init(done: Branch, undone: Branch, prevRanges: [Int]?, prevTime: Double?, options: HistoryOptions) {
        self.done = done
        self.undone = undone
        self.prevRanges = prevRanges
        self.prevTime = prevTime
        self.options = options
    }

    /// Whether there is anything to undo.
    public var canUndo: Bool { done.eventCount > 0 }
    /// Whether there is anything to redo.
    public var canRedo: Bool { undone.eventCount > 0 }
}

/// The key under which the history state is stored.
public let historyKey = PluginKey<HistoryState>("history")

private let historyMeta = "history$"
private let addToHistoryMeta = "addToHistory"
private let closeHistoryMeta = "closeHistory"
private let rebasedMeta = "rebased"

private enum HistoryUpdate {
    case set(HistoryState, redo: Bool)
}

private let appendedTransactionMeta = "appendedTransaction"

/// Mark a transaction so the change after it starts a new undo group, even if
/// it would otherwise merge with the previous event.
@discardableResult
public func closeHistory(_ tr: Transaction) -> Transaction {
    tr.setMeta(closeHistoryMeta, true)
}

/// Group commits that happen close together (in ms). Tiptap/PM default 500ms.
public struct HistoryOptions: Sendable {
    public var newGroupDelay: Double
    public var depth: Int
    public init(newGroupDelay: Double = 500, depth: Int = 100) {
        self.newGroupDelay = newGroupDelay
        self.depth = depth
    }
}

/// Create the history plugin.
public func history(_ options: HistoryOptions = HistoryOptions()) -> Plugin {
    Plugin(
        key: historyKey.key,
        stateField: PluginStateField(
            initialize: { _, _ in HistoryState(done: .empty, undone: .empty, prevRanges: nil, prevTime: nil, options: options) },
            apply: { tr, value, oldState, _ in
                var hist = value as! HistoryState
                if let update = tr.getMeta(historyMeta) as? HistoryUpdate {
                    switch update { case let .set(newState, _): return newState }
                }
                if tr.getMeta(closeHistoryMeta) != nil {
                    hist = HistoryState(done: hist.done, undone: hist.undone, prevRanges: nil, prevTime: nil, options: options)
                }
                guard tr.docChanged else { return hist }

                let appended = tr.getMeta(appendedTransactionMeta) as? Transaction
                if let appended, let update = appended.getMeta(historyMeta) as? HistoryUpdate {
                    // A transaction appended to an undo/redo joins that history
                    // move: its inverse lands on the branch the move feeds, so
                    // the counterpart command replays it too.
                    switch update {
                    case .set(_, redo: true):
                        return HistoryState(
                            done: hist.done.addTransform(tr, nil, options.depth),
                            undone: hist.undone,
                            prevRanges: rangesFor(tr.mapping.maps),
                            prevTime: hist.prevTime,
                            options: options)
                    case .set(_, redo: false):
                        return HistoryState(
                            done: hist.done,
                            undone: hist.undone.addTransform(tr, nil, options.depth),
                            prevRanges: nil,
                            prevTime: hist.prevTime,
                            options: options)
                    }
                }

                let addToHist = (tr.getMeta(addToHistoryMeta) as? Bool) ?? true
                let rootOptedOut = (appended?.getMeta(addToHistoryMeta) as? Bool) == false
                if addToHist && !rootOptedOut {
                    // Appended transactions never start their own group — they
                    // join the event of the transaction that triggered them.
                    let newGroup = hist.prevTime == nil
                        || (appended == nil
                            && (hist.prevTime! < tr.time - options.newGroupDelay
                                || !isAdjacentTo(tr, hist.prevRanges)))
                    let prevRanges = appended != nil
                        ? mapRanges(hist.prevRanges, tr.mapping)
                        : rangesFor(tr.mapping.maps)
                    return HistoryState(
                        done: hist.done.addTransform(tr, newGroup ? oldState.selection.getBookmark() : nil, options.depth),
                        undone: .empty,
                        prevRanges: prevRanges,
                        prevTime: tr.time,
                        options: options)
                } else if let rebasedCount = tr.getMeta(rebasedMeta) as? Int {
                    // The collab module rebased our unconfirmed steps.
                    return HistoryState(
                        done: hist.done.rebased(tr, rebasedCount),
                        undone: hist.undone.rebased(tr, rebasedCount),
                        prevRanges: mapRanges(hist.prevRanges, tr.mapping),
                        prevTime: hist.prevTime,
                        options: options)
                } else {
                    // A change that isn't undoable (remote edit): record its maps
                    // so stored steps keep pointing at the right positions.
                    return HistoryState(
                        done: hist.done.addMaps(tr.mapping.maps),
                        undone: hist.undone.addMaps(tr.mapping.maps),
                        prevRanges: mapRanges(hist.prevRanges, tr.mapping),
                        prevTime: hist.prevTime,
                        options: options)
                }
            }))
}

/// Apply the latest event of one branch, moving it onto the other branch.
private func histTransaction(_ hist: HistoryState, _ state: EditorState, redo: Bool) -> Transaction? {
    guard let pop = (redo ? hist.undone : hist.done).popEvent(state) else { return nil }
    let selection = pop.selection.resolve(pop.transform.doc)
    let added = (redo ? hist.done : hist.undone).addTransform(pop.transform, state.selection.getBookmark(), hist.options.depth)
    let newHist = HistoryState(done: redo ? added : pop.remaining,
                               undone: redo ? pop.remaining : added,
                               prevRanges: nil, prevTime: nil, options: hist.options)
    pop.transform.setSelection(selection)
    pop.transform.setMeta(historyMeta, HistoryUpdate.set(newHist, redo: redo))
    return pop.transform
}

/// Undo the most recent change.
public let undo: @Sendable (EditorState, ((Transaction) -> Void)?) -> Bool = { state, dispatch in
    guard let hist = historyKey.getState(state), hist.canUndo else { return false }
    if dispatch != nil, let tr = histTransaction(hist, state, redo: false) {
        dispatch?(tr.scrollIntoView())
    }
    return true
}

/// Redo the most recently undone change.
public let redo: @Sendable (EditorState, ((Transaction) -> Void)?) -> Bool = { state, dispatch in
    guard let hist = historyKey.getState(state), hist.canRedo else { return false }
    if dispatch != nil, let tr = histTransaction(hist, state, redo: true) {
        dispatch?(tr.scrollIntoView())
    }
    return true
}

/// Force-compress the undo branch in place. Compression normally triggers
/// automatically during rebasing (maxEmptyItems); this mirrors upstream's
/// test-only direct compression and exists for tests/maintenance.
public func _compressHistory(_ state: EditorState) {
    guard let hist = historyKey.getState(state) else { return }
    hist.done = hist.done.compress()
}

/// The number of undoable events.
public func undoDepth(_ state: EditorState) -> Int { historyKey.getState(state)?.done.eventCount ?? 0 }
/// The number of redoable events.
public func redoDepth(_ state: EditorState) -> Int { historyKey.getState(state)?.undone.eventCount ?? 0 }

// MARK: - Grouping helpers

/// Whether `tr`'s first changed range overlaps the previously-touched ranges,
/// i.e. it continues editing the same region (ProseMirror's `isAdjacentTo`).
private func isAdjacentTo(_ tr: Transaction, _ prevRanges: [Int]?) -> Bool {
    guard let prevRanges, !prevRanges.isEmpty else { return false }
    if !tr.docChanged { return true }
    var adjacent = false
    tr.mapping.maps[0].forEach { start, end, _, _ in
        var i = 0
        while i < prevRanges.count {
            if start <= prevRanges[i + 1] && end >= prevRanges[i] { adjacent = true }
            i += 2
        }
    }
    return adjacent
}

/// The new-coordinate ranges touched by the last non-empty step map of a change.
private func rangesFor(_ maps: [StepMap]) -> [Int] {
    var result: [Int] = []
    var i = maps.count - 1
    while i >= 0, result.isEmpty {
        maps[i].forEach { _, _, from, to in result.append(from); result.append(to) }
        i -= 1
    }
    return result
}

/// Map touched ranges through a non-history change, dropping emptied ranges.
private func mapRanges(_ ranges: [Int]?, _ mapping: Mapping) -> [Int]? {
    guard let ranges else { return nil }
    var result: [Int] = []
    var i = 0
    while i < ranges.count {
        let from = mapping.map(ranges[i], 1), to = mapping.map(ranges[i + 1], -1)
        if from <= to { result.append(from); result.append(to) }
        i += 2
    }
    return result
}

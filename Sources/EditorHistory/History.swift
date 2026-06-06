import DocumentModel
import DocumentTransform
import EditorStateKit

/// One undoable event: the steps that undo a change (ready to apply, in order)
/// plus a bookmark of the selection to restore.
struct HistoryEvent {
    var steps: [Step]
    var selection: SelectionBookmark
    var time: Double
}

/// The plugin state for undo/redo.
public final class HistoryState {
    var done: [HistoryEvent]
    var undone: [HistoryEvent]
    var prevTime: Double

    init(done: [HistoryEvent] = [], undone: [HistoryEvent] = [], prevTime: Double = 0) {
        self.done = done
        self.undone = undone
        self.prevTime = prevTime
    }

    /// Whether there is anything to undo.
    public var canUndo: Bool { !done.isEmpty }
    /// Whether there is anything to redo.
    public var canRedo: Bool { !undone.isEmpty }
}

/// The key under which the history state is stored.
public let historyKey = PluginKey<HistoryState>("history")

private let historyMeta = "history$"
private let addToHistoryMeta = "addToHistory"

private enum HistoryUpdate {
    case set(HistoryState)
}

/// Compute the steps that undo the given transform, ready to apply in order.
private func invertedSteps(_ steps: [Step], _ docs: [Node], _ finalDoc: Node) -> [Step] {
    var result: [Step] = []
    var i = steps.count - 1
    while i >= 0 {
        result.append(steps[i].invert(docs[i]))
        i -= 1
    }
    return result
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
            initialize: { _, _ in HistoryState() },
            apply: { tr, value, oldState, _ in
                let hist = value as! HistoryState
                if let update = tr.getMeta(historyMeta) as? HistoryUpdate {
                    switch update { case let .set(newState): return newState }
                }
                guard tr.docChanged, (tr.getMeta(addToHistoryMeta) as? Bool) ?? true else { return hist }
                let event = HistoryEvent(
                    steps: invertedSteps(tr.steps, tr.docs, tr.doc),
                    selection: oldState.selection.getBookmark(),
                    time: tr.time)
                var done = hist.done
                // Merge into the previous event if it is recent enough.
                if let last = done.last, tr.time - hist.prevTime < options.newGroupDelay, !done.isEmpty {
                    // Prepend the new undo steps before the previous event's
                    // undo steps so the whole group undoes together.
                    done[done.count - 1] = HistoryEvent(
                        steps: event.steps + last.steps,
                        selection: last.selection,
                        time: last.time)
                } else {
                    done.append(event)
                    if done.count > options.depth { done.removeFirst(done.count - options.depth) }
                }
                return HistoryState(done: done, undone: [], prevTime: tr.time)
            }))
}

private func shift(_ state: EditorState, _ from: WritableKeyPath<HistoryState, [HistoryEvent]>, _ toUndone: Bool, _ dispatch: ((Transaction) -> Void)?) -> Bool {
    guard let hist = historyKey.getState(state) else { return false }
    let source = toUndone ? hist.done : hist.undone
    guard let event = source.last else { return false }
    guard dispatch != nil else { return true }

    let tr = state.tr
    for step in event.steps { tr.maybeStep(step) }
    // The redo/undo counterpart is the inverse of what we just applied.
    let counterpart = HistoryEvent(
        steps: invertedSteps(tr.steps, tr.docs, tr.doc),
        selection: state.selection.getBookmark(),
        time: state.tr.time)
    // The bookmark was captured in a document identical to the one this undo
    // reconstructs, so resolve it directly (no mapping).
    tr.setSelection(event.selection.resolve(tr.doc))

    var newDone = hist.done
    var newUndone = hist.undone
    if toUndone {
        newDone.removeLast()
        newUndone.append(counterpart)
    } else {
        newUndone.removeLast()
        newDone.append(counterpart)
    }
    let newState = HistoryState(done: newDone, undone: newUndone, prevTime: hist.prevTime)
    tr.setMeta(historyMeta, HistoryUpdate.set(newState))
    tr.setMeta(addToHistoryMeta, false)
    dispatch?(tr.scrollIntoView())
    return true
}

/// Undo the most recent change.
public let undo: @Sendable (EditorState, ((Transaction) -> Void)?) -> Bool = { state, dispatch in
    shift(state, \.done, true, dispatch)
}

/// Redo the most recently undone change.
public let redo: @Sendable (EditorState, ((Transaction) -> Void)?) -> Bool = { state, dispatch in
    shift(state, \.undone, false, dispatch)
}

/// The number of undoable events.
public func undoDepth(_ state: EditorState) -> Int { historyKey.getState(state)?.done.count ?? 0 }
/// The number of redoable events.
public func redoDepth(_ state: EditorState) -> Int { historyKey.getState(state)?.undone.count ?? 0 }

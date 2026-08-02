import DocumentModel
public import DocumentTransform
public import EditorStateKit

/// A step paired with its inverse and the origin transaction, kept around while
/// it is unconfirmed by the central authority.
public struct Rebaseable {
    public var step: any Step
    public var inverted: any Step
    public var origin: Transaction?
    public init(step: any Step, inverted: any Step, origin: Transaction? = nil) {
        self.step = step
        self.inverted = inverted
        self.origin = origin
    }
}

/// The collab plugin's state: the confirmed version number and the steps this
/// client has applied locally but not yet had confirmed.
public final class CollabState {
    public let version: Int
    var unconfirmed: [Rebaseable]
    let clientID: Int

    init(version: Int, unconfirmed: [Rebaseable], clientID: Int) {
        self.version = version
        self.unconfirmed = unconfirmed
        self.clientID = clientID
    }
}

public let collabKey = PluginKey<CollabState>("collab")
private let collabMeta = "collab$"
private let rebasedMeta = "rebased"
private let addToHistoryMeta = "addToHistory"

private enum CollabUpdate { case set(CollabState) }

/// Create the collaboration plugin. `clientID` distinguishes this client's
/// changes from peers'; it defaults to a random 32-bit number like upstream.
public func collab(version: Int = 0, clientID: Int = Int.random(in: 0..<0x1_0000_0000)) -> Plugin {
    Plugin(
        key: collabKey.key,
        stateField: PluginStateField(
            initialize: { _, _ in CollabState(version: version, unconfirmed: [], clientID: clientID) },
            apply: { tr, value, _, _ in
                let collabState = value as! CollabState
                if let update = tr.getMeta(collabMeta) as? CollabUpdate {
                    switch update { case let .set(s): return s }
                }
                if tr.docChanged {
                    return CollabState(version: collabState.version,
                                       unconfirmed: collabState.unconfirmed + unconfirmedFrom(tr),
                                       clientID: collabState.clientID)
                }
                return collabState
            }))
}

private func unconfirmedFrom(_ transform: Transaction) -> [Rebaseable] {
    var result: [Rebaseable] = []
    for i in 0..<transform.steps.count {
        result.append(Rebaseable(step: transform.steps[i],
                                 inverted: transform.steps[i].invert(transform.docs[i]),
                                 origin: transform))
    }
    return result
}

/// The steps this client has ready to send to the authority, if any.
public struct SendableSteps {
    public let version: Int
    public let steps: [any Step]
    public let clientID: Int
    /// The original transactions that produced each step — useful for timestamps
    /// and other metadata. Note the steps may since have been rebased, while the
    /// origins are the old, unchanged transactions.
    public let origins: [Transaction?]
}

/// Steps to send to the central authority, or `nil` if there are none.
public func sendableSteps(_ state: EditorState) -> SendableSteps? {
    guard let collabState = collabKey.getState(state), !collabState.unconfirmed.isEmpty else { return nil }
    return SendableSteps(version: collabState.version,
                         steps: collabState.unconfirmed.map { $0.step },
                         clientID: collabState.clientID,
                         origins: collabState.unconfirmed.map { $0.origin })
}

/// The confirmed document version for this state.
public func getVersion(_ state: EditorState) -> Int {
    collabKey.getState(state)?.version ?? 0
}

/// Create a transaction that represents a set of remote steps received from the
/// authority (each with the client ID that produced it). Apply the returned
/// transaction to advance and rebase local unconfirmed steps.
///
/// With `mapSelectionBackward` (off by default, like upstream), a text selection
/// is mapped with negative bias so content inserted at the cursor lands after it.
public func receiveTransaction(_ state: EditorState, _ steps: [any Step], _ clientIDs: [Int],
                               mapSelectionBackward: Bool = false) -> Transaction {
    let collabState = collabKey.getState(state)!
    let version = collabState.version + steps.count
    let ourID = collabState.clientID

    // How many of the leading received steps are our own (already applied).
    var ours = 0
    while ours < clientIDs.count && clientIDs[ours] == ourID { ours += 1 }
    var unconfirmed = Array(collabState.unconfirmed.dropFirst(ours))
    let remoteSteps = ours != 0 ? Array(steps.dropFirst(ours)) : steps

    if remoteSteps.isEmpty {
        let tr = state.tr
        tr.setMeta(collabMeta, CollabUpdate.set(CollabState(version: version, unconfirmed: unconfirmed, clientID: ourID)))
        return tr
    }

    let nUnconfirmed = unconfirmed.count
    let tr = state.tr
    if nUnconfirmed != 0 {
        unconfirmed = rebaseSteps(unconfirmed, remoteSteps, tr)
    } else {
        for step in remoteSteps { tr.maybeStep(step) }
        unconfirmed = []
    }

    let newCollabState = CollabState(version: version, unconfirmed: unconfirmed, clientID: ourID)
    if mapSelectionBackward, state.selection is TextSelection {
        tr.setSelection(TextSelection.between(tr.doc.resolve(tr.mapping.map(state.selection.anchor, -1)),
                                              tr.doc.resolve(tr.mapping.map(state.selection.head, -1)), -1))
        // The mapped selection is bookkeeping, not an explicit update.
        tr.clearSelectionSet()
    }
    tr.setMeta(rebasedMeta, nUnconfirmed)
    tr.setMeta(addToHistoryMeta, false)
    tr.setMeta(collabMeta, CollabUpdate.set(newCollabState))
    return tr
}

@discardableResult
public func rebaseSteps(_ steps: [Rebaseable], _ over: [any Step], _ transform: Transform) -> [Rebaseable] {
    // Undo our local steps...
    var i = steps.count - 1
    while i >= 0 { transform.maybeStep(steps[i].inverted); i -= 1 }
    // ...apply the remote steps...
    for step in over { transform.maybeStep(step) }
    // ...then re-apply our steps, mapped over the remote ones.
    var result: [Rebaseable] = []
    var mapFrom = steps.count
    for j in 0..<steps.count {
        let mapped = steps[j].step.map(transform.mapping.slice(mapFrom))
        mapFrom -= 1
        if let mapped, transform.maybeStep(mapped).failed == nil {
            transform.mapping.setMirror(mapFrom, transform.steps.count - 1)
            result.append(Rebaseable(step: mapped,
                                     inverted: mapped.invert(transform.docs[transform.docs.count - 1]),
                                     origin: steps[j].origin))
        }
    }
    return result
}

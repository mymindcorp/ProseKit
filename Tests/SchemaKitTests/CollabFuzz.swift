import Foundation
import DocumentModel
import DocumentTransform
import EditorCollab
import EditorStateKit
import SchemaKit
import TestDocGen
import TestHarness

// A fuzzer for collaborative editing over the *real* schema.
//
// `EditorCollabTests` has a convergence fuzz already, and it is a good one — but
// it runs on a three-node schema (doc, paragraph, text) driven by text inserts
// and deletes. Rebasing text is the easy half. What breaks convergence in
// practice is structure: one peer wraps a paragraph in a list while another
// splits it, one merges table cells while another types in one of them. Those
// produce `ReplaceAroundStep`s whose gap positions have to be mapped through
// each other, and nothing was exercising that.
//
// Three properties, because the obvious one is not enough on its own:
//
//   * every peer ends up holding the same document, and one the schema accepts;
//   * a peer joining late and replaying the log from version 0 builds that same
//     document — the log *is* the note, on every other device;
//   * and concurrent edits in places that don't overlap all survive. Agreement
//     alone is satisfied by a rebase that silently drops a local step: everyone
//     agrees, and one person's paragraph is missing.
//
// Opt-in for the same reason as the selection sweeps; see `SelectionFuzz`.
func registerCollabFuzzTests() {
    guard ProcessInfo.processInfo.environment["PROSEKIT_FUZZ"] != nil else { return }

    test("collab fuzz: peers running real commands converge on the same document") {
        for seed in 1 ... fuzzOpSeeds {
            var rng = SelRNG(seed &* 17 &+ 9)
            for peerCount in [2, 3] {
                let session = try FuzzSession(peers: peerCount)
                var log: [String] = []
                for _ in 0 ..< fuzzCollabOps {
                    let peer = session.peers[Int.random(in: 0 ..< peerCount, using: &rng)]
                    if Int.random(in: 0 ..< 4, using: &rng) == 0 {
                        peer.sync()
                        log.append("peer \(peer.clientID) sync")
                    } else {
                        log.append("peer \(peer.clientID): \(peer.edit(&rng))")
                    }
                    // Whatever any peer is holding must still be a document.
                    for other in session.peers {
                        var invalid: (any Error)?
                        do { try other.editor.doc.check() } catch { invalid = error }
                        try expect(invalid == nil,
                                   "peer \(other.clientID) holds an invalid document at seed \(seed) — \(log.suffix(4).joined(separator: " | ")): \(invalid.map { "\($0)" } ?? "")")
                    }
                }
                session.settle()

                let ctx = "seed \(seed), \(peerCount) peers — \(log.suffix(6).joined(separator: " | "))"
                for peer in session.peers {
                    // By JSON, not by `==`: every peer has its own `Schema`
                    // instance and node equality is type identity, so two
                    // structurally identical documents from two editors are
                    // never `==`.
                    try expect(peer.editor.doc.toJSON() == session.authority.doc.toJSON(),
                               "peer \(peer.clientID) diverged from the authority at \(ctx)")
                    try expectEqual(getVersion(peer.editor.state), session.authority.version,
                                    "peer \(peer.clientID) is at the wrong version at \(ctx)")
                    try expectNil(sendableSteps(peer.editor.state))
                    try checkSelectionValid(peer.editor.state.selection, in: peer.editor.doc,
                                            "peer \(peer.clientID) at \(ctx)")
                }
            }
        }
    }

    test("collab fuzz: a peer joining late rebuilds the document from the log alone") {
        // What a new client actually does: fetch the step log from version 0
        // and replay it onto an empty document. That has to land on the same
        // document everyone else is looking at — the log *is* the document, and
        // a step that only applies in the presence of some client-side state
        // makes the history unreplayable without anyone noticing until someone
        // opens the note on a second device.
        //
        // Deliberately not "the same edits in a different sync order agree":
        // rebasing is order-dependent on purpose, and two different confirmation
        // orders are allowed to reach two different (equally valid) documents.
        for seed in 1 ... fuzzOpSeeds {
            var rng = SelRNG(seed &* 19 &+ 11)
            let session = try FuzzSession(peers: 3)
            for op in 0 ..< fuzzCollabOps {
                _ = session.peers[Int.random(in: 0 ..< 3, using: &rng)].edit(&rng)
                if op % 3 == 2 { for peer in session.peers { peer.sync() } }
            }
            session.settle()

            let joiner = try FuzzPeer(clientID: 99, authority: session.authority)
            let (steps, ids) = session.authority.stepsSince(0)
            joiner.receive(steps, ids)
            try expectEqual(getVersion(joiner.editor.state), session.authority.version,
                            "the late joiner is at the wrong version at seed \(seed)")
            try expect(joiner.editor.doc.toJSON() == session.authority.doc.toJSON(),
                       "replaying the whole log built a different document at seed \(seed)")
            var invalid: (any Error)?
            do { try joiner.editor.doc.check() } catch { invalid = error }
            try expect(invalid == nil,
                       "replaying the whole log built an invalid document at seed \(seed): \(invalid.map { "\($0)" } ?? "")")
        }
    }
    test("collab fuzz: concurrent edits in separate places all survive") {
        // Convergence on its own is a weaker property than it sounds: a rebase
        // that quietly *drops* a local step still leaves every peer agreeing,
        // because they all agree on the log the step never reached. Everyone
        // ends up looking at the same document and one person's paragraph is
        // simply missing.
        //
        // So: peers type markers only they touch, nobody deletes, and every
        // marker has to be in the document at the end. Nothing here can be lost
        // to a legitimate conflict, so anything missing was dropped.
        for seed in 1 ... fuzzOpSeeds {
            var rng = SelRNG(seed &* 23 &+ 3)
            let session = try FuzzSession(peers: 3)
            // One paragraph per peer, so no two peers ever edit the same block.
            for peer in session.peers {
                let tr = peer.editor.state.tr
                try tr.split(peer.editor.doc.content.size - 1, 1)
                peer.editor.dispatch(tr)
                peer.sync()
            }
            session.settle()

            var markers: [String] = []
            for op in 0 ..< fuzzCollabOps {
                let index = Int.random(in: 0 ..< session.peers.count, using: &rng)
                let peer = session.peers[index]
                let marker = "m\(seed)x\(op)z"
                // Into this peer's own paragraph, at its start, so two peers
                // never type into the same block and the insert can't be
                // reshaped by anything else.
                guard let at = paragraphStart(peer.editor.doc, index) else { continue }
                let tr = peer.editor.state.tr
                guard (try? tr.insertText(marker, at)) != nil else { continue }
                peer.editor.dispatch(tr)
                markers.append(marker)
                if Int.random(in: 0 ..< 3, using: &rng) == 0 {
                    session.peers[Int.random(in: 0 ..< session.peers.count, using: &rng)].sync()
                }
            }
            session.settle()

            let text = session.authority.doc.textContent
            let lost = markers.filter { !text.contains($0) }
            try expect(lost.isEmpty,
                       "\(lost.count) of \(markers.count) concurrent edits never reached the document at seed \(seed) — first missing \(lost.first ?? "")")
            for peer in session.peers {
                try expect(peer.editor.doc.toJSON() == session.authority.doc.toJSON(),
                           "peer \(peer.clientID) diverged at seed \(seed)")
            }
        }
    }
}

/// The first text position inside the `index`-th top-level paragraph, or nil if
/// the document doesn't have that many.
private func paragraphStart(_ doc: Node, _ index: Int) -> Int? {
    var seen = 0, found: Int?
    for i in 0 ..< doc.childCount {
        guard doc.child(i).type.name == "paragraph" else { continue }
        if seen == index { found = doc.resolve(0).posAtIndex(i) + 1; break }
        seen += 1
    }
    return found
}

/// Ops per session: enough for peers to build up several unconfirmed steps
/// each, which is the state rebasing is about.
let fuzzCollabOps = 40

// MARK: - A tiny server and its peers

/// An ordered, append-only log of steps — the same minimal authority the collab
/// suite uses, but holding its steps as JSON rather than as objects.
///
/// That is not ceremony. `Editor` builds a fresh `Schema` per instance and node
/// equality is type *identity*, so two peers can't pass each other live nodes
/// and be compared afterwards. Sending JSON is what a real client does anyway —
/// it is the wire format — so the fuzz gets a more faithful server and puts
/// every step through `decodeStep` on the way in and out for free.
final class FuzzAuthority {
    /// The authority's own editor, kept only for its schema and its copy of the
    /// document. Its state is never edited locally.
    private let owner: Editor
    private(set) var doc: Node
    private(set) var steps: [[String: AttributeValue]] = []
    private(set) var clientIDs: [Int] = []

    init() throws {
        owner = try Editor(extensions: fuzzKit())
        doc = owner.doc
    }

    var version: Int { steps.count }

    /// Accept steps only if they are based on the current version.
    @discardableResult
    func receive(version: Int, steps: [[String: AttributeValue]], clientID: Int) -> Bool {
        guard version == self.version else { return false }
        for json in steps {
            guard let step = try? decodeStep(owner.schema, json), let newDoc = step.apply(doc).doc else { return false }
            doc = newDoc
            self.steps.append(json)
            clientIDs.append(clientID)
        }
        return true
    }

    func stepsSince(_ version: Int) -> (steps: [[String: AttributeValue]], clientIDs: [Int]) {
        (Array(steps[version...]), Array(clientIDs[version...]))
    }
}

final class FuzzPeer {
    let editor: Editor
    let clientID: Int
    let authority: FuzzAuthority

    init(clientID: Int, authority: FuzzAuthority) throws {
        self.clientID = clientID
        self.authority = authority
        // History off: an undo is a local edit like any other for these
        // purposes, and the plugin's own transactions would only make the op
        // log harder to read back.
        editor = try Editor(extensions: fuzzKit() + [CollabExtension(clientID: clientID)], history: false)
    }

    func edit(_ rng: inout SelRNG) -> String { fuzzStep(editor, &rng) }

    /// Push what we have, then pull everything since our version — our own
    /// steps come back as confirmation, everyone else's as something to rebase
    /// over.
    func sync() {
        if let sendable = sendableSteps(editor.state) {
            _ = authority.receive(version: sendable.version,
                                  steps: sendable.steps.map { $0.toJSON() },
                                  clientID: sendable.clientID)
        }
        let (json, ids) = authority.stepsSince(getVersion(editor.state))
        receive(json, ids)
    }

    /// Take remote steps, decoding them the way a client off the wire would.
    func receive(_ json: [[String: AttributeValue]], _ ids: [Int]) {
        guard !json.isEmpty else { return }
        let steps = json.compactMap { try? decodeStep(editor.schema, $0) }
        // A step that won't decode is a bug in its own right; leaving it out
        // would hide it, so let the version mismatch surface as divergence.
        guard steps.count == json.count else { return }
        editor.dispatch(receiveTransaction(editor.state, steps, ids))
    }
}

final class FuzzSession {
    let authority: FuzzAuthority
    let peers: [FuzzPeer]

    init(peers count: Int) throws {
        let authority = try FuzzAuthority()
        self.authority = authority
        peers = try (1 ... count).map { try FuzzPeer(clientID: $0, authority: authority) }
    }

    /// Sync until nothing is left to send. Each full pass confirms at least one
    /// peer's pending steps, so `count + 3` passes is comfortably enough.
    func settle() {
        for _ in 0 ..< (peers.count + 3) { for peer in peers { peer.sync() } }
    }
}

/// The collab plugin as an extension, so a `FuzzPeer` is an ordinary `Editor`
/// and the shared op driver works on it unchanged.
final class CollabExtension: Extension {
    let name = "collabFuzz"
    let priority = 100
    let clientID: Int
    init(clientID: Int) { self.clientID = clientID }
    func plugins(_ ctx: ExtensionContext) -> [Plugin] { [collab(clientID: clientID)] }
}

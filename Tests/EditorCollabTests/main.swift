import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import EditorCollab
import TestHarness

let collector = TestCollector()
func test(_ name: String, _ body: @escaping @Sendable () throws -> Void) { collector.test(name, body) }

let schema: Schema = {
    let nodes: [(String, NodeSpec)] = [
        ("doc", NodeSpec(content: "block+")),
        ("paragraph", NodeSpec(content: "inline*", group: "block")),
        ("text", NodeSpec(group: "inline")),
    ]
    return try! Schema(nodes: nodes, marks: [], topNode: "doc")
}()

func startDoc() -> Node {
    try! schema.node("doc", [:], content: Fragment.from([try! schema.node("paragraph", [:], content: Fragment.from([schema.text("")]))]))
}

/// A minimal central authority: an ordered, append-only log of steps.
final class Authority {
    private(set) var doc: Node
    private(set) var steps: [Step] = []
    private(set) var clientIDs: [Int] = []
    init(_ doc: Node) { self.doc = doc }
    var version: Int { steps.count }

    /// Accept steps if they are based on the current version.
    @discardableResult
    func receive(version: Int, steps: [Step], clientID: Int) -> Bool {
        if version != self.version { return false }
        for s in steps {
            let result = s.apply(doc)
            guard let newDoc = result.doc else { return false }
            doc = newDoc
            self.steps.append(s)
            self.clientIDs.append(clientID)
        }
        return true
    }

    func stepsSince(_ version: Int) -> (steps: [Step], clientIDs: [Int]) {
        (Array(steps[version...]), Array(clientIDs[version...]))
    }
}

/// A peer wrapping an EditorState with the collab plugin.
final class Peer {
    var state: EditorState
    let clientID: Int
    let authority: Authority
    init(_ doc: Node, clientID: Int, authority: Authority) {
        self.clientID = clientID
        self.authority = authority
        self.state = EditorState.create(EditorStateConfig(schema: schema, doc: doc, plugins: [collab(clientID: clientID)]))
    }

    func insert(_ text: String, at pos: Int) {
        let tr = state.tr
        try! tr.insertText(text, pos)
        state = state.apply(tr)
    }

    /// Push local steps to the authority, then pull (receiving our own echo as
    /// confirmation, plus any remote steps to rebase over).
    func sync() {
        if let sendable = sendableSteps(state) {
            _ = authority.receive(version: sendable.version, steps: sendable.steps, clientID: sendable.clientID)
        }
        let (steps, ids) = authority.stepsSince(getVersion(state))
        if !steps.isEmpty {
            state = state.apply(receiveTransaction(state, steps, ids))
        }
    }
}

func runToConvergence(_ peers: [Peer], rounds: Int = 5) {
    for _ in 0..<rounds {
        for peer in peers { peer.sync() }
    }
}

// MARK: - Tests

test("collab: a single peer's steps reach the authority") {
    let doc = startDoc()
    let authority = Authority(doc)
    let p1 = Peer(doc, clientID: 1, authority: authority)
    p1.insert("hello", at: 1)
    try expectNotNil(sendableSteps(p1.state))
    p1.sync()
    try expectEqual(authority.doc.textContent, "hello")
    try expectNil(sendableSteps(p1.state)) // confirmed, nothing left to send
    try expectEqual(getVersion(p1.state), 1)
}

test("collab: two peers with concurrent edits converge") {
    let doc = startDoc()
    let authority = Authority(doc)
    let p1 = Peer(doc, clientID: 1, authority: authority)
    let p2 = Peer(doc, clientID: 2, authority: authority)

    // Concurrent edits at the same position (both at version 0).
    p1.insert("A", at: 1)
    p2.insert("B", at: 1)

    runToConvergence([p1, p2])

    // Both peers and the authority agree on the same document.
    try expectEqual(p1.state.doc, p2.state.doc)
    try expectEqual(p1.state.doc, authority.doc)
    try expectEqual(getVersion(p1.state), authority.version)
    // Both inserted characters survive.
    let text = authority.doc.textContent
    try expect(text.contains("A") && text.contains("B"), "got '\(text)'")
}

test("collab: interleaved multi-round editing converges") {
    let doc = startDoc()
    let authority = Authority(doc)
    let p1 = Peer(doc, clientID: 1, authority: authority)
    let p2 = Peer(doc, clientID: 2, authority: authority)

    p1.insert("Hello ", at: 1)
    p1.sync(); p2.sync()
    p2.insert("World", at: p2.state.doc.content.size - 1)
    p1.insert("!", at: p1.state.doc.content.size - 1)
    runToConvergence([p1, p2])

    try expectEqual(p1.state.doc, p2.state.doc)
    try expectEqual(p1.state.doc, authority.doc)
    let text = authority.doc.textContent
    try expect(text.contains("Hello") && text.contains("World") && text.contains("!"), "got '\(text)'")
}

test("collab: steps are JSON-codable for transport") {
    let doc = startDoc()
    let authority = Authority(doc)
    let p1 = Peer(doc, clientID: 1, authority: authority)
    p1.insert("x", at: 1)
    let sendable = sendableSteps(p1.state)!
    // Serialize and deserialize each step (as it would cross the wire).
    for step in sendable.steps {
        let json = step.toJSON()
        let restored = try decodeStep(schema, json)
        try expectEqual(restored.apply(doc).doc, step.apply(doc).doc)
    }
}

TestSuite.main("EditorCollabTests", collector.all)

import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import EditorHistory
import EditorCollab
import TestHarness

// Ported from prosemirror-collab/test/test-collab.ts: a dummy central authority
// pushing steps between n peer states, each running history() + collab().

private final class DummyServer {
    var states: [EditorState] = []
    var steps: [Step] = []
    var clientIDs: [Int] = []
    var delayed: [Int] = []

    init(_ startDoc: TaggedNode? = nil, n: Int = 2) {
        let d = startDoc?.node ?? doc(p()).node
        for i in 0..<n {
            states.append(EditorState.create(EditorStateConfig(
                schema: basicSchema, doc: d,
                plugins: [history(), collab(clientID: i + 1)])))
        }
    }

    func sync(_ n: Int) {
        let state = states[n]
        let version = getVersion(state)
        if version != steps.count {
            states[n] = state.apply(receiveTransaction(state, Array(steps[version...]), Array(clientIDs[version...])))
        }
    }

    func send(_ n: Int) {
        guard let sendable = sendableSteps(states[n]), sendable.version == steps.count else { return }
        steps += sendable.steps
        clientIDs += Array(repeating: sendable.clientID, count: sendable.steps.count)
    }

    func broadcast(_ n: Int) {
        if delayed.contains(n) { return }
        sync(n)
        send(n)
        for i in states.indices where i != n { sync(i) }
    }

    func update(_ n: Int, _ f: (EditorState) -> Transaction) {
        states[n] = states[n].apply(f(states[n]))
        broadcast(n)
    }

    func type(_ n: Int, _ text: String, _ pos: Int? = nil) {
        update(n) { s in try! s.tr.insertText(text, pos ?? s.selection.head) }
    }

    func undo(_ n: Int) {
        _ = EditorHistory.undo(states[n]) { tr in self.update(n) { _ in tr } }
    }

    func redo(_ n: Int) {
        _ = EditorHistory.redo(states[n]) { tr in self.update(n) { _ in tr } }
    }

    func conv(_ d: TaggedNode) throws {
        for (i, state) in states.enumerated() {
            try expectEqual(state.doc, d.node, "client \(i) diverged")
        }
    }

    func conv(_ s: String) throws { try conv(doc(p(s))) }

    func delay(_ n: Int, _ f: () -> Void) {
        delayed.append(n)
        f()
        delayed.removeLast()
        broadcast(n)
    }
}

private func sel(_ near: Int) -> (EditorState) -> Transaction {
    { s in s.tr.setSelection(Selection.near(s.doc.resolve(near))) }
}

func registerPMCollabTests() {
    test("PM collab: converges for simple changes") {
        let s = DummyServer()
        s.type(0, "hi")
        s.type(1, "ok", 3)
        s.type(0, "!", 5)
        s.type(1, "...", 1)
        try s.conv("...hiok!")
    }

    test("PM collab: converges for multiple local changes") {
        let s = DummyServer()
        s.type(0, "hi")
        s.delay(0) {
            s.type(0, "A")
            s.type(1, "X")
            s.type(0, "B")
            s.type(1, "Y")
        }
        try s.conv("hiXYAB")
    }

    test("PM collab: converges with three peers") {
        let s = DummyServer(nil, n: 3)
        s.type(0, "A")
        s.type(1, "U")
        s.type(2, "X")
        s.type(0, "B")
        s.type(1, "V")
        s.type(2, "C")
        try s.conv("AUXBVC")
    }

    test("PM collab: converges with three peers with multiple steps") {
        let s = DummyServer(nil, n: 3)
        s.type(0, "A")
        s.delay(1) {
            s.type(1, "U")
            s.type(2, "X")
            s.type(0, "B")
            s.type(1, "V")
            s.type(2, "C")
        }
        try s.conv("AXBCUV")
    }

    test("PM collab: supports undo") {
        let s = DummyServer()
        s.type(0, "A")
        s.type(1, "B")
        s.type(0, "C")
        s.undo(1)
        try s.conv("AC")
        s.type(1, "D")
        s.type(0, "E")
        try s.conv("ACDE")
    }

    test("PM collab: supports redo") {
        let s = DummyServer()
        s.type(0, "A")
        s.type(1, "B")
        s.type(0, "C")
        s.undo(1)
        s.redo(1)
        s.type(1, "D")
        s.type(0, "E")
        try s.conv("ABCDE")
    }

    test("PM collab: supports deep undo") {
        let s = DummyServer(doc(p("hello"), p("bye")))
        s.update(0, sel(6))
        s.update(1, sel(11))
        s.type(0, "!")
        s.type(1, "!")
        s.update(0) { s in closeHistory(s.tr) }
        s.delay(0) {
            s.type(0, " ...")
            s.type(1, " ,,,")
        }
        s.update(0) { s in closeHistory(s.tr) }
        s.type(0, "*")
        s.type(1, "*")
        s.undo(0)
        try s.conv(doc(p("hello! ..."), p("bye! ,,,*")))
        s.undo(0)
        s.undo(0)
        try s.conv(doc(p("hello"), p("bye! ,,,*")))
        s.redo(0)
        s.redo(0)
        s.redo(0)
        try s.conv(doc(p("hello! ...*"), p("bye! ,,,*")))
        s.undo(0)
        s.undo(0)
        try s.conv(doc(p("hello!"), p("bye! ,,,*")))
        s.undo(1)
        try s.conv(doc(p("hello!"), p("bye")))
    }

    test("PM collab: supports undo with clashing events") {
        let s = DummyServer(doc(p("hello")))
        s.update(0, sel(6))
        s.type(0, "A")
        s.delay(0) {
            s.type(0, "B", 4)
            s.type(0, "C", 5)
            s.type(0, "D", 1)
            s.update(1) { s in try! s.tr.delete(2, 5) }
        }
        try s.conv("DhoA")
        s.undo(0)
        s.undo(0)
        try s.conv("ho")
        try expectEqual(s.states[0].selection.head, 3)
    }

    test("PM collab: handles conflicting steps") {
        let s = DummyServer(doc(p("abcde")))
        s.delay(0) {
            s.update(0) { s in try! s.tr.delete(3, 4) }
            s.type(0, "x")
            s.update(1) { s in try! s.tr.delete(2, 5) }
        }
        s.undo(0)
        s.undo(0)
        try s.conv(doc(p("ae")))
    }

    test("PM collab fuzz: random typing/undo/redo/delays stay convergent") {
        var rngState: UInt64 = 0xC0FF_EE00
        func rnd(_ n: Int) -> Int {
            rngState ^= rngState << 13; rngState ^= rngState >> 7; rngState ^= rngState << 17
            return Int(rngState % UInt64(max(1, n)))
        }
        let words = ["a", "b", "cd", "x ", "yz"]
        for round in 0..<25 {
            let s = DummyServer()
            for _ in 0..<20 {
                let n = rnd(2)
                switch rnd(6) {
                case 0, 1, 2:
                    s.type(n, words[rnd(words.count)])
                case 3:
                    s.undo(n)
                case 4:
                    s.redo(n)
                default:
                    s.delay(n) {
                        s.type(n, words[rnd(words.count)])
                        s.type(1 - n, words[rnd(words.count)])
                    }
                }
            }
            for _ in 0..<3 { for i in 0..<2 { s.broadcast(i) } }
            try expectEqual(s.states[0].doc, s.states[1].doc, "round \(round)")
        }
    }

    test("PM collab: can undo simultaneous typing") {
        let s = DummyServer(doc(p("A"), p("B")))
        s.update(0, sel(2))
        s.update(1, sel(5))
        s.delay(0) {
            s.type(0, "1")
            s.type(0, "2")
            s.type(1, "x")
            s.type(1, "y")
        }
        try s.conv(doc(p("A12"), p("Bxy")))
        s.undo(0)
        try s.conv(doc(p("A"), p("Bxy")))
        s.undo(1)
        try s.conv(doc(p("A"), p("B")))
    }
}

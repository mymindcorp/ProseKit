import Foundation
import DocumentModel
import EditorStateKit
import EditorCommands
import EditorKeymap
import TestHarness

// Ported from prosemirror-keymap/test/test-keymap.ts. Upstream dispatches W3C
// keyboard events; this port's keymap consumes pre-normalized binding-name
// strings (the platform adapter does event translation), so the cases that
// exercise event/keyCode fallbacks ("tries both shifted key and base",
// "tries keyCode when modifier active", "non-ASCII keyCode") have no headless
// equivalent here and are not ported.

private final class Counter: @unchecked Sendable {
    var count = 0
    var command: Command {
        { [self] _, _, _ in
            count += 1
            return true
        }
    }
}

private let kmState = EditorState.create(EditorStateConfig(schema: basicSchema))

private func dispatchKey(_ map: Plugin, _ key: String) {
    _ = map.props?.handleKeyDown?(key, kmState, { _ in })
}

func registerPMKeymapTests() {
    test("PM keymap: calls the correct handler") {
        let a = Counter(), b = Counter()
        dispatchKey(keymap(["KeyA": a.command, "KeyB": b.command]), "KeyA")
        try expectEqual(a.count, 1)
        try expectEqual(b.count, 0)
    }

    test("PM keymap: distinguishes between modifiers") {
        let s = Counter(), cS = Counter(), scS = Counter(), aS = Counter()
        let map = keymap([
            "Space": s.command,
            "Control-Space": cS.command,
            "s-c-Space": scS.command,
            "alt-Space": aS.command,
        ])
        dispatchKey(map, "Ctrl-Space")
        dispatchKey(map, "Shift-Ctrl-Space")
        try expectEqual(s.count, 0)
        try expectEqual(cS.count, 1)
        try expectEqual(scS.count, 1)
        try expectEqual(aS.count, 0)
    }

    test("PM keymap: passes the state and dispatch through") {
        let sawState = Counter(), sawDispatch = Counter()
        let map = keymap(["X": { state, dispatch, _ in
            if state === kmState { sawState.count += 1 }
            dispatch?(state.tr)
            return true
        }])
        _ = map.props?.handleKeyDown?("X", kmState, { _ in sawDispatch.count += 1 })
        try expectEqual(sawState.count, 1)
        try expectEqual(sawDispatch.count, 1)
    }

    test("PM keymap: normalizes modifier aliases and ordering") {
        try expectEqual(normalizeKeyName("shift-cmd-z"), "Mod-Shift-z")
        try expectEqual(normalizeKeyName("c-s-Space"), "Ctrl-Shift-Space")
        try expectEqual(normalizeKeyName("option-m-a"), "Mod-Alt-a")
        try expectEqual(normalizeKeyName("Enter"), "Enter")
    }
}

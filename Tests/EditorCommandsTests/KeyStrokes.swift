import Foundation
import DocumentModel
import EditorStateKit
import EditorCommands
import EditorKeymap
import TestHarness

// `KeyStroke` is the platform-neutral key press an adapter builds from a native
// event, and `bindingName` turns it into the string a keymap is keyed by. The
// contract between them is the whole point: a stroke's name has to match the
// binding a host wrote, or the key silently does nothing.
//
// Nothing in this package calls either — the UIKit renderer translates
// `UIKey` through its own `KeyEvent` — so they are exercised only by whatever
// adapter a host writes. That is the reason to pin them rather than a reason
// not to.

func registerKeyStrokeTests() {
    // MARK: The contract with the keymap

    test("KeyStroke: a stroke's name is what a keymap is keyed by") {
        // The one that matters: build a keymap from strings a host would write,
        // then look it up with the name a stroke produces.
        // A command is `@Sendable`, so what it fired is recorded in a reference
        // the closures share rather than a captured var.
        final class Fired: @unchecked Sendable { var name: String? }
        let fired = Fired()
        let bindings: [String: Command] = [
            "Mod-b": { _, _, _ in fired.name = "Mod-b"; return true },
            "Mod-Shift-z": { _, _, _ in fired.name = "Mod-Shift-z"; return true },
            "Alt-ArrowLeft": { _, _, _ in fired.name = "Alt-ArrowLeft"; return true },
            "Enter": { _, _, _ in fired.name = "Enter"; return true },
        ]
        let plugin = keymap(bindings)
        let state = EditorState.create(EditorStateConfig(schema: basicSchema, doc: doc(p("x")).node))

        let strokes: [(KeyStroke, String)] = [
            (KeyStroke(key: "b", meta: true), "Mod-b"),
            (KeyStroke(key: "z", shift: true, meta: true), "Mod-Shift-z"),
            (KeyStroke(key: "ArrowLeft", alt: true), "Alt-ArrowLeft"),
            (KeyStroke(key: "Enter"), "Enter"),
        ]
        for (stroke, expected) in strokes {
            fired.name = nil
            let handled = plugin.props?.handleKeyDown?(stroke.bindingName(), state, nil) ?? false
            try expect(handled, "\(expected) should be handled")
            try expectEqual(fired.name, expected)
        }
    }

    test("KeyStroke: a stroke with no binding is left for someone else") {
        let plugin = keymap(["Mod-b": { _, _, _ in true }])
        let state = EditorState.create(EditorStateConfig(schema: basicSchema, doc: doc(p("x")).node))
        let unbound = KeyStroke(key: "q", meta: true).bindingName()
        try expect(plugin.props?.handleKeyDown?(unbound, state, nil) == false,
                   "an unbound stroke must not be swallowed")
    }

    test("KeyStroke: its name is already canonical") {
        // Normalizing a name the stroke produced changes nothing, so a stroke
        // and a hand-written binding meet at the same string.
        let strokes = [
            KeyStroke(key: "a"),
            KeyStroke(key: "a", meta: true),
            KeyStroke(key: "a", shift: true, alt: true, control: true, meta: true),
            KeyStroke(key: "ArrowUp", shift: true),
        ]
        for stroke in strokes {
            let name = stroke.bindingName()
            try expectEqual(normalizeKeyName(name), name, "not canonical: \(name)")
        }
    }

    // MARK: Naming

    test("KeyStroke: modifiers are named in one fixed order") {
        try expectEqual(KeyStroke(key: "a").bindingName(), "a")
        try expectEqual(KeyStroke(key: "a", meta: true).bindingName(), "Mod-a")
        try expectEqual(KeyStroke(key: "a", shift: true).bindingName(), "Shift-a")
        try expectEqual(KeyStroke(key: "a", alt: true).bindingName(), "Alt-a")
        try expectEqual(KeyStroke(key: "a", control: true).bindingName(), "Ctrl-a")
        // All four, in the order the keymap normalizes to.
        try expectEqual(KeyStroke(key: "a", shift: true, alt: true, control: true, meta: true)
            .bindingName(), "Mod-Ctrl-Alt-Shift-a")
    }

    test("KeyStroke: a named key keeps its name") {
        for key in ["Enter", "Backspace", "ArrowLeft", "Tab", "Escape", " "] {
            try expectEqual(KeyStroke(key: key).bindingName(), key)
        }
    }

    test("KeyStroke: init leaves every modifier up unless asked") {
        let plain = KeyStroke(key: "a")
        try expect(!plain.shift && !plain.alt && !plain.control && !plain.meta)
        try expect(!plain.mod, "mod is the primary modifier, which is up")
    }

    test("KeyStroke: mod is the platform's primary modifier") {
        // Command on Apple platforms, which are the ones this package builds for.
        try expect(KeyStroke(key: "a", meta: true).mod)
        try expect(!KeyStroke(key: "a", control: true).mod)
    }

    // MARK: Where Mod is Ctrl

    test("KeyStroke: naming for a platform whose Mod is Ctrl") {
        // `modIsMeta: false` is for a host on a platform where the primary
        // modifier is Control. This package targets macOS and iOS, so nothing
        // in tree passes it; an adapter elsewhere would.
        let ctrl = KeyStroke(key: "b", control: true)
        try expectEqual(ctrl.bindingName(modIsMeta: false), "Mod-b")
        try expectEqual(ctrl.bindingName(), "Ctrl-b", "the default reading is unchanged")
        // Known wart, pinned rather than fixed: with Mod bound to Control, a
        // meta press has nowhere to go and drops out of the name. There is no
        // supported platform where that combination arises, and "Meta-b" would
        // normalize back to "Mod-b" anyway — the two would collide.
        try expectEqual(KeyStroke(key: "b", meta: true).bindingName(modIsMeta: false), "b")
    }

    // MARK: Equality

    test("KeyStroke: strokes differing by a modifier are different strokes") {
        try expect(KeyStroke(key: "a", meta: true) != KeyStroke(key: "a"))
        try expect(KeyStroke(key: "a", shift: true) != KeyStroke(key: "a", alt: true))
        try expectEqual(KeyStroke(key: "a", meta: true), KeyStroke(key: "a", meta: true))
        var seen = Set<KeyStroke>()
        seen.insert(KeyStroke(key: "a", meta: true))
        try expect(seen.contains(KeyStroke(key: "a", meta: true)))
        try expect(!seen.contains(KeyStroke(key: "a")))
    }
}

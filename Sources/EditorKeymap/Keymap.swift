import DocumentModel
public import EditorStateKit
public import EditorCommands

/// A platform-neutral description of a key press. Adapters translate native
/// events (NSEvent / UIKey) into this and feed it to the keymap.
public struct KeyStroke: Hashable, Sendable {
    public var key: String          // e.g. "a", "Enter", "Backspace", "ArrowLeft"
    public var shift: Bool
    public var alt: Bool
    public var control: Bool
    public var meta: Bool            // Command on macOS

    public init(key: String, shift: Bool = false, alt: Bool = false, control: Bool = false, meta: Bool = false) {
        self.key = key
        self.shift = shift
        self.alt = alt
        self.control = control
        self.meta = meta
    }

    /// Whether the primary platform modifier ("Mod") is down. On Apple
    /// platforms this is Command.
    public var mod: Bool { meta }

    /// Canonical key-binding name, e.g. "Mod-Shift-z" or "Backspace".
    public func bindingName(modIsMeta: Bool = true) -> String {
        var parts: [String] = []
        if (modIsMeta ? meta : control) { parts.append("Mod") }
        if (modIsMeta ? control : false) { parts.append("Ctrl") }
        if alt { parts.append("Alt") }
        if shift { parts.append("Shift") }
        parts.append(key)
        return parts.joined(separator: "-")
    }
}

/// Normalize a binding string into the canonical modifier order used for
/// lookup (Mod, Ctrl, Alt, Shift, then key).
public func normalizeKeyName(_ name: String) -> String {
    let parts = name.split(separator: "-").map(String.init)
    guard let key = parts.last else { return name }
    var mod = false, ctrl = false, alt = false, shift = false
    for p in parts.dropLast() {
        // Single letters are w3c-keyname's aliases (c-s-Space == Ctrl-Shift-Space).
        switch p.lowercased() {
        case "mod", "cmd", "meta", "m": mod = true
        case "ctrl", "control", "c": ctrl = true
        case "alt", "option", "a": alt = true
        case "shift", "s": shift = true
        default: break
        }
    }
    var result: [String] = []
    if mod { result.append("Mod") }
    if ctrl { result.append("Ctrl") }
    if alt { result.append("Alt") }
    if shift { result.append("Shift") }
    result.append(key)
    return result.joined(separator: "-")
}

/// Build a keymap plugin from a binding table.
public func keymap(_ bindings: [String: Command]) -> Plugin {
    var normalized: [String: Command] = [:]
    for (name, command) in bindings { normalized[normalizeKeyName(name)] = command }
    let table = normalized
    return Plugin(props: PluginProps(handleKeyDown: { key, state, dispatch in
        if let command = table[normalizeKeyName(key)] {
            return command(state, dispatch, nil)
        }
        return false
    }))
}

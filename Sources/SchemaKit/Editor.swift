import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit
import EditorCommands
import EditorHistory
import EditorKeymap

/// The high-level editor facade (the Tiptap `Editor`). Builds a schema from a
/// set of extensions, owns the `EditorState`, and exposes commands.
public final class Editor {
    public private(set) var manager: ExtensionManager
    public private(set) var state: EditorState
    /// Called after every state update.
    public var onChange: ((EditorState) -> Void)?
    /// Optional host for view-dependent command behaviour.
    public weak var host: AnyObject?

    private var namedCommands: [String: Command] = [:]

    public var schema: Schema { manager.schema }

    /// Create an editor from extensions and optional initial content (a doc
    /// node, or `nil` for an empty document).
    public init(extensions: [Extension], content: Node? = nil, history includeHistory: Bool = true) throws {
        let manager = try ExtensionManager(extensions)
        self.manager = manager
        // Temporary placeholder state; rebuilt below once `self` exists.
        self.state = EditorState.create(EditorStateConfig(schema: manager.schema))

        var plugins: [Plugin] = []
        if includeHistory {
            plugins.append(EditorHistory.history())
        }
        plugins.append(contentsOf: manager.buildPlugins(editor: self))
        if includeHistory {
            // Undo/redo keymap as a final keymap layer.
            plugins.append(keymap([
                "Mod-z": { s, d, _ in EditorHistory.undo(s, d) },
                "Mod-y": { s, d, _ in EditorHistory.redo(s, d) },
                "Shift-Mod-z": { s, d, _ in EditorHistory.redo(s, d) },
            ]))
        }
        self.state = EditorState.create(EditorStateConfig(schema: manager.schema, doc: content, plugins: plugins))
        self.namedCommands = manager.commands(editor: self)
    }

    // MARK: - Dispatch

    /// Apply a transaction and notify observers. Stamps the transaction's time
    /// so undo history groups rapid edits but separates distinct user actions.
    public func dispatch(_ tr: Transaction) {
        if tr.time == 0 { tr.time = Date().timeIntervalSince1970 * 1000 }
        state = state.apply(tr)
        onChange?(state)
    }

    /// Run a command against the current state, dispatching its transaction.
    @discardableResult
    public func run(_ command: Command) -> Bool {
        command(state, { [weak self] tr in self?.dispatch(tr) }, host as? CommandHost)
    }

    /// Whether a command would apply (a dry run, without dispatching).
    public func can(_ command: Command) -> Bool {
        command(state, nil, host as? CommandHost)
    }

    /// Run a named command contributed by an extension.
    @discardableResult
    public func run(_ name: String) -> Bool {
        guard let command = namedCommands[name] else { return false }
        return run(command)
    }

    /// Run a sequence of commands as a chain, threading state through each.
    /// Returns true if all applied.
    @discardableResult
    public func chain(_ commands: [Command]) -> Bool {
        var working = state
        var any = false
        for command in commands {
            var produced: Transaction? = nil
            let did = command(working, { produced = $0 }, host as? CommandHost)
            if did, let tr = produced {
                working = working.apply(tr)
                any = true
            } else if !did {
                return false
            }
        }
        if any {
            state = working
            onChange?(state)
        }
        return true
    }

    // MARK: - Queries

    /// Whether the selection is inside a node of the given name (and attrs).
    public func isActive(node name: String, attrs: Attrs? = nil) -> Bool {
        guard let type = schema.nodes[name] else { return false }
        let sel = state.selection
        let from = sel.resolvedFrom
        var depth = from.depth
        while depth >= 0 {
            let node = from.node(depth)
            if node.type === type, attrs == nil || attrsMatch(node.attrs, attrs!) { return true }
            depth -= 1
        }
        // node selection on a leaf
        if let ns = sel as? NodeSelection, ns.node.type === type {
            return attrs == nil || attrsMatch(ns.node.attrs, attrs!)
        }
        return false
    }

    /// Whether the given mark is active over the selection (or stored).
    public func isActive(mark name: String) -> Bool {
        guard let type = schema.marks[name] else { return false }
        let sel = state.selection
        if sel.empty {
            let marks = state.storedMarks ?? sel.resolvedFrom.marks()
            return type.isInSet(marks) != nil
        }
        for range in sel.ranges {
            if !state.doc.rangeHasMark(range.from.pos, range.to.pos, type) { return false }
            // Ensure it covers the whole range, not just part of it.
            var covered = true
            state.doc.nodesBetween(range.from.pos, range.to.pos, { node, _, _, _ in
                if node.isInline && type.isInSet(node.marks) == nil { covered = false }
                return true
            })
            if !covered { return false }
        }
        return true
    }

    /// The attributes of the closest ancestor node of the given name.
    public func attributes(ofNode name: String) -> Attrs? {
        guard let type = schema.nodes[name] else { return nil }
        let from = state.selection.resolvedFrom
        var depth = from.depth
        while depth >= 0 {
            let node = from.node(depth)
            if node.type === type { return node.attrs }
            depth -= 1
        }
        return nil
    }

    // MARK: - Content

    public var doc: Node { state.doc }
    public func json() -> [String: AttributeValue] { state.doc.toJSON() }

    public func setContent(_ doc: Node) {
        let tr = state.tr
        try? tr.replaceWith(0, state.doc.content.size, doc.content)
        tr.setSelection(Selection.atStart(tr.doc))
        tr.setMeta("addToHistory", false) // initial/replaced content isn't undoable
        dispatch(tr)
    }
}

private func attrsMatch(_ a: Attrs, _ subset: Attrs) -> Bool {
    for (key, value) in subset where a[key] != value { return false }
    return true
}

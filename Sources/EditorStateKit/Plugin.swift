import Foundation
import DocumentModel
import DocumentTransform

/// Describes the state a plugin contributes to the editor state: how to
/// initialize it and how to advance it across a transaction.
public struct PluginStateField {
    public let initialize: @Sendable (_ config: EditorStateConfig, _ state: EditorState) -> Any
    public let apply: @Sendable (_ tr: Transaction, _ value: Any, _ oldState: EditorState, _ newState: EditorState) -> Any

    public init(
        initialize: @escaping @Sendable (_ config: EditorStateConfig, _ state: EditorState) -> Any,
        apply: @escaping @Sendable (_ tr: Transaction, _ value: Any, _ oldState: EditorState, _ newState: EditorState) -> Any
    ) {
        self.initialize = initialize
        self.apply = apply
    }
}

/// View/behaviour props contributed by a plugin. Editing-related hooks live
/// here; the view layer reads the rest. These run on the main actor in the view
/// layer; `Plugin` is `@unchecked Sendable` and owns them.
public struct PluginProps {
    public typealias Dispatch = (Transaction) -> Void
    /// Keyboard handler: return true if handled. (Used by the keymap plugin.)
    public var handleKeyDown: ((_ key: String, _ state: EditorState, _ dispatch: Dispatch?) -> Bool)?
    /// Text input handler.
    public var handleTextInput: ((_ from: Int, _ to: Int, _ text: String, _ state: EditorState, _ dispatch: Dispatch?) -> Bool)?
    /// Decorations this plugin wants drawn over the document.
    public var decorations: ((_ state: EditorState) -> DecorationSet?)?

    public init(
        handleKeyDown: ((_ key: String, _ state: EditorState, _ dispatch: Dispatch?) -> Bool)? = nil,
        handleTextInput: ((_ from: Int, _ to: Int, _ text: String, _ state: EditorState, _ dispatch: Dispatch?) -> Bool)? = nil,
        decorations: ((_ state: EditorState) -> DecorationSet?)? = nil
    ) {
        self.handleKeyDown = handleKeyDown
        self.handleTextInput = handleTextInput
        self.decorations = decorations
    }
}

/// A plugin bundles editor behaviour: optional persistent state, transaction
/// hooks, and view props.
public final class Plugin: @unchecked Sendable {
    public let key: String
    public let stateField: PluginStateField?
    public let appendTransaction: (@Sendable (_ transactions: [Transaction], _ oldState: EditorState, _ newState: EditorState) -> Transaction?)?
    public let filterTransaction: (@Sendable (_ tr: Transaction, _ state: EditorState) -> Bool)?
    public let props: PluginProps?

    public init(
        key: String? = nil,
        stateField: PluginStateField? = nil,
        appendTransaction: (@Sendable (_ transactions: [Transaction], _ oldState: EditorState, _ newState: EditorState) -> Transaction?)? = nil,
        filterTransaction: (@Sendable (_ tr: Transaction, _ state: EditorState) -> Bool)? = nil,
        props: PluginProps? = nil
    ) {
        self.key = key ?? PluginKeyCounter.next()
        self.stateField = stateField
        self.appendTransaction = appendTransaction
        self.filterTransaction = filterTransaction
        self.props = props
    }

    /// Get this plugin's state from an editor state.
    public func getState(_ state: EditorState) -> Any? {
        state.pluginState[key]
    }
}

/// A typed handle to a plugin's state, used to retrieve it from an editor state.
public final class PluginKey<T>: @unchecked Sendable {
    public let key: String
    public init(_ name: String = "key") {
        self.key = PluginKeyCounter.next(name)
    }
    public func getState(_ state: EditorState) -> T? {
        state.pluginState[key] as? T
    }
}

enum PluginKeyCounter {
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    private static let lock = NSLock()
    static func next(_ name: String = "plugin") -> String {
        lock.lock(); defer { lock.unlock() }
        let n = (counts[name] ?? 0) + 1
        counts[name] = n
        return "\(name)$\(n)"
    }
}

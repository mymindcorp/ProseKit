import DocumentModel
import DocumentTransform
public import EditorStateKit

/// Optional host the command layer can query for view-dependent facts (such as
/// whether the cursor is visually at the start/end of a textblock). The shared
/// command layer never imports a UI framework; adapters provide this.
public protocol CommandHost: AnyObject {
    /// Whether the selection is at the visual start ("backward"/"up") or end
    /// ("forward"/"down") of its textblock. Return `nil` if unknown.
    func endOfTextblock(_ dir: String, _ state: EditorState) -> Bool?
}

/// A dispatch function that applies a transaction.
public typealias Dispatch = (Transaction) -> Void

/// Commands are functions that take a state and, optionally, a dispatch
/// function and a host. They return `true` when they apply to the given state.
/// When a `dispatch` is given, they should produce their effect by dispatching
/// a transaction.
public typealias Command = @Sendable (_ state: EditorState, _ dispatch: Dispatch?, _ host: (any CommandHost)?) -> Bool

/// Combine a number of commands into one. The combined command runs them in
/// order until one returns `true`.
public func chainCommands(_ commands: Command...) -> Command {
    chainCommands(commands)
}

public func chainCommands(_ commands: [Command]) -> Command {
    { state, dispatch, host in
        for command in commands {
            if command(state, dispatch, host) { return true }
        }
        return false
    }
}

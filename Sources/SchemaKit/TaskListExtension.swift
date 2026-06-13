import DocumentModel
import DocumentTransform
import EditorStateKit
import EditorCommands
import EditorInputRules

// Task lists, matching Tiptap's TaskList / TaskItem (node names `taskList` and
// `taskItem`, with a boolean `checked` attribute on each item).

public final class TaskListExtension: NodeExtension {
    public let name = "taskList"
    public init() {}
    public var nodeSpec: NodeSpec { NodeSpec(content: "taskItem+", group: "block") }
    public var html: HTMLSpec { HTMLSpec(tag: "ul") }
    public func commands(_ ctx: ExtensionContext) -> [String: Command] {
        guard let type = ctx.nodeType, let item = ctx.schema.nodes["taskItem"] else { return [:] }
        return ["toggleTaskList": toggleList(type, item)]
    }
    public func keyboardShortcuts(_ ctx: ExtensionContext) -> [String: Command] {
        guard let type = ctx.nodeType, let item = ctx.schema.nodes["taskItem"] else { return [:] }
        return ["Mod-Shift-9": toggleList(type, item)]
    }
    public func inputRules(_ ctx: ExtensionContext) -> [InputRule] {
        guard let type = ctx.nodeType else { return [] }
        // "[ ] " or "[x] " at the start of a block makes a task list.
        return [wrappingInputRule("^\\s*\\[[ xX]?\\]\\s$", type)]
    }
}

public final class TaskItemExtension: NodeExtension {
    public let name = "taskItem"
    public init() {}
    public var nodeSpec: NodeSpec {
        NodeSpec(content: "paragraph block*", attrs: ["checked": AttributeSpec(default: .bool(false))], defining: true)
    }
    public var html: HTMLSpec { HTMLSpec(tag: "li") }
    public func commands(_ ctx: ExtensionContext) -> [String: Command] {
        guard let type = ctx.nodeType else { return [:] }
        return ["toggleTaskChecked": toggleTaskChecked(type)]
    }
    public func keyboardShortcuts(_ ctx: ExtensionContext) -> [String: Command] {
        guard let item = ctx.nodeType else { return [:] }
        return [
            // A task created by splitting (Enter) always starts unchecked,
            // never inheriting the current item's checked state.
            "Enter": splitListItem(item, ["checked": .bool(false)]),
            "Tab": sinkListItem(item),
            "Shift-Tab": liftListItem(item),
        ]
    }
}

/// Toggle the `checked` attribute of the task item containing the selection.
public func toggleTaskChecked(_ itemType: NodeType) -> Command {
    { state, dispatch, _ in
        let from = state.selection.resolvedFrom
        var depth = from.depth
        while depth > 0 {
            if from.node(depth).type === itemType {
                let pos = from.before(depth)
                let checked = from.node(depth).attrs["checked"]?.boolValue ?? false
                if let dispatch {
                    try? dispatch(state.tr.setNodeAttribute(pos, "checked", .bool(!checked)))
                }
                return true
            }
            depth -= 1
        }
        return false
    }
}

/// Set the `checked` attribute of the task item at the given document position.
public func setTaskChecked(_ state: EditorState, pos: Int, checked: Bool) -> Transaction? {
    guard let node = state.doc.nodeAt(pos), node.type.name == "taskItem" else { return nil }
    return try? state.tr.setNodeAttribute(pos, "checked", .bool(checked))
}

/// The task-list extensions (list + item).
public func taskListExtensions() -> [Extension] {
    [TaskListExtension(), TaskItemExtension()]
}

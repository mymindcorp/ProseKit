public import DocumentModel
import DocumentTransform
public import EditorStateKit
public import EditorCommands
public import EditorInputRules

// Task lists, matching Tiptap's TaskList / TaskItem (node names `taskList` and
// `taskItem`, with a boolean `checked` attribute on each item).

public final class TaskListExtension: NodeExtension {
    public let name = "taskList"
    /// Behaviour options; see `TaskListOptions`.
    public let options: TaskListOptions
    public init(options: TaskListOptions = TaskListOptions()) { self.options = options }
    public var nodeSpec: NodeSpec { NodeSpec(content: "taskItem+", group: "block") }
    public func plugins(_ ctx: ExtensionContext) -> [Plugin] {
        options.sortCompletedToBottom ? [taskSortPlugin()] : []
    }
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
        guard let type = ctx.nodeType, let item = ctx.schema.nodes["taskItem"] else { return [] }
        // "[ ] " or "[x] " at the start of a block makes a task list.
        // The checked attribute belongs to the item wrapper, not the list.
        return [InputRule("^\\s*\\[([ xX]?)\\]\\s$") { state, match, start, end in
            let tr = state.tr
            guard (try? tr.delete(start, end)) != nil,
                  let range = tr.doc.resolve(start).blockRange(),
                  let wrapping = findWrappingForRange(range, type) else { return nil }
            let checked = match[1]?.lowercased() == "x"
            let wrappers = wrapping.map { wrapper in
                guard wrapper.type === item else { return wrapper }
                var attrs = wrapper.attrs
                attrs["checked"] = .bool(checked)
                return NodeTypeWithAttrs(wrapper.type, attrs)
            }
            guard (try? tr.wrap(range, wrappers)) != nil else { return nil }
            if start > 0, tr.doc.resolve(start - 1).nodeBefore?.type === type,
               canJoin(tr.doc, start - 1) {
                _ = try? tr.join(start - 1)
            }
            return tr
        }]
    }
}

public final class TaskItemExtension: NodeExtension {
    public let name = "taskItem"
    /// Behaviour options; see `TaskListOptions`.
    public let options: TaskListOptions
    public init(options: TaskListOptions = TaskListOptions()) { self.options = options }
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
            "Tab": listItemShortcut(item, sinkListItem(item)),
            "Shift-Tab": listItemShortcut(item, liftListItem(item)),
        ]
    }
}

/// Toggle the `checked` attribute of the task item containing the selection.
public func toggleTaskChecked(_ itemType: NodeType) -> Command {
    { state, dispatch, _ in
        guard let target = selectedNodeOrAncestor(state, itemType) else { return false }
        let checked = target.node.attrs["checked"]?.boolValue ?? false
        if let dispatch {
            guard let tr = try? state.tr.setNodeAttribute(target.pos, "checked", .bool(!checked)) else { return false }
            // Sorting (when it's on) rides along in the same transaction.
            sortTasksInPlace(tr, state)
            dispatch(tr)
        }
        return true
    }
}

/// Set the `checked` attribute of the task item at the given document position.
public func setTaskChecked(_ state: EditorState, pos: Int, checked: Bool) -> Transaction? {
    guard let node = state.doc.nodeAt(pos), node.type.name == "taskItem",
          let tr = try? state.tr.setNodeAttribute(pos, "checked", .bool(checked)) else { return nil }
    // Sorting (when it's on) rides along in the same transaction.
    sortTasksInPlace(tr, state)
    return tr
}

/// The task-list extensions (list + item).
public func taskListExtensions(options: TaskListOptions = TaskListOptions()) -> [any Extension] {
    [TaskListExtension(options: options), TaskItemExtension(options: options)]
}

import EditorStateKit

/// The base set of key bindings shared across platforms, mapping key names to
/// commands. The keymap plugin (EditorKeymap) interprets `Mod-` against the
/// platform's primary modifier.
public let baseKeymap: [String: Command] = [
    "Enter": chainCommands(newlineInCode, createParagraphNear, liftEmptyBlock, splitBlock),
    "Backspace": chainCommands(deleteSelection, joinBackward, selectNodeBackward),
    "Mod-Backspace": chainCommands(deleteSelection, joinBackward, selectNodeBackward),
    "Delete": chainCommands(deleteSelection, joinForward, selectNodeForward),
    "Mod-Delete": chainCommands(deleteSelection, joinForward, selectNodeForward),
    "Mod-a": selectAll,
    "Mod-Enter": exitCode,
    "Escape": selectParentNode,
]

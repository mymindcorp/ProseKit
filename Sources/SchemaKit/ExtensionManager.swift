import DocumentModel
import EditorStateKit
import EditorCommands
import EditorKeymap
import EditorInputRules

/// Resolves a list of extensions into a compiled `Schema`, a merged set of
/// commands, and the ProseMirror plugins (input rules, keymap, and any
/// extension-provided plugins). Mirrors Tiptap's resolution order.
public final class ExtensionManager {
    public let extensions: [any Extension]
    public let schema: Schema
    private let htmlByName: [String: HTMLSpec]

    public init(_ extensions: [any Extension]) throws(ModelError) {
        // Sort by priority (descending), stable on declaration order.
        let sorted = extensions.enumerated().sorted { a, b in
            a.element.priority != b.element.priority
                ? a.element.priority > b.element.priority
                : a.offset < b.offset
        }.map { $0.element }
        self.extensions = sorted

        var nodeSpecs: [(String, NodeSpec)] = []
        var markSpecs: [(String, MarkSpec)] = []
        var html: [String: HTMLSpec] = [:]
        for ext in sorted {
            if let node = ext as? any NodeExtension {
                nodeSpecs.append((node.name, node.nodeSpec))
                html[node.name] = node.html
            } else if let mark = ext as? any MarkExtension {
                markSpecs.append((mark.name, mark.markSpec))
                html[mark.name] = mark.html
            }
        }
        guard nodeSpecs.contains(where: { $0.0 == "doc" }) else {
            throw ModelError.schemaError("Extensions must include a top-level 'doc' node")
        }
        // Merge in global attributes (Tiptap's addGlobalAttributes) before
        // compiling the schema, so extensions like UniqueID can add attributes
        // to nodes they don't own. Existing attributes are never overwritten.
        let globals = sorted.flatMap { $0.globalAttributes() }
        if !globals.isEmpty {
            nodeSpecs = nodeSpecs.map { name, spec in
                var spec = spec
                for global in globals {
                    let applies = global.types.contains("all")
                        ? (name != "doc" && name != "text")
                        : global.types.contains(name)
                    guard applies else { continue }
                    for (attr, attrSpec) in global.attributes where spec.attrs[attr] == nil {
                        spec.attrs[attr] = attrSpec
                    }
                }
                return (name, spec)
            }
        }
        self.schema = try Schema(nodes: nodeSpecs, marks: markSpecs, topNode: "doc")
        self.htmlByName = html
    }

    func context(for ext: any Extension, editor: Editor?) -> ExtensionContext {
        ExtensionContext(
            schema: schema,
            nodeType: schema.nodes[ext.name],
            markType: schema.marks[ext.name],
            editor: editor)
    }

    /// All named commands contributed by the extensions.
    public func commands(editor: Editor?) -> [String: Command] {
        var result: [String: Command] = [:]
        for ext in extensions {
            for (name, command) in ext.commands(context(for: ext, editor: editor)) {
                result[name] = command
            }
        }
        return result
    }

    /// The merged keyboard-shortcut table (higher-priority extensions win).
    public func keyboardShortcuts(editor: Editor?) -> [String: Command] {
        var result: [String: Command] = [:]
        for ext in extensions {
            for (key, command) in ext.keyboardShortcuts(context(for: ext, editor: editor)) {
                if result[normalizeKeyName(key)] == nil { result[normalizeKeyName(key)] = command }
            }
        }
        return result
    }

    /// All input rules contributed by the extensions.
    public func inputRules(editor: Editor?) -> [InputRule] {
        extensions.flatMap { $0.inputRules(context(for: $0, editor: editor)) }
    }

    /// All suggestion sources contributed by the extensions.
    public func suggestionSources(editor: Editor?) -> [any SuggestionSource] {
        extensions.flatMap { $0.suggestionSources(context(for: $0, editor: editor)) }
    }

    /// Build the full ordered plugin list: extension plugins, then the input-
    /// rules plugin, then the keymap (extension shortcuts falling back to the
    /// base keymap).
    public func buildPlugins(editor: Editor?) -> [Plugin] {
        var plugins: [Plugin] = []
        for ext in extensions {
            plugins.append(contentsOf: ext.plugins(context(for: ext, editor: editor)))
        }
        let rules = inputRules(editor: editor)
        if !rules.isEmpty { plugins.append(EditorInputRules.inputRules(rules)) }

        // Collect every command bound to each key across extensions (in
        // priority order), then chain them — falling back to the base keymap —
        // so e.g. Enter tries splitListItem for whichever list type applies.
        var perKey: [String: [Command]] = [:]
        // Backspace right after an input rule fired reverts the rule (PM/Tiptap
        // behavior) — it only claims the key when the last transaction was a
        // rule application, so it must run before everything else.
        if !rules.isEmpty {
            perKey[normalizeKeyName("Backspace"), default: []].append { state, dispatch, _ in
                undoInputRule(state, dispatch)
            }
        }
        for ext in extensions {
            for (key, command) in ext.keyboardShortcuts(context(for: ext, editor: editor)) {
                perKey[normalizeKeyName(key), default: []].append(command)
            }
        }
        var normalizedBase: [String: Command] = [:]
        for (key, command) in baseKeymap { normalizedBase[normalizeKeyName(key)] = command }

        var bindings: [String: Command] = [:]
        for key in Set(perKey.keys).union(normalizedBase.keys) {
            var chain = perKey[key] ?? []
            if let base = normalizedBase[key] { chain.append(base) }
            bindings[key] = chain.count == 1 ? chain[0] : chainCommands(chain)
        }
        plugins.append(keymap(bindings))
        return plugins
    }

    public func html(for name: String) -> HTMLSpec? { htmlByName[name] }
}

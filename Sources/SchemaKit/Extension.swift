import DocumentModel
import EditorStateKit
import EditorCommands
import EditorInputRules

/// The context handed to an extension's hooks once the schema is compiled. It
/// exposes the schema and this extension's resolved node/mark type.
public final class ExtensionContext {
    public let schema: Schema
    public let nodeType: NodeType?
    public let markType: MarkType?
    public weak var editor: Editor?

    init(schema: Schema, nodeType: NodeType?, markType: MarkType?, editor: Editor?) {
        self.schema = schema
        self.nodeType = nodeType
        self.markType = markType
        self.editor = editor
    }
}

/// Base protocol for all extensions. An extension contributes some combination
/// of: a node/mark to the schema, named commands, keyboard shortcuts, input
/// rules, and ProseMirror plugins. This is the Tiptap authoring layer.
public protocol Extension: AnyObject {
    /// A unique name. For node/mark extensions this is the schema type name.
    var name: String { get }
    /// Resolution priority — higher runs earlier (Tiptap default 100).
    var priority: Int { get }

    /// Named commands contributed by this extension.
    func commands(_ ctx: ExtensionContext) -> [String: Command]
    /// Keyboard shortcuts, mapping key-binding names to commands.
    func keyboardShortcuts(_ ctx: ExtensionContext) -> [String: Command]
    /// Input rules contributed by this extension.
    func inputRules(_ ctx: ExtensionContext) -> [InputRule]
    /// Raw ProseMirror plugins contributed by this extension.
    func plugins(_ ctx: ExtensionContext) -> [Plugin]
    /// Suggestion menus (slash `/`, wiki `[[`, mentions `@`, …) this extension
    /// drives. The renderer shows their popups generically.
    func suggestionSources(_ ctx: ExtensionContext) -> [any SuggestionSource]
}

public extension Extension {
    var priority: Int { 100 }
    func commands(_ ctx: ExtensionContext) -> [String: Command] { [:] }
    func keyboardShortcuts(_ ctx: ExtensionContext) -> [String: Command] { [:] }
    func inputRules(_ ctx: ExtensionContext) -> [InputRule] { [] }
    func plugins(_ ctx: ExtensionContext) -> [Plugin] { [] }
    func suggestionSources(_ ctx: ExtensionContext) -> [any SuggestionSource] { [] }
}

/// HTML round-trip hints for a node/mark, used by the serialization layer (M6).
public struct HTMLSpec: Sendable {
    /// The tag this node/mark parses from and renders to (e.g. "p", "strong").
    public var tag: String?
    /// Extra parse tags (e.g. bold also parses from "b" and font-weight).
    public var parseTags: [String]
    public init(tag: String? = nil, parseTags: [String] = []) {
        self.tag = tag
        self.parseTags = parseTags
    }
}

/// An extension that contributes a node type to the schema.
public protocol NodeExtension: Extension {
    /// The ProseMirror node spec for this node.
    var nodeSpec: NodeSpec { get }
    /// HTML round-trip hints.
    var html: HTMLSpec { get }
}

public extension NodeExtension {
    var html: HTMLSpec { HTMLSpec() }
}

/// An extension that contributes a mark type to the schema.
public protocol MarkExtension: Extension {
    /// The ProseMirror mark spec for this mark.
    var markSpec: MarkSpec { get }
    /// HTML round-trip hints.
    var html: HTMLSpec { get }
}

public extension MarkExtension {
    var html: HTMLSpec { HTMLSpec() }
}

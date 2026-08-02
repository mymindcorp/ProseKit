public import Foundation
import DocumentModel
import DocumentTransform
public import EditorStateKit

/// Assigns a stable, unique id attribute to every node of the configured types
/// and keeps those ids unique as the document changes — a port of Tiptap's
/// `UniqueID` extension (https://tiptap.dev/docs/editor/extensions/functionality/uniqueid).
///
/// The attribute is added to the target nodes' schemas via `globalAttributes()`
/// (so existing node types don't need redefining), and an `appendTransaction`
/// plugin fills in ids for nodes that lack one and re-issues a fresh id whenever
/// two nodes end up sharing one — which is what happens when a node is split,
/// pasted, or duplicated. Ids are assigned in document order, so when a block is
/// split the upper half keeps its id and the new lower half gets a new one.
public final class UniqueIDExtension: Extension {
    public let name = "uniqueID"

    /// The attribute name that holds the id. Default `"id"`.
    public let attributeName: String
    /// The node type names that get an id. Use the special value `"all"` to apply
    /// to every node except `doc` and `text`. Defaults to empty (assigns nothing
    /// until configured), matching Tiptap.
    public let types: [String]
    /// Generates a fresh id. Defaults to a v4 UUID string.
    public let generateID: @Sendable () -> String
    /// Optional predicate to ignore some transactions (e.g. remote collab edits).
    /// When it returns `false` for any transaction in a batch, ids are left alone.
    public let filterTransaction: (@Sendable (Transaction) -> Bool)?

    public init(
        attributeName: String = "id",
        types: [String] = [],
        generateID: @escaping @Sendable () -> String = { UUID().uuidString },
        filterTransaction: (@Sendable (Transaction) -> Bool)? = nil
    ) {
        self.attributeName = attributeName
        self.types = types
        self.generateID = generateID
        self.filterTransaction = filterTransaction
    }

    public func globalAttributes() -> [GlobalAttribute] {
        guard !types.isEmpty else { return [] }
        return [GlobalAttribute(types: types, attributes: [attributeName: AttributeSpec(default: .null)])]
    }

    public func plugins(_ ctx: ExtensionContext) -> [Plugin] {
        guard !types.isEmpty else { return [] }
        let attr = attributeName
        let typeSet = Set(types)
        let all = types.contains("all")
        let generate = generateID
        let filter = filterTransaction
        return [Plugin(key: "uniqueID", appendTransaction: { trs, _, newState in
            // Skip selection-only changes for efficiency, but always run for the
            // initial priming seed (which changes nothing) so loaded content
            // gets ids on creation.
            let priming = trs.contains { ($0.getMeta(appendTransactionPrimeMeta) as? Bool) == true }
            if !priming && !trs.contains(where: { $0.docChanged }) { return nil }
            if let filter, trs.contains(where: { !filter($0) }) { return nil }
            return assignUniqueIDs(newState, attribute: attr, typeSet: typeSet, all: all, generate: generate)
        })]
    }
}

/// Returns a transaction that gives every targeted node a unique `attribute`
/// value, or nil if they are all already present and unique. Nodes are visited
/// in document order; the first holder of an id keeps it and any later node
/// repeating it (or missing one entirely) is assigned a fresh id.
func assignUniqueIDs(
    _ state: EditorState,
    attribute: String,
    typeSet: Set<String>,
    all: Bool,
    generate: @Sendable () -> String
) -> Transaction? {
    var seen = Set<String>()
    var tr: Transaction?
    state.doc.descendants { node, pos, _, _ in
        let applies = all ? (!node.isText && node.type.name != "doc") : typeSet.contains(node.type.name)
        guard applies else { return true }
        if case let .string(id)? = node.attrs[attribute], !seen.contains(id) {
            seen.insert(id)
        } else {
            var newID = generate()
            while seen.contains(newID) { newID = generate() }
            seen.insert(newID)
            // AttrStep preserves positions, so `pos` stays valid as we append.
            let t = tr ?? state.tr
            _ = try? t.setNodeAttribute(pos, attribute, .string(newID))
            tr = t
        }
        return true
    }
    return tr
}

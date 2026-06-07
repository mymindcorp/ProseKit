import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit

/// A remote participant's cursor/selection, in document positions. Positions are
/// mapped through every transaction so they stay correct as the document changes
/// — whether the change came from the local user or another participant.
public struct CollabCursor: Equatable, Sendable {
    public var id: String
    public var anchor: Int
    public var head: Int
    public var color: String   // "#RRGGBB" — the renderer converts to a UIColor
    public var label: String
    public init(id: String, anchor: Int, head: Int, color: String, label: String) {
        self.id = id
        self.anchor = anchor
        self.head = head
        self.color = color
        self.label = label
    }
    public var isCollapsed: Bool { anchor == head }
}

public let collabCursorsKey = PluginKey<[String: CollabCursor]>("collabCursors")

private let collabCursorMeta = "collabCursor$"

enum CollabCursorUpdate { case set(CollabCursor); case remove(String) }

/// Tracks remote cursors and keeps their positions valid by mapping them through
/// each transaction. Self-contained: the host sets/removes cursors via the
/// `Editor` API below; the renderer reads `editor.collabCursors` to draw them.
public final class CollabCursorExtension: Extension {
    public let name = "collabCursor"
    public init() {}
    public func plugins(_ ctx: ExtensionContext) -> [Plugin] {
        [Plugin(
            key: collabCursorsKey.key,
            stateField: PluginStateField(
                initialize: { _, _ in [String: CollabCursor]() as Any },
                apply: { tr, value, _, _ in
                    var cursors = value as! [String: CollabCursor]
                    // Map existing cursors through the document change so they
                    // ride along with edits made anywhere in the document.
                    if tr.docChanged {
                        for (id, c) in cursors {
                            cursors[id] = CollabCursor(id: id,
                                                       anchor: tr.mapping.map(c.anchor),
                                                       head: tr.mapping.map(c.head),
                                                       color: c.color, label: c.label)
                        }
                    }
                    if let update = tr.getMeta(collabCursorMeta) as? CollabCursorUpdate {
                        switch update {
                        case let .set(c): cursors[c.id] = c
                        case let .remove(id): cursors[id] = nil
                        }
                    }
                    return cursors as Any
                }))]
    }
}

public extension Editor {
    /// The remote cursors currently being tracked.
    var collabCursors: [CollabCursor] {
        Array((collabCursorsKey.getState(state) ?? [:]).values)
    }

    /// Set (or move) a remote participant's cursor/selection.
    func setCollabCursor(id: String, anchor: Int, head: Int, color: String, label: String) {
        let size = doc.content.size
        let cursor = CollabCursor(id: id,
                                  anchor: min(max(anchor, 0), size),
                                  head: min(max(head, 0), size),
                                  color: color, label: label)
        dispatch(state.tr.setMeta(collabCursorMeta, CollabCursorUpdate.set(cursor)))
    }

    /// Remove a remote participant's cursor.
    func removeCollabCursor(id: String) {
        dispatch(state.tr.setMeta(collabCursorMeta, CollabCursorUpdate.remove(id)))
    }
}

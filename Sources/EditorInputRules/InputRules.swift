import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit

/// An input rule maps a regular expression matching the text before the cursor
/// to a transformation. When the user types and the rule's pattern matches, the
/// handler runs.
public struct InputRule {
    let regex: NSRegularExpression
    let handler: (_ state: EditorState, _ match: [String?], _ start: Int, _ end: Int) -> Transaction?
    /// When true, the rule may fire on text already present (used for paste).
    let inCode: Bool

    public init(_ pattern: String, inCode: Bool = false, handler: @escaping (_ state: EditorState, _ match: [String?], _ start: Int, _ end: Int) -> Transaction?) {
        self.regex = try! NSRegularExpression(pattern: pattern)
        self.handler = handler
        self.inCode = inCode
    }
}

public final class InputRulesState: @unchecked Sendable {
    var transform: Transaction?
    var from: Int = 0
    var to: Int = 0
    var text: String = ""
}

nonisolated(unsafe) public let inputRulesKey = PluginKey<InputRulesState>("inputRules")

private let MAX_MATCH = 500

/// Create the input-rules plugin.
public func inputRules(_ rules: [InputRule]) -> Plugin {
    let stateBox = InputRulesState()
    return Plugin(
        key: inputRulesKey.key,
        stateField: PluginStateField(
            initialize: { _, _ in stateBox },
            apply: { tr, value, _, _ in
                let s = value as! InputRulesState
                if let stored = tr.getMeta("applyInputRule") as? (from: Int, to: Int, text: String) {
                    s.from = stored.from; s.to = stored.to; s.text = stored.text; s.transform = tr
                } else if tr.docChanged {
                    s.transform = nil
                }
                return s
            }),
        props: PluginProps(handleTextInput: { from, to, text, state, dispatch in
            run(state, from, to, text, rules, dispatch)
        }))
}

private func run(_ state: EditorState, _ from: Int, _ to: Int, _ text: String, _ rules: [InputRule], _ dispatch: ((Transaction) -> Void)?) -> Bool {
    let resolvedFrom = state.doc.resolve(from)
    if resolvedFrom.parent.type.spec.code { return false }
    let lo = max(0, resolvedFrom.parentOffset - MAX_MATCH)
    let textBefore = resolvedFrom.parent.textBetween(lo, resolvedFrom.parentOffset, blockSeparator: nil, leafText: "\u{fffc}") + text
    for rule in rules {
        let ns = textBefore as NSString
        guard let m = rule.regex.firstMatch(in: textBefore, range: NSRange(location: 0, length: ns.length)) else { continue }
        var groups: [String?] = []
        for i in 0..<m.numberOfRanges {
            let r = m.range(at: i)
            groups.append(r.location == NSNotFound ? nil : ns.substring(with: r))
        }
        let matchLen = (groups[0] ?? "").count
        let start = from - (matchLen - text.count)
        if let tr = rule.handler(state, groups, start, to) {
            dispatch?(tr.setMeta("applyInputRule", (from: start, to: to, text: text)))
            return true
        }
    }
    return false
}

// MARK: - Rule builders

/// Build a rule that wraps the matched block in a node of the given type.
public func wrappingInputRule(_ pattern: String, _ nodeType: NodeType, _ getAttrs: (([String?]) -> Attrs)? = nil, joinPredicate: (([String?], Node) -> Bool)? = nil) -> InputRule {
    InputRule(pattern) { state, match, start, end in
        let attrs = getAttrs?(match) ?? [:]
        let tr = state.tr
        try? tr.delete(start, end)
        let resolvedStart = tr.doc.resolve(start)
        guard let range = resolvedStart.blockRange(),
              let wrapping = findWrappingForRange(range, nodeType, attrs) else { return nil }
        try? tr.wrap(range, wrapping)
        if start - 1 >= 0, let before = tr.doc.resolve(start - 1).nodeBefore,
           before.type === nodeType, canJoin(tr.doc, start - 1),
           joinPredicate?(match, before) ?? true {
            try? tr.join(start - 1)
        }
        return tr
    }
}

/// Build a rule that changes the textblock type of the matched block.
public func textblockTypeInputRule(_ pattern: String, _ nodeType: NodeType, _ getAttrs: (([String?]) -> Attrs)? = nil) -> InputRule {
    InputRule(pattern) { state, match, start, end in
        let resolvedStart = state.doc.resolve(start)
        let attrs = getAttrs?(match) ?? [:]
        if !resolvedStart.node(-1).canReplaceWith(resolvedStart.index(-1), resolvedStart.indexAfter(-1), nodeType) {
            return nil
        }
        let tr = state.tr
        try? tr.delete(start, end)
        try? tr.setBlockType(start, start, nodeType, attrs)
        return tr
    }
}

/// Build a rule that applies a mark to the text matched by its last capture
/// group, stripping the surrounding marker characters (Tiptap-style, e.g.
/// `**bold**` → bold "bold"). The captured group must be the inner text; any
/// leading whitespace consumed by the pattern is preserved.
public func markInputRule(_ pattern: String, _ markType: MarkType, _ getAttrs: (([String?]) -> Attrs)? = nil) -> InputRule {
    InputRule(pattern) { state, match, start, end in
        let fullMatch = match[0] ?? ""
        // The inner text is the last participating capture group.
        guard let inner = match.dropFirst().compactMap({ $0 }).last, !inner.isEmpty,
              let innerRange = fullMatch.range(of: inner) else { return nil }
        let attrs = getAttrs?(match) ?? [:]

        // Leading whitespace the pattern consumed (kept, not deleted).
        var leadingSpaces = 0
        for ch in fullMatch { if ch == " " || ch == "\t" || ch == "\n" { leadingSpaces += 1 } else { break } }
        let innerOffset = fullMatch.distance(from: fullMatch.startIndex, to: innerRange.lowerBound)
        let textStart = start + innerOffset
        let textEnd = textStart + inner.count

        let tr = state.tr
        // Delete trailing markers first so the earlier positions stay valid,
        // then the opening markers (after any leading whitespace).
        if textEnd < end { try? tr.delete(textEnd, end) }
        if textStart > start + leadingSpaces { try? tr.delete(start + leadingSpaces, textStart) }
        let markStart = start + leadingSpaces
        try? tr.addMark(markStart, markStart + inner.count, markType.create(attrs))
        tr.removeStoredMark(markType)
        return tr
    }
}

/// Replaces `--` with an em-dash.
nonisolated(unsafe) public let emDashRule = InputRule("--$") { state, _, start, end in
    let t = state.tr
    try? t.insertText("\u{2014}", start, end)
    return t
}

/// Replaces three dots with an ellipsis character.
nonisolated(unsafe) public let ellipsisRule = InputRule("\\.\\.\\.$") { state, _, start, end in
    let t = state.tr
    try? t.insertText("\u{2026}", start, end)
    return t
}

// MARK: - Undo

/// Undo the input rule that was just applied, if the previous transaction was
/// an input rule.
nonisolated(unsafe) public let undoInputRule: (EditorState, ((Transaction) -> Void)?) -> Bool = { state, dispatch in
    guard let s = inputRulesKey.getState(state), let transform = s.transform else { return false }
    if let dispatch {
        let tr = state.tr
        var i = transform.steps.count - 1
        while i >= 0 {
            tr.maybeStep(transform.steps[i].invert(transform.docs[i]))
            i -= 1
        }
        if !s.text.isEmpty {
            let marks = tr.doc.resolve(s.from).marks()
            try? tr.replaceWith(s.from, s.to, state.schema.text(s.text, marks))
        } else {
            try? tr.delete(s.from, s.to)
        }
        dispatch(tr)
    }
    return true
}

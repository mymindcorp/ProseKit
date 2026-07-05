import Foundation
import DocumentModel
import DocumentTransform
import EditorStateKit

/// An input rule maps a regular expression matching the text before the cursor
/// to a transformation. When the user types and the rule's pattern matches, the
/// handler runs.
public struct InputRule: Sendable {
    let regex: NSRegularExpression
    let handler: @Sendable (_ state: EditorState, _ match: [String?], _ start: Int, _ end: Int) -> Transaction?
    /// By default rules don't apply inside nodes whose spec is marked as
    /// `code`; set this to true to change that.
    let inCode: Bool
    /// When false, the rule won't fire when any part of the matched text
    /// carries a mark whose spec is marked as `code`. The default is true.
    let inCodeMark: Bool

    public init(_ pattern: String, inCode: Bool = false, inCodeMark: Bool = true, handler: @escaping @Sendable (_ state: EditorState, _ match: [String?], _ start: Int, _ end: Int) -> Transaction?) {
        // The pattern is an authored constant; a malformed one is a programmer
        // error (fail fast here rather than silently disabling the rule).
        self.regex = try! NSRegularExpression(pattern: pattern)
        self.handler = handler
        self.inCode = inCode
        self.inCodeMark = inCodeMark
    }
}

public final class InputRulesState: @unchecked Sendable {
    var transform: Transaction?
    var from: Int = 0
    var to: Int = 0
    var text: String = ""
}

public let inputRulesKey = PluginKey<InputRulesState>("inputRules")

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
                } else if tr.selectionSet || tr.docChanged {
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
    let lo = max(0, resolvedFrom.parentOffset - MAX_MATCH)
    let textBefore = resolvedFrom.parent.textBetween(lo, resolvedFrom.parentOffset, blockSeparator: nil, leafText: "\u{fffc}") + text
    for rule in rules {
        if !rule.inCodeMark, resolvedFrom.marks().contains(where: { $0.type.spec.code }) { continue }
        if resolvedFrom.parent.type.spec.code, !rule.inCode { continue }
        let ns = textBefore as NSString
        guard let m = rule.regex.firstMatch(in: textBefore, range: NSRange(location: 0, length: ns.length)) else { continue }
        var groups: [String?] = []
        for i in 0..<m.numberOfRanges {
            let r = m.range(at: i)
            groups.append(r.location == NSNotFound ? nil : ns.substring(with: r))
        }
        let matchLen = (groups[0] ?? "").count
        // A rule may not consume only part of the inserted text (the range
        // math below would invert).
        if matchLen < text.count { continue }
        let start = from - (matchLen - text.count)
        if !rule.inCodeMark {
            // The cursor check above misses code marks that end mid-match;
            // scan the whole matched range.
            var hasCodeMark = false
            state.doc.nodesBetween(start, from, { node, _, _, _ in
                if node.isInline, node.marks.contains(where: { $0.type.spec.code }) { hasCodeMark = true }
                return true
            })
            if hasCodeMark { continue }
        }
        if let tr = rule.handler(state, groups, start, to) {
            // Store the TYPED range (not the match start): undoInputRule inverts
            // the steps and then re-inserts the typed text at this range.
            dispatch?(tr.setMeta("applyInputRule", (from: from, to: to, text: text)))
            return true
        }
    }
    return false
}

// MARK: - Rule builders

/// Build a rule that wraps the matched block in a node of the given type.
public func wrappingInputRule(_ pattern: String, _ nodeType: NodeType, _ getAttrs: (@Sendable ([String?]) -> Attrs)? = nil, joinPredicate: (@Sendable ([String?], Node) -> Bool)? = nil) -> InputRule {
    InputRule(pattern) { state, match, start, end in
        let attrs = getAttrs?(match) ?? [:]
        let tr = state.tr
        _ = try? tr.delete(start, end)
        let resolvedStart = tr.doc.resolve(start)
        guard let range = resolvedStart.blockRange(),
              let wrapping = findWrappingForRange(range, nodeType, attrs) else { return nil }
        _ = try? tr.wrap(range, wrapping)
        if start - 1 >= 0, let before = tr.doc.resolve(start - 1).nodeBefore,
           before.type === nodeType, canJoin(tr.doc, start - 1),
           joinPredicate?(match, before) ?? true {
            _ = try? tr.join(start - 1)
        }
        return tr
    }
}

/// Build a rule that changes the textblock type of the matched block.
public func textblockTypeInputRule(_ pattern: String, _ nodeType: NodeType, _ getAttrs: (@Sendable ([String?]) -> Attrs)? = nil) -> InputRule {
    InputRule(pattern) { state, match, start, end in
        let resolvedStart = state.doc.resolve(start)
        let attrs = getAttrs?(match) ?? [:]
        if !resolvedStart.node(-1).canReplaceWith(resolvedStart.index(-1), resolvedStart.indexAfter(-1), nodeType) {
            return nil
        }
        let tr = state.tr
        _ = try? tr.delete(start, end)
        _ = try? tr.setBlockType(start, start, nodeType, attrs)
        return tr
    }
}

/// Build a rule that applies a mark to the text matched by its last capture
/// group, stripping the surrounding marker characters (Tiptap-style, e.g.
/// `**bold**` → bold "bold"). The captured group must be the inner text; any
/// leading whitespace consumed by the pattern is preserved.
public func markInputRule(_ pattern: String, _ markType: MarkType, _ getAttrs: (@Sendable ([String?]) -> Attrs)? = nil) -> InputRule {
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
        if textEnd < end { _ = try? tr.delete(textEnd, end) }
        if textStart > start + leadingSpaces { _ = try? tr.delete(start + leadingSpaces, textStart) }
        let markStart = start + leadingSpaces
        _ = try? tr.addMark(markStart, markStart + inner.count, markType.create(attrs))
        tr.removeStoredMark(markType)
        return tr
    }
}

/// Replaces `--` with an em-dash.
public let emDashRule = InputRule("--$", inCodeMark: false) { state, _, start, end in
    let t = state.tr
    _ = try? t.insertText("\u{2014}", start, end)
    return t
}

/// Replaces three dots with an ellipsis character.
public let ellipsisRule = InputRule("\\.\\.\\.$", inCodeMark: false) { state, _, start, end in
    let t = state.tr
    _ = try? t.insertText("\u{2026}", start, end)
    return t
}

// MARK: - Undo

/// Undo the input rule that was just applied, if the previous transaction was
/// an input rule.
public let undoInputRule: @Sendable (EditorState, ((Transaction) -> Void)?) -> Bool = { state, dispatch in
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
            _ = try? tr.replaceWith(s.from, s.to, state.schema.text(s.text, marks))
        } else {
            _ = try? tr.delete(s.from, s.to)
        }
        dispatch(tr)
    }
    return true
}

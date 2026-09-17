import Foundation
public import DocumentModel
import DocumentTransform
public import EditorStateKit

fileprivate struct InputRuleMatch: Sendable {
    let groups: [String?]
    /// Character offsets relative to the full match, preserving capture identity.
    let offsets: [Int?]
}

/// An input rule maps a regular expression matching the text before the cursor
/// to a transformation. When the user types and the rule's pattern matches, the
/// handler runs.
public struct InputRule: Sendable {
    let regex: NSRegularExpression
    fileprivate let handler: @Sendable (_ state: EditorState, _ match: InputRuleMatch, _ start: Int, _ end: Int, _ from: Int, _ text: String) -> Transaction?
    /// By default rules don't apply inside nodes whose spec is marked as
    /// `code`; set this to true to change that.
    let inCode: Bool
    /// When false, the rule won't fire when any part of the matched text
    /// carries a mark whose spec is marked as `code`. The default is true.
    let inCodeMark: Bool

    public init(_ pattern: String, inCode: Bool = false, inCodeMark: Bool = true, handler: @escaping @Sendable (_ state: EditorState, _ match: [String?], _ start: Int, _ end: Int) -> Transaction?) {
        self.init(pattern, inCode: inCode, inCodeMark: inCodeMark, textHandler: { state, match, start, end, _, _ in
            handler(state, match.groups, start, end)
        })
    }

    fileprivate init(_ pattern: String, inCode: Bool = false, inCodeMark: Bool = true, textHandler: @escaping @Sendable (EditorState, InputRuleMatch, Int, Int, Int, String) -> Transaction?) {
        // The pattern is an authored constant; a malformed one is a programmer
        // error (fail fast here rather than silently disabling the rule).
        self.regex = try! NSRegularExpression(pattern: pattern)
        self.handler = textHandler
        self.inCode = inCode
        self.inCodeMark = inCodeMark
    }
}

public final class InputRulesState: @unchecked Sendable {
    // EditorState snapshots (including speculative command chains) must not
    // mutate each other's undo record.
    let transform: Transaction?
    let from: Int
    let to: Int
    let text: String

    init(transform: Transaction? = nil, from: Int = 0, to: Int = 0, text: String = "") {
        self.transform = transform
        self.from = from
        self.to = to
        self.text = text
    }
}

public let inputRulesKey = PluginKey<InputRulesState>("inputRules")

private let MAX_MATCH = 500

/// Create the input-rules plugin.
public func inputRules(_ rules: [InputRule]) -> Plugin {
    return Plugin(
        key: inputRulesKey.key,
        stateField: PluginStateField(
            initialize: { _, _ in InputRulesState() },
            apply: { tr, value, _, _ in
                let s = value as! InputRulesState
                if let stored = tr.getMeta("applyInputRule") as? (from: Int, to: Int, text: String) {
                    return InputRulesState(transform: tr, from: stored.from, to: stored.to, text: stored.text)
                } else if tr.selectionSet || tr.docChanged {
                    return InputRulesState()
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
    let prefix = resolvedFrom.parent.textBetween(lo, resolvedFrom.parentOffset, blockSeparator: nil, leafText: "\u{fffc}")
    let textBefore = prefix + text
    // Regex offsets use UTF-16, but document positions count Characters. The
    // incoming text can also combine with the last Character in the prefix.
    var boundaries = [0: 0]
    var utf16Offset = 0
    for (offset, character) in textBefore.enumerated() {
        utf16Offset += String(character).utf16.count
        boundaries[utf16Offset] = offset + 1
    }
    for rule in rules {
        if !rule.inCodeMark, resolvedFrom.marks().contains(where: { $0.type.spec.code }) { continue }
        if resolvedFrom.parent.type.spec.code, !rule.inCode { continue }
        let ns = textBefore as NSString
        guard let m = rule.regex.firstMatch(in: textBefore, range: NSRange(location: 0, length: ns.length)) else { continue }
        guard NSMaxRange(m.range) == ns.length, m.range.location <= prefix.utf16.count,
              let matchOffset = boundaries[m.range.location],
              (0..<m.numberOfRanges).allSatisfy({
                  let range = m.range(at: $0)
                  return range.location == NSNotFound || (boundaries[range.location] != nil && boundaries[NSMaxRange(range)] != nil)
              }) else { continue }
        var groups: [String?] = []
        var offsets: [Int?] = []
        for i in 0..<m.numberOfRanges {
            let r = m.range(at: i)
            groups.append(r.location == NSNotFound ? nil : ns.substring(with: r))
            offsets.append(boundaries[r.location].map { $0 - matchOffset })
        }
        let start = from - prefix.count + matchOffset
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
        if let tr = rule.handler(state, InputRuleMatch(groups: groups, offsets: offsets), start, to, from, text) {
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
        guard resolvedStart.depth > 0 else { return nil }
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
///
/// Unlike `InputRule`, this defaults `inCodeMark` to **false**. A code mark
/// excludes every other mark, so inside a code span the rule would strip the
/// markers and then have its `addMark` silently dropped — `**b**` becomes a
/// bare "b" and the asterisks are gone. Code spans are literal, so the rule
/// must not fire there at all.
public func markInputRule(_ pattern: String, _ markType: MarkType, _ getAttrs: (@Sendable ([String?]) -> Attrs)? = nil, inCodeMark: Bool = false) -> InputRule {
    InputRule(pattern, inCodeMark: inCodeMark, textHandler: { state, match, start, end, from, text in
        guard state.doc.resolve(start).parent.type.allowsMarkType(markType) else { return nil }
        let fullMatch = match.groups[0] ?? ""
        // The inner text is the last participating capture group.
        guard let capture = match.groups.indices.dropFirst().last(where: { match.groups[$0] != nil }),
              let inner = match.groups[capture], !inner.isEmpty,
              let innerOffset = match.offsets[capture] else { return nil }
        let attrs = getAttrs?(match.groups) ?? [:]

        // Leading whitespace the pattern consumed (kept, not deleted).
        var leadingSpaces = 0
        for ch in fullMatch { if ch.isWhitespace { leadingSpaces += 1 } else { break } }
        let textStart = start + innerOffset
        let textEnd = textStart + inner.count

        let tr = state.tr
        // The event may contain part (or all) of the captured text. Insert it
        // before removing delimiters so existing marks on the inner text survive.
        var insertionFrom = from
        var insertionText = text
        if from > start, let previous = state.doc.resolve(from).nodeBefore?.text?.last,
           (String(previous) + text).count != 1 + text.count {
            // Replacing the whole combining character keeps the insertion step
            // invertible in a document whose positions count graphemes.
            insertionFrom -= 1
            insertionText = String(previous) + text
        }
        guard (try? tr.insertText(insertionText, insertionFrom, end)) != nil else { return nil }
        let insertedEnd = start + fullMatch.count
        // Delete trailing markers first so the earlier positions stay valid,
        // then the opening markers (after any leading whitespace).
        if textEnd < insertedEnd { _ = try? tr.delete(textEnd, insertedEnd) }
        if textStart > start + leadingSpaces { _ = try? tr.delete(start + leadingSpaces, textStart) }
        let markStart = start + leadingSpaces
        _ = try? tr.addMark(markStart, markStart + inner.count, markType.create(attrs))
        // A non-code mark may also exclude this formatting. An AddMarkStep
        // can succeed without applying its mark, so verify the result before
        // committing the delimiter deletions.
        guard tr.doc.rangeHasMark(markStart, markStart + inner.count, markType) else { return nil }
        tr.removeStoredMark(markType)
        return tr
    })
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

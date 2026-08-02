import Foundation
public import DocumentModel

// When pasting from sources whose HTML flattens checklists to bullet lists (Apple
// Notes), the checked state is only available out-of-band: ordered checklist lines
// from Apple Notes' private proto, or the set of checked line texts recovered from
// RTF list markers. This reclassifies matching bullet lists into task lists.

/// Match key for a list item: the text of its first paragraph only (nested
/// sub-lists are separate lines in the source, so they must not contribute),
/// normalized so both sides of the comparison agree: NBSP and object-replacement
/// characters (the NSAttributedString → HTML round-trip introduces both) are
/// dropped, as is a literal RTF list marker ("☑\tmilk") — some RTF imports keep
/// the marker in the text, and Cocoa's HTML writer passes it through, so BOTH
/// comparands need the same strip.
private func normalizedLine(_ s: String) -> String {
    var t = Substring(s)
    if let tab = t.firstIndex(of: "\t"),
       t[..<tab].rangeOfCharacter(from: .alphanumerics) == nil {
        t = t[t.index(after: tab)...]
    }
    return t.replacingOccurrences(of: "\u{00A0}", with: " ")
        .replacingOccurrences(of: "\u{FFFC}", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func itemLineText(_ item: Node) -> String {
    for i in 0..<item.childCount where item.child(i).type.name == "paragraph" {
        return normalizedLine(item.child(i).textContent)
    }
    return normalizedLine(item.textContent)
}

/// Rebuild `content`, converting bullet lists that came from checklists into task
/// lists.
///
/// - `checklistLines`: every checklist line in source order with its checked state
///   (Apple Notes' proto). When present, a bullet list converts only if ALL its
///   non-empty items are checklist lines — an unrelated bullet list that merely
///   shares one line text survives, while a blank row (which the proto drops)
///   doesn't block conversion — and duplicate texts resolve positionally: per-text
///   FIFO queues are consumed in document order, which matches note order.
/// - `checkedTexts`: texts of checked lines only (the RTF path, which cannot see
///   unchecked items). Without `checklistLines`, any matching item converts a list.
/// No-op if the schema lacks task nodes or there are no checklist lines.
public func applyChecklistMarkers(_ content: Fragment, checkedTexts: Set<String>,
                                  checklistLines: [(text: String, checked: Bool)] = [],
                                  schema: Schema) -> Fragment {
    let checked = Set(checkedTexts.map(normalizedLine))
    var queues: [String: [Bool]] = [:]
    for line in checklistLines { queues[normalizedLine(line.text), default: []].append(line.checked) }
    let lineTexts = Set(queues.keys)
    guard !(checked.isEmpty && lineTexts.isEmpty),
          let taskListType = schema.nodes["taskList"], let taskItemType = schema.nodes["taskItem"]
    else { return content }

    func matches(_ text: String) -> Bool { lineTexts.contains(text) || checked.contains(text) }

    func recurseChildren(_ node: Node) -> Node {
        guard node.childCount > 0 else { return node }
        let kids = (0..<node.childCount).map { mapNode(node.child($0)) }
        return node.copy(content: Fragment.from(kids))
    }

    func mapNode(_ node: Node) -> Node {
        guard node.type.name == "bulletList", node.childCount > 0 else { return recurseChildren(node) }
        let items = (0..<node.childCount).map { node.child($0) }
        let texts = items.map(itemLineText)
        let isChecklist = lineTexts.isEmpty
            ? texts.contains(where: checked.contains)
            : texts.contains(where: matches) && texts.allSatisfy { $0.isEmpty || matches($0) }
        guard isChecklist else { return recurseChildren(node) }

        // Convert each item BEFORE recursing into it, so queues are consumed in
        // document order — which matches note order even across nesting levels.
        // If any item can't convert, restore the queues and keep the list intact
        // rather than dropping a line or leaving states shifted.
        let queuesBefore = queues
        var taskItems: [Node] = []
        for (item, text) in zip(items, texts) {
            let isChecked: Bool
            if var queue = queues[text], !queue.isEmpty {
                isChecked = queue.removeFirst()
                queues[text] = queue
            } else {
                isChecked = checked.contains(text)
            }
            let kids = (0..<item.childCount).map { mapNode(item.child($0)) }
            guard let ti = taskItemType.createAndFill(["checked": .bool(isChecked)], content: Fragment.from(kids))
            else {
                queues = queuesBefore
                return recurseChildren(node)
            }
            taskItems.append(ti)
        }
        if let list = taskListType.createAndFill([:], content: Fragment.from(taskItems)) { return list }
        queues = queuesBefore
        return recurseChildren(node)
    }

    return Fragment.from((0..<content.childCount).map { mapNode(content.child($0)) })
}

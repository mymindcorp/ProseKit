import DocumentModel

// When pasting from sources whose HTML flattens checklists to bullet lists (Apple
// Notes), the checked state is only available out-of-band: ordered checklist lines
// from Apple Notes' private proto, or the set of checked line texts recovered from
// RTF list markers. This reclassifies matching bullet lists into task lists.

/// Match key for a list item: the text of its first paragraph only (nested
/// sub-lists are separate lines in the source, so they must not contribute), with
/// NBSP and object-replacement characters normalized away (the NSAttributedString
/// → HTML round-trip introduces both).
private func normalizedLine(_ s: String) -> String {
    s.replacingOccurrences(of: "\u{00A0}", with: " ")
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
///   items are checklist lines — an unrelated bullet list that merely shares one
///   line text survives — and duplicate texts resolve positionally (per-text FIFO).
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

    func mapNode(_ node: Node) -> Node {
        // Recurse first so nested lists are handled too.
        var n = node
        if node.childCount > 0 {
            let kids = (0..<node.childCount).map { mapNode(node.child($0)) }
            n = node.copy(content: Fragment.from(kids))
        }
        guard n.type.name == "bulletList", n.childCount > 0 else { return n }
        let items = (0..<n.childCount).map { n.child($0) }
        let texts = items.map(itemLineText)
        let isChecklist = lineTexts.isEmpty
            ? texts.contains(where: checked.contains)
            : texts.allSatisfy { lineTexts.contains($0) || checked.contains($0) }
        guard isChecklist else { return n }
        var taskItems: [Node] = []
        for (item, text) in zip(items, texts) {
            let isChecked: Bool
            if var queue = queues[text], !queue.isEmpty {
                isChecked = queue.removeFirst()
                queues[text] = queue
            } else {
                isChecked = checked.contains(text)
            }
            // An unconvertible item aborts the whole list rather than dropping a line.
            guard let ti = taskItemType.createAndFill(["checked": .bool(isChecked)], content: item.content)
            else { return n }
            taskItems.append(ti)
        }
        return taskListType.createAndFill([:], content: Fragment.from(taskItems)) ?? n
    }

    return Fragment.from((0..<content.childCount).map { mapNode(content.child($0)) })
}

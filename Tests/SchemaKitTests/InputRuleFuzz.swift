import Foundation
import DocumentModel
import DocumentTransform
import EditorHistory
import EditorStateKit
import SchemaKit
import TestDocGen
import TestHarness

// A fuzzer for input rules — the Markdown shortcuts that fire as you type.
//
// `# ` at the start of a line makes a heading, `- ` a list, `**bold** ` a mark.
// Each rule matches text *behind the caret*, so what it does depends on what is
// already there: the same keystroke in a code block, a caption, a table header
// or halfway through a word has to either fire correctly or stay out of the
// way. And a rule's transaction is one undo step, so undoing everything typed
// has to give the document back.
//
// Opt-in for the same reason as the selection sweeps; see `SelectionFuzz`.
func registerInputRuleFuzzTests() {
    guard ProcessInfo.processInfo.environment["PROSEKIT_FUZZ"] != nil else { return }

    test("input rule fuzz: shortcuts typed anywhere leave a valid, undoable document") {
        var totalFired = 0
        for seed in 1 ... fuzzOpSeeds {
            var rng = SelRNG(seed &* 47 &+ 3)
            let editor = try Editor(extensions: fuzzKit())
            // Start from a generated document, so the shortcuts land in every
            // kind of block the schema has rather than in an empty paragraph.
            var gen = DocGen(schema: editor.schema, seed: seed)
            editor.setContent(gen.randomDoc(depth: 3, budget: 40))
            let original = editor.doc
            var log: [String] = []
            var fired = 0

            for _ in 0 ..< fuzzInputRuleOps {
                // Half the time a block shortcut at the start of a textblock —
                // the only place `# ` or `- ` can fire — and otherwise anything
                // anywhere, which is where a rule has to stay out of the way.
                let size = editor.doc.content.size
                let trigger: String
                let target: Selection
                if Bool.random(using: &rng), let start = textblockStarts(editor.doc).randomElement(using: &rng) {
                    trigger = blockTriggers.randomElement(using: &rng)!
                    target = Selection.near(editor.doc.resolve(start), 1)
                } else {
                    trigger = inputRuleTriggers.randomElement(using: &rng)!
                    target = Selection.near(editor.doc.resolve(Int.random(in: 0 ... size, using: &rng)), 1)
                }
                editor.dispatch(editor.state.tr.setSelection(target))
                log.append("\(trigger.debugDescription) at \(target.head)")
                for char in trigger {
                    let head = editor.state.selection.head
                    let text = String(char)
                    // Exactly what the view does: offer the character to the
                    // rules first, and type it plainly when none took it.
                    if textInput(editor, at: head, text) {
                        fired += 1
                    } else {
                        let tr = editor.state.tr
                        guard (try? tr.insertText(text)) != nil else { continue }
                        editor.dispatch(tr)
                    }
                    let ctx = "seed \(seed) after \(log.suffix(3).joined(separator: " | ")) (typing \(text.debugDescription))"
                    var invalid: (any Error)?
                    do { try editor.doc.check() } catch { invalid = error }
                    try expect(invalid == nil, "an input rule produced an invalid document — \(ctx): \(invalid.map { "\($0)" } ?? "")")
                    try checkSelectionValid(editor.state.selection, in: editor.doc, ctx)
                }
                editor.dispatch(closeHistory(editor.state.tr))
            }

            totalFired += fired

            var undos = 0
            while undoDepth(editor.state) > 0 {
                undos += 1
                try expect(undos <= fuzzInputRuleOps * 12, "undo isn't terminating at seed \(seed)")
                try expect(key(editor, "Mod-z"), "undo declined at seed \(seed)")
            }
            try expect(editor.doc == original,
                       "undoing everything typed didn't restore the document at seed \(seed) — \(log.joined(separator: " | "))")
        }
        // A sweep in which rules never fire asserts nothing about rules. Not
        // per seed — a small generated document whose only textblock is a
        // code block gives them nowhere to fire — but across the run they must
        // have fired at least once per session on average.
        try expect(totalFired >= Int(fuzzOpSeeds),
                   "input rules fired only \(totalFired) times across \(fuzzOpSeeds) sessions")
    }
}

let fuzzInputRuleOps = 20

/// The positions a block shortcut can fire at: the first position inside each
/// textblock.
private func textblockStarts(_ doc: Node) -> [Int] {
    var out: [Int] = []
    doc.descendants { node, pos, _, _ in
        if node.isTextblock { out.append(pos + 1) }
        return true
    }
    return out
}

/// The shortcuts that only fire at the start of a block.
private let blockTriggers = ["# ", "## ", "### ", "- ", "* ", "+ ", "1. ", "12. ", "> ", "[ ] ", "[x] ", "```"]

/// The shortcuts the kit registers, each with the space or closing delimiter
/// that fires it, plus a few near misses that must not.
private let inputRuleTriggers = [
    "# ", "## ", "### ", "####### ", "- ", "* ", "+ ", "1. ", "12. ", "> ", "[ ] ", "[x] ", "[] ", "```",
    "**bold** ", "*it* ", "__b__ ", "_i_ ", "`code` ", "~~s~~ ", "==h== ",
    "**", "* ", "**a", "a**b** ", "1.", "#", "- - ", "> > ", "```x",
    "hello ", "🙂 ", "漢字",
]

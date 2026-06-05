# Editor Behaviors — Gap Analysis & Plan

> **Progress:** ✅ smart typography · ✅ backspace/forward/word/line delete + caret nav (Option/Cmd/Home/End, Shift-extend) · ✅ placeholder · ✅ scroll-to-caret · ✅ triple-click paragraph + shift-click extend · ✅ paste-as-plain + Markdown paste · ✅ decorations layer + find/replace · ✅ table Tab-navigation · ✅ UTF-16 layout mapping · ✅ Dynamic Type · ✅ basic VoiceOver value · ✅ real inline image rendering · ✅ **spell-check underlines** · ✅ **RTL/bidi base direction + right-alignment** · ✅ **incremental layout v1** (doc-level cache; no relayout on caret/selection). **Remaining (big):** UITextInput/IME (#1) + full VoiceOver text-nav (#13) · CellSelection (#11, multi-cell) · block-level incremental layout (#22 further).


A survey of standard text-editor behaviors against the current implementation, with a prioritized plan for what's missing. "Engine" = shared headless Swift (done, 108 tests). "Renderer" = `EditorUIKit` (`EditorTextView` + `DocumentLayout`).

## Status legend
✅ done · 🟡 partial · ❌ missing

## What works today
- ✅ Character insertion; Enter→split; Shift-Enter→hard break
- ✅ Backspace / forward-delete (char), Option→word, Cmd→line; block join/lift at edges
- ✅ Caret place (tap), drag-select (long-press), double-click word-select, Shift+arrow extend, word/line/doc movement (Option/Cmd/Home/End)
- ✅ Undo / redo (Mod-Z / Mod-Y / Shift-Mod-Z) with time-grouping
- ✅ Copy / cut / paste / select-all (HTML + plain text), select-all highlight
- ✅ Marks (bold/italic/code/strike/link), lists (bullet/ordered/task), blockquote, headings, hr, tables (structural), wiki-links, images (placeholder)
- ✅ Input rules (`# `, `- `, `1. `, `> `, `**b**`, `[[wiki]]`), keymap shortcuts
- ✅ Caret blink, selection highlight

---

## Tier 1 — Required for a credible editor (do next)

1. **IME / marked text (`UITextInput`).** ❌ Today we only conform to `UIKeyInput`, so there is **no composition** for CJK, accent/dead keys, dictation, or autocorrect, and **none of the native iOS selection UI** (loupe/magnifier, selection handles, the edit menu positioning). This is the single biggest gap. Plan: implement `UITextInput` + `UITextInputTokenizer`, backed by a position/range model that maps `UITextPosition`↔document positions. This also unlocks autocorrect/predictive/dictation for free.
   - Engineering-guide notes: new `final class` document-position/range adapters; `@MainActor`; positions are value types; translate at the view edge.

2. **Scroll-to-caret (reveal on edit/selection).** 🟡 Transactions set a `scrollIntoView` flag but the view never scrolls its enclosing scroll view to reveal the caret. Plan: after dispatch, if `tr.scrolledIntoView`, compute `caretRect` and ask the host scroll view to reveal it (delegate/closure on `EditorTextView`).

3. **Placeholder text.** ❌ Empty document shows nothing. Plan: render a themed placeholder string when the doc is a single empty textblock.

4. **UTF-16 vs grapheme position model.** 🟡 Positions use `Character` count; CoreText/`UITextInput` use UTF-16. Mismatch breaks emoji/combining marks. Plan: standardize the model on UTF-16 code-unit offsets (as ProseMirror does) — touches `Node.nodeSize`/text handling and the layout segment map. Bundle with #1 since `UITextInput` forces the issue.

## Tier 2 — Expected polish

5. **Triple-click / triple-tap → select paragraph (line).** ❌ Add to the tap gesture (`numberOfTapsRequired == 3`).
6. **Shift+click to extend selection.** ❌ Anchor at current selection, head at tap point.
7. **Paste-and-match-style (Cmd-Shift-V) + Markdown paste.** 🟡 We paste HTML/plain; add a plain-only path and Markdown detection (we already have `MarkdownParser`).
8. **Drag & drop** of text and images (in and out). ❌ `UIDragInteraction`/`UIDropInteraction` → slices.
9. **Smart typography** (smart quotes, em-dash, ellipsis). 🟡 `emDashRule`/`ellipsisRule` exist in `EditorInputRules` but aren't in `starterKit()`; wire them + a smart-quotes rule.
10. **Real image rendering.** 🟡 Images draw a placeholder box. Plan: async image load + intrinsic sizing + draw into the layout; resize handles later.
11. **Tab navigation inside tables + cell selection.** 🟡 Structural table commands exist, but Tab doesn't move between cells and there's no multi-cell (rectangular) selection. Plan: `CellSelection` type + Tab/Shift-Tab cell movement + arrow-into-cell.
12. **Find / replace.** ❌ Query model + match decorations + replace transaction.

## Tier 3 — Accessibility & correctness (must-have before shipping)

13. **VoiceOver / accessibility.** ❌ No accessibility tree, rotor, or trait exposure. Plan: expose the document as accessible text; map selection/caret to accessibility APIs.
14. **Dynamic Type.** 🟡 `TextTheme` uses fixed sizes; honor `UIContentSizeCategory`.
15. **RTL / bidirectional text.** ❌ CoreText handles runs, but caret/hit-testing/selection rects assume LTR. Plan: per-line writing-direction handling.
16. **Spell-check underlines.** ❌ Surface `UITextChecker` results as decorations.

## Tier 4 — Rich / collaborative (later)

17. **Decorations layer.** ❌ `Decoration`/`DecorationSet` was deferred from M2/M7. Needed for find highlights, spellcheck squiggles, collab cursors, inline widgets. Plan: build the shared decoration model + render pass.
18. **Collaboration cursors / presence.** 🟡 Collab steps converge (engine done), but no remote selection/caret decorations. Depends on #17.
19. **Code-block niceties.** ❌ Syntax highlighting; Tab inserts indentation; language attribute.
20. **Link & image editing UI.** ❌ App-level affordances (link popover, alt text). Mostly host responsibility.
21. **Native edit menu actions** beyond cut/copy/paste (Look Up, Share, formatting). 🟡 Add via `UIMenu`/`editMenu` once `UITextInput` lands.

## Performance (cross-cutting)

22. **Incremental / viewport layout.** 🟡 `DocumentLayout` relayouts the whole document on every change — fine for small docs, O(n) per keystroke for large ones. Plan: cache per-block layout keyed by node identity; relayout only changed blocks; render only the visible viewport.

---

## Suggested order
Tier 1 (#1 IME+UTF-16, #2 scroll-to-caret, #3 placeholder) → Tier 2 polish (#5–#11) → #17 decorations (unlocks #12 find, #18 collab cursors, #16 spellcheck) → Tier 3 accessibility → #22 performance when docs get large.

Each item should follow the Swift Engineering Guide's Mandatory First Actions (type choice, concurrency model, typed errors, test placement) and factor pure logic (position math, matching, parsing) out of the UIKit layer so it stays headless-testable under `TestHarness`.

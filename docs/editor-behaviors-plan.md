# Editor Behaviors — what shipped, and what's left

This started as a gap analysis of standard text-editor behaviors against the
renderer, with a tiered plan. Everything in that plan has shipped except one
item, so it is now a record of what the editor does rather than a to-do list.
"Engine" = the shared headless Swift modules; "renderer" = `EditorUIKit`
(`EditorTextView` + `DocumentView` + `DocumentLayout`).

## Still open

**Full VoiceOver text navigation.** `EditorTextView` exposes itself as a single
accessibility element — label, the document's plain text as its value, and the
`.updatesFrequently` trait (`EditorTextView.swift`, near `accessibilityValue`).
There is no per-element accessibility tree, no rotor, and no mapping of the
caret/selection onto the accessibility text APIs, so VoiceOver can read the
document but not navigate it by word, line, or heading.

The `UITextInput` conformance that this was once blocked on is done, so the
remaining work is exposing the text APIs (`UIAccessibilityReadingContent`, the
custom rotors) on top of the position model that conformance already provides.

## What shipped

**Input and selection.** `UITextInput` + `UITextInputTokenizer` conformance
(`EditorTextView+UITextInput.swift`, `DocumentTokenizer.swift`), so composition
for CJK/dead keys, dictation, autocorrect, the loupe, selection handles, and the
native edit menu all come from the system. Positions are UTF-16 code-unit
offsets end to end. Tap to place, drag to select, double-tap word, triple-tap
paragraph, shift-click extend, and word/line/document movement
(Option/Cmd/Home/End, with shift-extend).

**Editing.** Character insertion, Enter/Shift-Enter, backspace and
forward-delete by character/word/line with block join and lift at edges, undo
and redo with time-grouping, copy/cut/paste/select-all, paste-and-match-style
and Markdown paste, drag & drop of text and images in and out
(`UIDragInteraction` / `UIDropInteraction`), smart typography via
`TypographyExtension` in `starterKit()`.

**Structure.** Marks (bold, italic, underline, strike, code, link, highlight,
sub/superscript, text and background colour), lists (bullet, ordered, task),
blockquote, headings, rules, tables, details, wiki links, mentions, math,
footnotes, images. Input rules and keymap shortcuts for all of it; Tab and
Shift-Tab indent inside code blocks and sink/lift list items.

**Tables.** Structural commands plus `CellSelection` (`SchemaKit/CellSelection.swift`)
for rectangular multi-cell selection, Tab/Shift-Tab cell navigation
(`TableInput.swift`), cell copy/paste, and column resizing.

**Decorations and what they unlocked.** `EditorStateKit/Decoration.swift` +
`DecorationSet`, and on top of it find/replace (`Search.swift`,
`SearchExtension`, `FindBarView`), spell-check underlines from `UITextChecker`
(`SpellCheck.swift`), and collaboration cursors (`SchemaKit/CollabCursor.swift`).

**Presentation.** Placeholder text, scroll-to-caret (`revealRect`, driven by a
transaction's `scrollIntoView` flag), Dynamic Type throughout `DocumentTheme`,
RTL/bidi base direction with right-alignment (`DocumentLayout`), real inline
image rendering with resize handles, code-block syntax highlighting and language
labels (`EditorSyntax`), math typesetting (`EditorMath`), a link popover
(`LinkPopupView`), and host-supplied edit-menu items (`editMenuItems`).

**Performance.** `DocumentLayout` caches per-block layout keyed by node identity
(`TextBlockLayoutCache`) and, past `lazyThreshold`, typesets only the children
near the viewport and estimates the rest — so opening a large document does not
lay out the whole thing. `documentHeight` is an estimate until the reader has
scrolled through; `documentHeightIsExact` and `measuredDocumentHeight()` say so
and force the issue. `DocumentView` virtualizes the same way.

## Conventions this work followed

Pure logic — position math, matching, parsing — stays out of the UIKit layer so
it can be tested headlessly under `TestHarness`; the renderer's own behavior is
covered by `EditorUIKitTests` under `xcodebuild`.

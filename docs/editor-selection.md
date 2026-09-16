# Caret and selection interactions

Mouse and trackpad input have one selection owner, `MouseSelectionRecognizer`.
It recognizes a primary-button press immediately, before native caret or content
drag recognizers can claim a slow click-drag. There is no pan threshold and no
preliminary click required.

- Click places the caret at the press location; dragging extends from that position.
- Shift-click and Shift-drag extend from the existing selection anchor.
- Double-click selects a word; dragging extends by whole words.
- Triple-click selects a paragraph; dragging extends by whole paragraphs.
- Release ends the gesture; cancellation clears its temporary selection session.

Touch and Pencil input remain with `UITextInteraction`, including caret placement,
long-press selection, the magnifier, and selection handles. Secondary-button and
Command/Control/Option clicks also remain native. Images, resize handles,
checkboxes, disclosure controls, math activation, and the trailing paragraph tap
keep their own interactions. Hosts can opt into selected-text drag and drop with
`textDraggingEnabled`; doing so returns pointer selection to UIKit.

Both input paths use `applyInputSelection(anchor:head:)` to construct document
selections, including gap cursors, leaf node selections, and table cell selections.
Pointer input supplies its anchor explicitly. Native `UITextRange` updates infer
the moving end from the previous selection because their endpoints are ordered.
The document selection remains the source for caret geometry and highlighting.

Regression tests drive press, move, release, cancellation, focus changes, and
native input independently. In particular, a pointer must be in `.began` before
any movement: checking only a manually assigned `.began` state cannot detect a
recognizer that never claims the real press.

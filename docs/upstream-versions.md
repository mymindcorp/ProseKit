# Upstream version tracking

This codebase is a Swift port of [ProseMirror](https://github.com/ProseMirror)
(with Tiptap's extension/naming layer on top). Each upstream package versions
independently, so this file records **how far up each module has been reviewed**
— the release whose CHANGELOG we have read and reconciled against the Swift code.
Use it to find what's new when re-auditing: read each package's CHANGELOG from the
"reviewed through" version onward and port any bug fixes that apply.

> "Reviewed through" means the changelog was read and every **bug fix** up to that
> version was either confirmed already-ported or ported. It does **not** mean
> every new *feature* was ported — features are added on demand.

## Status

| Swift module | Upstream package | Reviewed through | Date | Notes |
| --- | --- | --- | --- | --- |
| `DocumentModel` | `prosemirror-model` | **1.25.4** | 2025-10-21 | Slice invalid-`ReplaceAroundStep` guard (1.25.3) confirmed present. DOM-parser fixes (1.24.1/1.25.1/1.25.4) live in our hand-written `HTMLParser`, not a 1:1 port. |
| `DocumentTransform` | `prosemirror-transform` | **1.12.0** | 2026-03-30 | `ReplaceStep.map` structure-flag fix (1.10.4) **ported** this pass. `liftTarget` split-constraint (1.10.5), `Mapping.appendMap` aliasing (1.10.3, free via Swift value semantics), and `deleteRange` start-to-start (1.12.0) confirmed present. See "Known gaps". |
| `EditorStateKit` | `prosemirror-state` | **1.4.4** | 2025-10-23 | `insertText` selection-mapping fix (1.4.4) confirmed present. |
| `EditorCommands` | `prosemirror-commands` | **1.7.1** | 2025-04-13 | `splitBlock` no-crash regression (1.7.1) and `joinBackward`/`splitBlock` fixes (1.6.x) confirmed present. |
| `SchemaKit` (tables) | `prosemirror-tables` | **1.8.5** | 2025-12-24 | `fixTables` zero-sized removal (1.6.4), colwidth validation (1.7.1), and keep-cell-type-on-row-move (1.8.1) confirmed present. Newer row/col *move* helpers track the same source. |
| `EditorHistory` | `prosemirror-history` | **1.5.0** | 2026-07-04 | Mark-step adjacency (1.4.1) and closed-event append guard (1.1.3) confirmed present. Composition grouping (1.3.1) and 1.5.0's beforeinput check N/A (no browser IME/DOM); `isHistoryTransaction` (1.5.0) is a feature, add on demand. |
| `EditorKeymap` | `prosemirror-keymap` | _not yet pinned_ | — | Upstream fixes are DOM `KeyboardEvent`-specific; the UIKit key handling is hand-written. Audit deferred. |
| `EditorInputRules` | `prosemirror-inputrules` | **1.5.1** | 2026-07-04 | Multi-char-input guard + `inCodeMark` code-mark suppression (1.5.0/1.5.1) **ported** this pass, with `MarkSpec.code` (model 1.25.0) added to support them; undo-without-text guard (1.1.3) confirmed present. `inCode: "only"` and the `undoable` option are unported features. |
| `EditorCollab` | `prosemirror-collab` | **1.3.1** | 2026-07-04 | `mapSelectionBackward` fixes (1.1.1/1.1.2) confirmed present; upstream's clearing of the selection-updated flag after mapping **ported** this pass (`Transaction.clearSelectionSet`). See "Known gaps" re remote-step application. |
| `EditorChangeset` | `prosemirror-changeset` | **2.3.1** | 2026-07-04 | Typed close tokens (2.3.1) and multi-range steps (2.0.4) confirmed present, regression tests already ported. `Change` JSON serialization (2.4.0) is a feature, add on demand. |
| `SchemaKit` (lists) | `prosemirror-schema-list` | **1.5.1** | 2026-07-04 | `liftListItem` type-guarded join (1.5.1), adjacent-sublists join (1.2.2), and `splitListItem` sublist fix (1.1.5) confirmed present. See "Known gaps" re attr validation (1.4.1). |
| `EditorSerialization` | `prosemirror-markdown` + custom HTML | n/a | — | HTML/Markdown serializers are hand-written for this editor's shapes, not direct ports; no upstream version to track. |
| `EditorMath` | none (TeX/KaTeX box model) | n/a | 2026-07-27 | Not a ProseMirror port. The typesetter implements the algorithms and font parameters from *The TeXbook* Appendix G — the same ones KaTeX implements — written from the published specification, not translated from KaTeX's source. The `SchemaKit` extension follows Tiptap's *documented* Mathematics API (node names, `latex` attribute, `data-type` HTML, command set); see the note in `MathematicsExtension.swift`. |

## Known gaps / intentional deviations

- **`removeNodeMark` with a `MarkType`** (prosemirror-transform 1.10.4): upstream
  added an overload so passing a mark *type* removes all marks of that type from a
  node (aligning it with `removeMark`). The Swift `removeNodeMark` only accepts a
  concrete `Mark`. Low impact; add the overload if a caller needs it.
- **Attribute `validate`** (prosemirror-model 1.21 / schema-list 1.4.1): upstream
  attribute specs can declare a type check that rejects wrong-typed attrs when
  parsing untrusted JSON. Swift `AttributeSpec` has no validation — `Node.fromJSON`
  accepts e.g. a string `order` on an ordered list. Lower severity here because
  `AttributeValue` is a closed enum and consumers read defensively
  (`intValue ?? 1`), but an invalid doc round-trips without error.
- **Details `persist` option** (Tiptap `Details`): Tiptap keeps a section's
  open/closed state in its DOM node view unless `persist: true` adds an `open`
  attribute. `SchemaKit`'s `DetailsExtension` always stores `open` in the
  document — there is no node view here to hold view-only state, and the
  CoreText renderer reads the attribute to decide whether to lay out the body.
- **Remote steps via `maybeStep`** (prosemirror-collab): upstream's
  `receiveTransaction` uses `tr.step` and throws when an authority-confirmed step
  fails to apply; the Swift port uses `maybeStep`, silently skipping it. A failure
  there means protocol corruption, so surfacing it (throwing variant) may be
  worth adding when a transport needs it.

## Known performance gaps

Places where the port matches upstream's algorithm and inherits a cost that
matters more here than it does in JavaScript. These are *not* deviations —
nothing to port — but they are worth recording so the next person measuring
doesn't have to rediscover them.

- **`Transform.addMark` is quadratic in the blocks it covers.** Marking a range
  emits one `AddMarkStep` per block, because a run is extended only when the next
  one begins exactly where the last ended and the two tokens between one block
  and the next always break that. Every step rebuilds the document's children, so
  N blocks cost N rebuilds of N children. Measured in release:

  | blocks | time | steps |
  |--------|------|-------|
  | 500    | 18ms | 500   |
  | 1,000  | 319ms | 1,000 |
  | 2,000  | 1,377ms | 2,000 |
  | 4,000  | 4,762ms | 4,000 |

  Select-all-then-bold on a long document freezes for seconds. Upstream has the
  same shape; the constant is worse here because copying an array of `Node`
  *structs* retains five reference-counted fields per element where JavaScript
  copies pointers.

  **A candidate fix, tried and then backed out** (not for correctness — it
  passed — but to keep the step stream upstream's for now): extend a run over
  anything that isn't inline. `AddMarkStep` consults the schema for every node it
  covers, so it leaves block structure alone and the resulting document is
  identical. That turns the 4,000-block case into **one step and 2ms**.

  Two things anyone attempting it needs to know.

  *A run may not reach over inline content the range leaves alone.* The step
  inverts to a `RemoveMarkStep` across its whole range, so a run widened over
  text that already carried the mark strips it on undo and the document does not
  come back. This is invisible to a forward comparison: merging unconditionally
  produced a byte-identical document for every shape tried — code blocks that
  forbid marks, nested quotes and lists, partial ranges — and was still wrong.
  Only inverting the steps and comparing the undone document exposes it. Runs
  have to break at inline content that isn't being marked (already-marked text,
  or text whose parent forbids the mark), which is where upstream's adjacency
  rule breaks them anyway, and resume after.

  *The removal steps that accompany an excluding mark must keep strict
  adjacency.* `RemoveMarkStep` takes a mark off everything in its range without
  consulting the schema, so widening one strips a mark that content is entitled
  to keep.

  **What it would and wouldn't buy.** A document with nothing pre-marked goes to
  a single step. A document already marked in places gains much less, because
  that is exactly where runs must stop: with every third block already bold,
  2,000 blocks go from 1,333 steps to 667 and the wall time does not move. It
  stays quadratic in that shape. Removing that too would need a step type
  recording which sub-ranges actually changed — a serialization and collab
  compatibility question, not a tuning one.

  **The cost of taking it** is that the step stream stops matching upstream's:
  fewer, wider steps for the same edit. That is narrower than it sounds — mark
  steps carry an empty `StepMap`, so no position mapping changes, and history
  groups by transaction rather than by step, so undo granularity is unchanged.

  `removeMark` does not have this problem: it counts inline nodes rather than
  comparing positions, which already merges its runs across block boundaries by
  the same rule.

## How to re-audit a module

1. Read the upstream CHANGELOG from the "reviewed through" version onward:
   ```sh
   curl -s https://raw.githubusercontent.com/ProseMirror/prosemirror-transform/master/CHANGELOG.md
   ```
   (Plain `curl` of `raw.githubusercontent.com` returns verbatim source;
   summarizer tools may refuse it.)
2. For each **bug fix** entry, find the corresponding Swift function and decide:
   already-ported, genuine gap, or N/A (e.g. a DOM/browser-only fix). Swift value
   semantics make some aliasing bugs not-applicable for free.
3. Port real gaps with a regression test; note free/duplicate confirmations here.
4. Bump the "reviewed through" version + date in the table above.

## Ported-fix log

- **2026-06-21** — `prosemirror-transform` 1.10.4: `ReplaceStep.map` now preserves
  the `structure` flag (`Sources/DocumentTransform/ReplaceStep.swift`); regression
  test in `Tests/DocumentTransformTests/PMStep.swift`.
- **2026-07-04** — `prosemirror-inputrules` 1.5.0/1.5.1: rules are skipped when the
  inserted text is longer than the match (the old math inverted the range), and
  `inCodeMark: false` rules (em-dash, ellipsis, smart quotes) no longer fire when
  the cursor or any part of the matched range carries a `code` mark. `InputRule.inCode`
  is now honored (per-rule code-block opt-in, upstream 1.4.0 semantics), the
  undoable record clears on selection-only transactions, and `MarkSpec` gained the
  `code` flag (model 1.25.0). `Sources/EditorInputRules/InputRules.swift`;
  regression tests in `Tests/EditorCommandsTests/PMInputRules.swift`.
- **2026-07-04** — `prosemirror-collab`: after `mapSelectionBackward` maps the
  selection, the transaction's selection-updated flag is cleared so the mapped
  selection doesn't count as an explicit update (upstream's `tr.updated &= ~UPDATED_SEL`);
  `Transaction.clearSelectionSet()` added to `EditorStateKit`.
  `Sources/EditorCollab/Collab.swift`; regression test in `Tests/EditorCollabTests/main.swift`.

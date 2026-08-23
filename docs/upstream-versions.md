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
| `DocumentModel` | `prosemirror-model` | **1.25.11** | 2026-08-22 | `Fragment.fromJSON` adjacent-text-node join **ported** this pass. The Slice invalid-`ReplaceAroundStep` guard (1.25.3, narrowed in 1.25.5) was **not** present — an earlier pass recorded it as confirmed in error — and is **ported** now. The surrogate-pair fix in `findDiffStart`/`End` (1.25.8) is N/A — positions here are grapheme clusters. `ReplaceError` vs `checkContent` (1.25.9) is free: `StepResult.fromReplace` catches any error. `DOMOutputSpec` typing (1.25.5/1.25.7/1.25.10) is TypeScript-only, and `body` in `blockTags` (1.25.11) is already how our `HTMLParser` treats it. See "Known gaps". |
| `DocumentTransform` | `prosemirror-transform` | **1.12.0** | 2026-03-30 | `ReplaceStep.map` structure-flag fix (1.10.4) **ported** this pass. `liftTarget` split-constraint (1.10.5), `Mapping.appendMap` aliasing (1.10.3, free via Swift value semantics), and `deleteRange` start-to-start (1.12.0) confirmed present. See "Known gaps". |
| `EditorStateKit` | `prosemirror-state` | **1.4.4** | 2025-10-23 | `insertText` selection-mapping fix (1.4.4) confirmed present. |
| `EditorCommands` | `prosemirror-commands` | **1.7.2** | 2026-08-22 | `splitBlock` measuring its split against the post-deletion selection (1.7.2) **ported** in an earlier pass. `splitBlockAs` has now been brought up to upstream's shape wholesale: the multi-depth walk out of an inline node (1.6.2), the reset of the empty leftover a start-of-block split leaves behind, and the `false` return when no split is possible (1.6.1) were all missing — the row previously claimed them as confirmed — and are **ported** this pass. The `splitNode` callback still takes `(node, atEnd)` rather than upstream's third `$from` parameter (an unported feature). See "Known gaps". |
| `SchemaKit` (tables) | `prosemirror-tables` | **1.8.5** | 2025-12-24 | `fixTables` zero-sized removal (1.6.4), colwidth validation (1.7.1), and keep-cell-type-on-row-move (1.8.1) confirmed present. Newer row/col *move* helpers track the same source. |
| `EditorHistory` | `prosemirror-history` | **1.5.0** | 2026-07-04 | Mark-step adjacency (1.4.1) and closed-event append guard (1.1.3) confirmed present. Composition grouping (1.3.1) and 1.5.0's beforeinput check N/A (no browser IME/DOM); `isHistoryTransaction` (1.5.0) is a feature, add on demand. |
| `EditorKeymap` | `prosemirror-keymap` | _not yet pinned_ | — | Upstream fixes are DOM `KeyboardEvent`-specific; the UIKit key handling is hand-written. Audit deferred. |
| `EditorInputRules` | `prosemirror-inputrules` | **1.5.1** | 2026-07-04 | Multi-char-input guard + `inCodeMark` code-mark suppression (1.5.0/1.5.1) **ported** this pass, with `MarkSpec.code` (model 1.25.0) added to support them; undo-without-text guard (1.1.3) confirmed present. `inCode: "only"` and the `undoable` option are unported features. |
| `EditorCollab` | `prosemirror-collab` | **1.3.1** | 2026-07-04 | `mapSelectionBackward` fixes (1.1.1/1.1.2) confirmed present; upstream's clearing of the selection-updated flag after mapping **ported** this pass (`Transaction.clearSelectionSet`). See "Known gaps" re remote-step application. |
| `EditorChangeset` | `prosemirror-changeset` | **2.4.2** | 2026-08-22 | Word-character range fix (2.4.1) and the too-big-to-diff guard (2.4.2) **ported** this pass, both with a correction — see the log. Typed close tokens (2.3.1) and multi-range steps (2.0.4) confirmed present. `Change` JSON serialization (2.4.0) is a feature, add on demand. |
| `SchemaKit` (lists) | `prosemirror-schema-list` | **1.5.1** | 2026-07-04 | `liftListItem` type-guarded join (1.5.1), adjacent-sublists join (1.2.2), and `splitListItem` sublist fix (1.1.5) confirmed present. See "Known gaps" re attr validation (1.4.1). |
| `EditorSerialization` | `prosemirror-markdown` + custom HTML | n/a | 2026-08-22 | HTML/Markdown serializers are hand-written for this editor's shapes, not direct ports; no upstream version to track. Upstream's `expelEnclosingWhitespace` behaviour (the subject of markdown 1.13.3/1.13.4/1.13.6) had no equivalent here and was **written this pass** — see the log. Trailing `order` handling (1.13.5) was already correct. |
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
- **`Slice.insertAt` content check** (prosemirror-model): upstream's `insertInto`
  refuses an insertion the parent's content expression rejects. The Swift
  `insertAt` never had that check, so it accepts insertions upstream would turn
  into a failed step. Narrower than it was — 1.25.5 dropped the check for open
  nodes, which is most of the cases — and the invalid slice still fails in
  `doc.replace`, which is what `ReplaceAroundStep` goes on to call.
- **`splitBlock` on an `AllSelection`** (prosemirror-commands): upstream bails
  before deleting anything when the selection's `$from` sits at depth 0, which an
  `AllSelection` always does. In a browser that is not the end of it — the keymap
  returns false, the contenteditable performs the delete-and-split itself, and the
  view reads the result back — so on screen select-all-then-Enter still splits.
  There is no such fallback here, so the depth check asks about the cursor the
  deletion leaves behind rather than the selection that went in. Every other
  selection reaches it unchanged.
- **`splitBlockAs`'s callback signature**: upstream passes the resolved position
  as a third argument (`(node, atEnd, $from)`), added in 1.6.0. The Swift closure
  takes `(node, atEnd)`; add the parameter when a caller needs it.
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

1. Read the upstream CHANGELOG from the "reviewed through" version onward.
   **Take it from npm, not GitHub.** ProseMirror development moved to
   `code.haverbeke.berlin` and the GitHub mirror's `master` has stopped
   tracking releases — in August 2026 it showed `prosemirror-model` at 1.25.4
   while npm had 1.25.11, so following the old procedure reported "nothing
   new" for four packages that had shipped eleven bug fixes between them. The
   npm tarball carries both the changelog and `src/`:

   ```sh
   curl -s https://registry.npmjs.org/prosemirror-transform/latest | \
     sed -n 's/.*"version":"\([^"]*\)".*/\1/p' | head -1
   curl -sL https://registry.npmjs.org/prosemirror-transform/-/prosemirror-transform-1.12.0.tgz | \
     tar -xzO package/CHANGELOG.md
   ```

   Diffing `src/` between the reviewed-through tarball and the current one
   shows what each entry actually changed, which the changelog prose often
   doesn't.
2. For each **bug fix** entry, find the corresponding Swift function and decide:
   already-ported, genuine gap, or N/A (e.g. a DOM/browser-only fix). Swift value
   semantics make some aliasing bugs not-applicable for free.
3. Port real gaps with a regression test; note free/duplicate confirmations here.
4. Bump the "reviewed through" version + date in the table above.

## Ported-fix log

- **2026-08-22** — `prosemirror-model` 1.25.3/1.25.5: `Slice.insertAt` asks the
  node the content lands in whether it may hold it, and returns `nil` when it may
  not. Without that check a `ReplaceAroundStep` could drop its gap anywhere the
  positions happened to fit — a paragraph into a code block — and `apply`
  succeeded, because nothing downstream rechecks a node the slice carries
  wholesale: the step produced a document its own schema rejects. The check skips
  a cut edge, which is upstream's 1.25.5 narrowing: what sits on an open edge is
  half a node, and the rest of it arrives from the document when the slice is
  placed, so the schema question there is about content the node never owns.
  `Sources/DocumentModel/Slice.swift`; regression tests in
  `Tests/DocumentTransformTests/SliceInsertAt.swift`, including the open/closed
  pair that pins the narrowing and the step that used to build the invalid doc.
- **2026-08-22** — `prosemirror-commands` 1.6.1/1.6.2 (and the older start-of-block
  behaviour): `splitBlockAs` was a reduction of upstream — it split one level, at a
  position it re-mapped rather than resolved, and reported success whether or not
  it had done anything. It now follows upstream's shape. It walks out to the
  nearest block, carrying a `nil` type per inline level crossed, so a cursor inside
  an inline node splits that node too; it returns `false` when neither the original
  type nor the default can be split to, instead of dispatching an empty
  transaction; and a split at the *start* of a block resets the empty block left in
  front to the default type when the schema allows it there — which is why Enter at
  the start of a heading now leaves a paragraph above it rather than a second empty
  heading. `Sources/EditorCommands/Commands.swift`; regression tests in
  `Tests/EditorCommandsTests/PMCommands.swift` and the upstream cases needing their
  own schema in `Tests/EditorCommandsTests/PMSplitBlockSchemas.swift`.
- **2026-08-22** — `prosemirror-markdown` 1.13.3/1.13.4/1.13.6 (in kind, not as a
  port): CommonMark will not open a delimiter run followed by whitespace or close
  one preceded by it, so `**foo **bar` spells no mark at all and the bold is gone
  the next time the document is read. `~~` and `==` are written as runs too but
  are deliberately paired *without* the flanking rules here, so whitespace beside
  one closes it and there is nothing to expel — the cost being that a strike we
  write with an inner space is read back by this parser and not by cmark-gfm,
  which does flank `~~`. The serializer now moves that whitespace
  outside the delimiters, holds hard breaks the same way — Markdown cannot spell
  one at the end of a block, where a trailing `\` reads back as a literal
  backslash — and drops whatever is still held at the end. Upstream predicts where
  a run ends (`isMarkAhead`); this works at the point the delimiters are written,
  which needs no prediction. `Sources/EditorSerialization/Markdown.swift`;
  regression tests, including a sweep over every three-piece paragraph these
  shapes can make, in
  `Tests/EditorSerializationTests/MarkdownDelimiterWhitespace.swift`.
- **2026-08-22** — `prosemirror-changeset` 2.4.1/2.4.2: `isLetter`'s ASCII range
  starts the lowercase block at 97 rather than 79, so ``[ \ ] ^ _ ` `` stop
  counting as word characters and a change stops growing across them — the typo
  had been ported faithfully, comment and all. `computeDiff` gives up on a
  region longer than `maxDiffSize` (now 2500) rather than running a search that
  cannot finish inside the bound — 253ms of it, in debug, to reach the same
  coarse answer.

  **Ported with the guard moved.** Upstream checks before tokenizing, and spells
  the comparison `max(toA - fromA, toB, fromB)` — two absolute positions where
  it means a length. Both spellings ask about the range as it arrived, which is
  conservative: a paragraph rewritten in one word arrives thousands of positions
  wide, and the scan from both ends cuts it to the word before Myers ever runs.
  Checking there made a 3005-wide range whose diff had been `[3001, 3005]` come
  back as the whole `[1, 3006]` — every such edit reading as a wholly rewritten
  paragraph. The guard asks after the trim instead, which keeps the precise diff
  and still skips the unfinishable search. `Sources/EditorChangeset/{Simplify,Diff}.swift`;
  regression tests in `Tests/EditorChangesetTests/main.swift`, one of them a time
  budget, since the guard's whole claim is about time — the output is identical
  either way.
- **2026-08-22** — `prosemirror-model` 1.25.x: `Fragment.fromJSON` builds through
  `Fragment.from` rather than the raw initializer, so JSON that spells one run of
  text as several adjacent nodes sharing markup loads in the canonical joined
  form. `Sources/DocumentModel/Fragment.swift`; regression tests in
  `Tests/DocumentModelTests/main.swift`.
- **2026-08-22** — `prosemirror-commands` 1.7.2: `splitBlock` deletes the
  selection first and measures everything against the selection that leaves
  behind, rather than against positions resolved in the document before it. For
  a selection running from a heading into a paragraph, the block being split is
  the heading — `splitBlockAs`'s callback was being asked about the paragraph,
  which no longer exists by the time the split happens.
  `Sources/EditorCommands/Commands.swift`; regression test in
  `Tests/EditorCommandsTests/PMCommands.swift`.

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

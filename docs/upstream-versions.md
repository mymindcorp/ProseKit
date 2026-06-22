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
| `EditorHistory` | `prosemirror-history` | _not yet pinned_ | — | Audit pending — pin a baseline next review. |
| `EditorKeymap` | `prosemirror-keymap` | _not yet pinned_ | — | Small, stable module. Audit pending. |
| `EditorInputRules` | `prosemirror-inputrules` | _not yet pinned_ | — | Audit pending. |
| `EditorCollab` | `prosemirror-collab` | _not yet pinned_ | — | Audit pending. |
| `EditorChangeset` | `prosemirror-changeset` | _not yet pinned_ | — | Audit pending. |
| `SchemaKit` (lists) | `prosemirror-schema-list` | _not yet pinned_ | — | Audit pending. |
| `EditorSerialization` | `prosemirror-markdown` + custom HTML | n/a | — | HTML/Markdown serializers are hand-written for this editor's shapes, not direct ports; no upstream version to track. |

## Known gaps / intentional deviations

- **`removeNodeMark` with a `MarkType`** (prosemirror-transform 1.10.4): upstream
  added an overload so passing a mark *type* removes all marks of that type from a
  node (aligning it with `removeMark`). The Swift `removeNodeMark` only accepts a
  concrete `Mark`. Low impact; add the overload if a caller needs it.

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

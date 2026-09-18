# Replaying generated edits

`SchemaKitTests` runs 12 fixed seeds with 60 edits each in normal CI. Each seed
starts with Unicode text, nested mixed lists, a table, and a hard break. It uses
the shared seeded RNG and command inventory, with valid text and node selections.
Operations include insertion, selection deletion, commands, Enter/Tab/Shift-Tab,
and undo/redo. Each session runs twice and compares its final document JSON,
selection, and operation trace.

After each operation the runner checks document validity, selection validity,
JSON round trips, table-map consistency, and table-repair idempotence. Declined
commands must leave the document unchanged. Each edit is isolated in history and
must undo to its previous document and redo to the edited document.

Run the default seeds:

```sh
PROSEKIT_STRICT=1 PROSEKIT_TEST_FILTER='seeded edits:' swift run SchemaKitTests
```

Run a larger sweep:

```sh
PROSEKIT_STRICT=1 PROSEKIT_EDIT_SEEDS=100 PROSEKIT_EDIT_STEPS=100 \
  PROSEKIT_TEST_FILTER='seeded edits:' swift run SchemaKitTests
```

Replay one seed (overrides the seed count):

```sh
PROSEKIT_EDIT_SEED=42 PROSEKIT_EDIT_STEPS=100 PROSEKIT_EDIT_TRACE=1 \
  PROSEKIT_TEST_FILTER='seeded edits:' swift run SchemaKitTests
```

Assertion failures include a replay command and the operation history. Trace
mode writes each operation to stderr **before** execution, so a process trap
also leaves a seed and step. Reduce the step count to isolate the shortest failing
prefix, then add a small named regression test alongside the fix. Seeds describe
the runner at a particular revision; preserve that revision when sharing a
reproduction. This headless runner does not exercise UIKit or IME behavior.

Malformed table import regressions run by default too:

```sh
PROSEKIT_TEST_FILTER='malformed table import:' swift run SchemaKitTests
```

They cover HTML and stored-node JSON, nonpositive and extreme row spans, wrong
attribute types, short/long/malformed column-width arrays, content preservation,
column resizing, and repair idempotence. Rowspan normalization follows the editor's
positive-span model; it does not implement HTML's special row-group semantics for
`rowspan="0"`.

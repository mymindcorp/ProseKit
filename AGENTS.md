# AGENTS

Notes for coding agents working in this repo.

## Toolchain / building

- **Package (library + tests):** build and test the SwiftPM package with:
  - `swift build`
  - `swift run <Module>Tests` — the headless suites are *executable* targets, not
    XCTest/Swift Testing (see `Tests/` and `Sources/TestHarness`), so they run
    under Command Line Tools alone.
  - The one exception is `EditorUIKitTests`, a real XCTest target for the
    renderer. It needs `xcodebuild` and a simulator; see [CLAUDE.md](CLAUDE.md).

- **Xcode is installed** at `/Applications/Xcode.app` and is currently the
  selected toolchain (`xcode-select -p` → `/Applications/Xcode.app/Contents/Developer`),
  so `xcodebuild` works directly. If a machine has Command Line Tools selected
  instead, prefix any `xcodebuild` invocation with a `DEVELOPER_DIR` override
  rather than `sudo xcode-select`:

  ```sh
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Examples/EditorDemo/EditorDemo.xcodeproj -scheme EditorDemo \
    -destination 'platform=macOS,variant=Mac Catalyst' \
    -derivedDataPath /tmp/editordemo-dd build
  ```

- **Demo project is generated** from `Examples/EditorDemo/project.yml` via `xcodegen`. After editing `project.yml`, run `xcodegen generate` in `Examples/EditorDemo/` to refresh the `.xcodeproj`.

## Platforms

- Minimum deployment targets are **macOS 15 / iOS 18** (required by the `Synchronization` module's `Mutex`).

## Reference sources (porting)

This codebase is a Swift port of ProseMirror/Tiptap. When porting algorithms or
test suites, port from the **official ProseMirror sources** at
<https://github.com/ProseMirror> (`prosemirror-model`, `-transform`, `-state`,
`-commands`, `-history`, `-collab`, `-tables`, `-inputrules`, `-keymap`,
`-schema-list`, `-markdown`, `-test-builder`).

**Fetch sources from npm, not from GitHub.** ProseMirror development moved to
`code.haverbeke.berlin`, and the GitHub mirror's `master` no longer tracks
releases — in August 2026 it was seven patch versions behind on
`prosemirror-model`. The npm tarball ships `src/` and `CHANGELOG.md`:

```sh
curl -sL https://registry.npmjs.org/prosemirror-history/-/prosemirror-history-1.5.0.tgz | tar -xz
cat package/src/history.ts
```

(WebFetch-style summarizer tools tend to refuse verbatim source; plain `curl`
works. `curl -s https://registry.npmjs.org/<pkg>/latest` gives the current
version.)

**Which upstream version is each module at?** See
[docs/upstream-versions.md](docs/upstream-versions.md) — it records the release
each module has been reviewed/ported through, known gaps, and the re-audit
procedure. When you port a new upstream fix, update that table and its ported-fix
log.

Provenance note: the table row/column *move* code
(`Sources/SchemaKit/TableMove.swift`, `TableMoveCommands.swift`,
`Tests/SchemaKitTests/PMTableMove.swift`) ports
**official `ProseMirror/prosemirror-tables`** `src/utils/` +
`test/{transpose,move-row-in-array-of-rows,convert-*}.test.ts`. Only port code
from ProseMirror. If you ever need an algorithm that exists only in a
non-ProseMirror repo, flag it explicitly in code comments and get sign-off
before porting from it.

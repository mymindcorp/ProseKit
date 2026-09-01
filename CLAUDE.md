# CLAUDE.md

Working agreements for this repo. Toolchain, platform, and porting-provenance
notes live in [AGENTS.md](AGENTS.md).

## Pull requests

**Never open stacked pull requests.** Every PR targets `main` directly. Do not
set a PR's base to another topic branch, and do not chain PRs so that one has to
merge before the next.

Why this is a hard rule rather than a preference: merging a stacked PR merges it
into its *base branch*, not into `main`. GitHub then marks it "Merged" and closes
it, so it reads as shipped from every view — the PR list, the branch, the
notification — while its commits are sitting on an intermediate branch that
nothing will ever merge forward. The work silently never lands.

That is not hypothetical here. PRs #24 (JSON encode) and #25 (HTML tokenizer)
both showed as merged, and neither was on `main`; it took an explicit
`git merge-base --is-ancestor` check per commit to notice. Recovering it needed a
separate merge and a full re-verification.

If a change genuinely depends on unmerged work:

- prefer folding it into the same PR, or
- wait for the dependency to land on `main`, then branch fresh from `main`.

If neither is possible, say so and ask — do not stack.

## Verifying tests

Claim a suite passes only from something that actually reports pass/fail.

- Headless suites: `swift run <Module>Tests` (exits non-zero on failure).
- iOS — needs a `-destination`, or it builds for the wrong platform:

  ```sh
  xcodebuild test -scheme ProseKit-Package -only-testing:EditorUIKitTests -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
  ```

  Piping it (`| tail`, `| grep`) makes `$?` the *pipe's* exit code, not
  `xcodebuild`'s, so a failing run can look clean. Redirect to a file and check
  `$?`, or read the counts out of the `.xcresult`:

  ```sh
  xcrun xcresulttool get test-results summary --path <…>.xcresult
  ```

- Build with `PROSEKIT_STRICT=1` to enforce warnings-as-errors, as CI does.

## Fuzzers

The sweeping fuzzers are opt-in — they walk every position of hundreds of
generated documents, which costs more than the rest of their suite put together.
(`EditorUIKitTests/InputFuzzTests` is the exception: it drives bounded, seeded
text-input sequences, is cheap, and always runs.)

Model and state (selections, commands, history, mapping, steps, serialization,
collaboration — with and without undo — copy/paste, foreign markup, the JSON
loaders on corrupt input, the structural transforms and the predicates that gate
them, track changes, tables, marks, input rules, decorations, task sorting,
search and its incremental highlighter):

```sh
PROSEKIT_FUZZ=1 swift run SchemaKitTests
PROSEKIT_FUZZ=1 PROSEKIT_FUZZ_DOCS=1000 swift run SchemaKitTests   # a deeper hunt
PROSEKIT_FUZZ=1 PROSEKIT_FUZZ_OPS=200 swift run SchemaKitTests     # more editing seeds
```

The LaTeX parser and layout (random token soup, every prefix and one-character
typo of the notation corpus, pathological nesting):

```sh
PROSEKIT_FUZZ=1 swift run EditorMathTests
```

The two knobs scale different sweeps, because the sweeps take different input:

- `PROSEKIT_FUZZ_DOCS` is how many *documents* the generated corpus holds. It
  deepens everything that inspects a static document — the selection sweeps and
  the serialization round-trips.
- `PROSEKIT_FUZZ_OPS` is how many *seeds* of a random editing session each sweep
  runs. It deepens everything that drives a live editor — steps, history,
  collaboration and track changes. Those share one op driver
  (`Tests/SchemaKitTests/FuzzOps.swift`), so an operation added there deepens
  all of them at once.

Add a new node type's commands to `fuzzOpCommands`, and its extension to
`fuzzKit()`. Both defaults are the *whole* kit, opt-in extensions included: the
sweeps that only edited `fullKit()` documents never once ran the commands that
build a figure or a footnote, while the corpus was full of them.

Layout geometry (`GeometryFuzzTests`: caret rects, hit testing, vertical
movement) and the `UITextInput` surface (`TextInputFuzzTests`) are iOS-only, and
gated by a *compilation condition* rather than an environment variable —
xcodebuild's `TEST_RUNNER_` prefix doesn't reach an SPM scheme's test runner.
The condition compiles both in; drop the `-only-testing:` to run them together:

```sh
xcodebuild test -scheme ProseKit-Package -only-testing:EditorUIKitTests/GeometryFuzzTests -destination 'platform=iOS Simulator,name=iPhone 17 Pro' SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) PROSEKIT_FUZZ'
```

`PROSEKIT_TEST_FILTER=<substring>` narrows any headless suite to matching cases.

The opt-in ones generate their documents from the schema's own content
expressions (`Sources/TestDocGen`, via `FuzzViews` on iOS), so coverage follows
the schema as extensions are added.
When adding a property, check it fails against a deliberately broken source —
an invariant no mutation can break is asserting nothing.

That check is worth doing even for a property that sounds airtight. "Every peer
ends up with the same document" survives a rebase that silently *drops* a local
step, because all of them agree on the log the step never reached — which is why
`CollabFuzz` also asserts that concurrent edits in separate places all survive.

## Benchmarks

Every benchmark is off by default so CI output stays quiet. The headless ones
read `PROSEKIT_BENCH` at runtime:

```sh
PROSEKIT_BENCH=1 swift run -c release EditorSerializationTests
PROSEKIT_BENCH=1 swift run -c release DocumentModelTests
PROSEKIT_BENCH=1 swift run -c release EditorStateKitTests
```

The renderer's are compiled out instead, for the same `TEST_RUNNER_` reason as
the geometry fuzzer, and want the optimizer turned on explicitly. There are
four, and they split the paint path between them: `RealizeBench` (what
`DocumentLayout.realize` costs per paint), `DrawBench` (what `draw(in:clipY:)`
costs), `EditorDrawBench` (the editable view's whole `draw`, with plugin
decorations), and `HotPathProbe` (a survey of the per-frame and per-keystroke
paths — scroll ticks, cursor moves, and typing, with and without the find bar
open). Swap the `-only-testing:` below for whichever you want:

```sh
xcodebuild test -scheme ProseKit-Package -configuration Release -only-testing:EditorUIKitTests/RealizeBench -destination 'platform=iOS Simulator,name=iPhone 17 Pro' ENABLE_TESTABILITY=YES SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) PROSEKIT_BENCH'
```

Run benchmarks in release — debug numbers are dominated by unspecialized
generics and are not comparable.

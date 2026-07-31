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
- iOS: `xcodebuild test -scheme ProseKit-Package -only-testing:EditorUIKitTests`.
  Piping it (`| tail`, `| grep`) makes `$?` the *pipe's* exit code, not
  `xcodebuild`'s, so a failing run can look clean. Redirect to a file and check
  `$?`, or read the counts out of the `.xcresult`:

  ```sh
  xcrun xcresulttool get test-results summary --path <…>.xcresult
  ```

- Build with `PROSEKIT_STRICT=1` to enforce warnings-as-errors, as CI does.

## Benchmarks

The serialization benchmark is off by default so CI output stays quiet:

```sh
PROSEKIT_BENCH=1 swift run -c release EditorSerializationTests
```

Run benchmarks in release — debug numbers are dominated by unspecialized
generics and are not comparable.

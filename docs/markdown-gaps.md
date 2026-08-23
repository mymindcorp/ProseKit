# Markdown parser gaps

Measured against the [CommonMark 0.31.2 spec test suite](https://spec.commonmark.org/0.31.2/spec.json)
(652 examples, CC-BY-SA 4.0 — not vendored; download it if you want to re-run).

Method: parse each example's Markdown with `MarkdownParser`, serialize the
document with `HTMLSerializer`, and compare against the expected HTML after
normalizing away pure serializer style (`<hr />` vs `<hr>`, `&quot;` vs `"`,
whitespace between block tags, and the newline CommonMark puts at the end of a
code block). A second pass checks that our *own* output re-reads identically —
`parse → serialize → parse == parse`.

**Current: 384/652 agree, 650/652 round-trip stable, nothing throws or crashes.**

The parser is deliberately not a CommonMark implementation, so full agreement
isn't the target. Round-trip stability is the number that matters for our own
documents; agreement matters for Markdown written elsewhere.

| | first measured | 2026-07-31 | 2026-08-22 |
| --- | --- | --- | --- |
| spec agreement | 137 | 353 | **384** |
| round-trip stable | 609 | 650 | **650** |
| threw or crashed | 0 | 0 | **0** |

The 2026-08-22 column is measured against `main` at c8f4338.

**Read the last column against the middle one with care.** The harness that
produced the first two columns was never committed — only this document was —
so the August figures come from a harness rebuilt from the method described
above. Its normalization is not guaranteed to match the original's character for
character, and the per-section costs below differ from the July ones in both
directions (fenced code blocks most visibly). Treat 353 → 384 as approximate.

Comparisons made *within* one harness run are exact, and those are the ones
worth acting on: see the round-trip section below.

One caution on the agreement figure itself:

- **It once undercounted code blocks**, because the harness didn't normalize the
  trailing newline CommonMark puts inside `<pre><code>`. Figures quoted before
  that was fixed (137–236) are on the old basis; everything from 246 on is
  comparable.

The list undercount recorded here in July is **gone**: a tight list now
serializes as `<ul><li>foo</li></ul>`, so the 18 examples it cost have come
back and normalizing the `<li><p>` form away no longer changes the score at all.

## Done

Recorded so the same ground isn't covered twice.

**Inline**

- delimiters escaped when serializing (`\`, `` ` ``, `*`, `_`, `[`, `]`, `$`,
  `&`, `<`, plus `=`/`~` doubled, and `!` before a link) — text used to come back
  as markup, and `====` and `snake_case_name` lost characters outright
- **emphasis via CommonMark's delimiter stack**, including the rule of three, so
  `***foo***` and `*foo **bar** baz*` nest correctly; flanking rules, including
  the intra-word underscore rule
- **marks serialize around runs**, not per node, so a bold spanning a link and
  the text after it is one run; a mark isn't closed around a node that can't
  carry it
- code spans by backtick run, with padding; a backtick fence's info string may
  not contain a backtick
- character references, except those producing control characters, which this
  model can't hold as text
- autolinks, through the URL sanitizer the link syntax uses
- **link reference definitions** — all three forms, for links and images,
  collected before parsing so a reference may precede its definition
- link and image titles, `<angle>` destinations, and a link-closing scan that
  survives parens inside a destination or title

**Blocks**

- tabs as block structure, expanded on four-column stops
- indented code blocks, including inside list items and blockquotes
- nested lists by indentation, with an item's content column measured from its
  own indent
- setext headings, and the `---` ambiguity resolved in setext's favour
- blockquote lazy continuation
- `~~~` fences, thematic breaks in every spelling, hard breaks from two trailing
  spaces, ATX closing runs
- list items holding multiple blocks; task lists round-tripping at all

## What's left

Disagreements per section, as measured on 2026-08-22 (268 in total):

| gap | examples | notes |
| --- | ---: | --- |
| **Raw HTML blocks and inline tags** | 44 of 44 + 14 of 20 | Pasted Markdown containing `<table>` or `<div>` is escaped into visible text. We already own a full HTML parser, so routing these through it is plausible rather than writing new code. Import-only. Still the largest bucket by some distance, and the only section we fail outright. |
| **List structure** | 24 of 48 + 12 of 26 | Start numbers, markers changing mid-list, and how far an item's content may be indented. No longer includes tight vs loose, which is fixed. |
| **Emphasis, the rest** | 27 of 132 | The stack is in; what remains is mostly precedence against links and code spans, and Unicode punctuation in the flanking tests. Down from 45 in July. |
| **Fenced code details** | 21 of 29 | Info strings, closing-fence length rules, indentation of the closing fence. July costed this at 13; the gap between the two figures is the harness caveat above, not a change in behaviour — the per-section counts are identical before and after every commit landed since. |
| **Links, the rest** | 20 of 90 + 12 of 27 | Mostly destinations and titles in shapes we don't accept yet, plus interaction with raw HTML. Down from 46 in July. |
| **Block quotes** | 15 of 25 | Largely their interaction with the list and raw-HTML gaps above. |
| **Setext headings** | 11 of 27 | |
| **Indented code blocks** | 10 of 12 | |
| **Entity edge cases** | 10 of 17 | Numeric references out of range, and references inside destinations. |
| **Everything else** | 48 | Hard line breaks 9, tabs 8, autolinks 7, backslash escapes 7, paragraphs 6, thematic breaks 3, and 2 each in images, soft line breaks, ATX headings, and code spans. |

## Divergences to keep

These follow from the document model. Listed so nobody spends time "fixing" them
or reads the agreement score as if they were failures.

- ~~**Tight vs loose lists.**~~ Fixed since July — a tight list now serializes as
  `<ul><li>foo</li></ul>`, not the `<li><p>` form. Kept here struck through
  because the July figures were quoted with an 18-example correction for it, and
  the August ones are not.
- **A code span can't carry another mark.** The schema's `code` mark excludes all
  others, so `**`code` is bold**` parses to a code span followed by bold text —
  which has no Markdown spelling, since `**` after a backtick can't open
  emphasis. The parse is right; the document is unwritable.
- **Exact whitespace between block elements**, `<hr />` vs `<hr>`, and which
  characters are entity-escaped. Cosmetic; normalized away above.
- **Percent-encoding of destinations.** CommonMark writes `/my uri` as
  `/my%20uri`; we keep destinations as written, as the HTML parser does.

## Round-trip: the two failures are not the two recorded here in July

Both July failures are **fixed**. A document of empty headings, and emphasis
spanning a soft line break into a setext underline, now both round-trip.

The count stayed at 650 anyway, because two new failures replaced them — and
unlike the July pair, these were not pathological. Tracking the count alone
would have hidden the swap completely; it took comparing the failing example
*ids* between runs to see it.

Bisected to `d68cba2`, which introduced a shortcut writing no delimiters around
a whitespace-only text node. Correct for the flanking marks it was written for,
applied to every mark instead — so `` ` ` ``, a legal code span holding a
space, lost its backticks and with them the mark:

| input | wrote | |
| --- | --- | --- |
| `` ` `\n`  ` `` (#334) | `` ` `  `` | second code span gone |
| ```` ``` ```\naaa ```` (#138) | `  aaa` | code span gone |

Fixed in #136, which restores **652/652** with agreement unmoved at 384. That
is the highest round-trip figure recorded here, and the first time nothing in
the suite fails it.

Measured with one harness across all three trees, so these are exact:

| | before `d68cba2` | `main` at c8f4338 | with #136 |
| --- | ---: | ---: | ---: |
| spec agreement | 384 | 384 | **384** |
| round-trip stable | 652 | 650 | **652** |
| threw or crashed | 0 | 0 | **0** |

## Keeping it honest

Three properties are worth holding onto while changing any of this:

- the 652 examples **never throw and never crash** — the property that matters
  most for the paste path, where hostile input arrives;
- **the identity of the failures, not just the count.** The two failures in
  August are not the two in July, and the count never moved. A regression that
  swaps one failure for another is invisible to the number by itself;
- **round-trip stability catches what agreement doesn't.** Several fixes in this
  work exist only because that number dropped when a feature went in: leaving
  control-character references alone, the escape-aware link scan,
  angle-wrapping awkward destinations, not closing a mark around a node that
  can't carry it, and dropping a list item's empty leading paragraph.

# Markdown parser gaps

Measured against the [CommonMark 0.31.2 spec test suite](https://spec.commonmark.org/0.31.2/spec.json)
(652 examples, CC-BY-SA 4.0 — not vendored; download it if you want to re-run).

Method: parse each example's Markdown with `MarkdownParser`, serialize the
document with `HTMLSerializer`, and compare against the expected HTML after
normalizing away pure serializer style (`<hr />` vs `<hr>`, `&quot;` vs `"`,
whitespace between block tags, and the newline CommonMark puts at the end of a
code block). A second pass checks that our *own* output re-reads identically —
`parse → serialize → parse == parse`.

**Current: 353/652 agree, 650/652 round-trip stable, nothing throws or crashes.**

The parser is deliberately not a CommonMark implementation, so full agreement
isn't the target. Round-trip stability is the number that matters for our own
documents; agreement matters for Markdown written elsewhere.

| | first measured | now |
| --- | --- | --- |
| spec agreement | 137 | **353** |
| round-trip stable | 609 | **650** |
| threw or crashed | 0 | 0 |

Two cautions when reading the agreement figure:

- **It undercounts lists.** A ProseMirror `listItem` always holds block content,
  so we emit `<li><p>…</p></li>` where CommonMark writes `<li>…</li>` for a tight
  list. Normalizing that difference away gives **371/652** — the extra 18 are
  entirely that.
- **It once undercounted code blocks**, because the harness didn't normalize the
  trailing newline CommonMark puts inside `<pre><code>`. Figures quoted before
  that was fixed (137–236) are on the old basis; everything from 246 on is
  comparable.

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

| gap | examples | notes |
| --- | ---: | --- |
| **Raw HTML blocks and inline tags** | 44 + 20 | Pasted Markdown containing `<table>` or `<div>` is escaped into visible text. We already own a full HTML parser, so routing these through it is plausible rather than writing new code. Import-only. The largest remaining bucket by some distance. |
| **Emphasis, the rest** | 45 of 132 | The stack is in; what remains is mostly precedence against links and code spans, and Unicode punctuation in the flanking tests. |
| **Links, the rest** | 46 of 90 | Mostly destinations and titles in shapes we don't accept yet, plus interaction with raw HTML. |
| **List structure** | 56 | Tight vs loose (see below) plus start numbers, markers changing mid-list, and how far an item's content may be indented. |
| **Fenced code details** | 13 | Info strings, closing-fence length rules, indentation of the closing fence. |
| **Entity edge cases** | 10 | Numeric references out of range, and references inside destinations. |

## Divergences to keep

These follow from the document model. Listed so nobody spends time "fixing" them
or reads the agreement score as if they were failures.

- **Tight vs loose lists.** A ProseMirror `listItem` always holds block content,
  so we always produce the paragraph form. Round-trips fine; only the HTML
  differs. Worth 18 examples.
- **A code span can't carry another mark.** The schema's `code` mark excludes all
  others, so `**`code` is bold**` parses to a code span followed by bold text —
  which has no Markdown spelling, since `**` after a backtick can't open
  emphasis. The parse is right; the document is unwritable.
- **Exact whitespace between block elements**, `<hr />` vs `<hr>`, and which
  characters are entity-escaped. Cosmetic; normalized away above.
- **Percent-encoding of destinations.** CommonMark writes `/my uri` as
  `/my%20uri`; we keep destinations as written, as the HTML parser does.

## The two that still don't round-trip

Both are pathological, and both are recorded rather than chased:

- a document of empty headings (`## \n#\n### ###`);
- a paragraph whose emphasis spans a soft line break, then a setext underline —
  the mark's text node holds a literal newline that a one-line heading can't
  write back.

## Keeping it honest

Two properties are worth holding onto while changing any of this:

- the 652 examples **never throw and never crash** — the property that matters
  most for the paste path, where hostile input arrives;
- **round-trip stability catches what agreement doesn't.** Several fixes in this
  work exist only because that number dropped when a feature went in: leaving
  control-character references alone, the escape-aware link scan,
  angle-wrapping awkward destinations, not closing a mark around a node that
  can't carry it, and dropping a list item's empty leading paragraph.

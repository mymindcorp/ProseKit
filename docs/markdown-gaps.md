# Markdown parser gaps

Measured against the [CommonMark 0.31.2 spec test suite](https://spec.commonmark.org/0.31.2/spec.json)
(652 examples, CC-BY-SA 4.0 — not vendored; download it if you want to re-run).

Method: parse each example's Markdown with `MarkdownParser`, serialize the
document with `HTMLSerializer`, and compare against the expected HTML after
normalizing away pure serializer style (`<hr />` vs `<hr>`, `&quot;` vs `"`,
whitespace between block tags). A second pass checks that our *own* output
re-reads identically — `parse → serialize → parse == parse`.

**Current: 234/652 agree, 647/652 round-trip stable, nothing throws or crashes.**

The parser is deliberately not a CommonMark implementation, so a low agreement
score is expected and isn't the target. Round-trip stability is the number that
matters for our own documents; agreement matters for Markdown written elsewhere.

| | first measurement | now |
| --- | --- | --- |
| spec agreement | 137 | **234** |
| round-trip stable | 609 | **647** |
| threw or crashed | 0 | 0 |

## Done

Recorded so the same ground isn't covered twice:

- **inline delimiters are escaped when serializing** (`\`, `` ` ``, `*`, `_`,
  `[`, `]`, `$`, `&`, `<`, plus `=`/`~` when doubled) — text used to come back
  as markup, and `====` and `snake_case_name` lost characters outright
- **a delimiter pair with nothing between it is text**, not an empty mark
- **emphasis follows the flanking rules**, including the intra-word underscore
  rule; a closing run is chosen by scanning for one that can actually close
- **code spans use backtick runs**, with padding, and a backtick fence's info
  string may not contain a backtick
- **character references** are decoded — except those producing control
  characters, which this model can't represent as text
- **autolinks**, through the same URL sanitizer the link syntax uses
- **`~~~` fences**, **link and image titles**, **`<angle>` destinations**,
  **thematic breaks in every spelling**, **hard breaks from two trailing
  spaces**, **ATX closing runs**
- **list items hold multiple blocks**, so a formula or fenced code block written
  under a bullet stays in that bullet
- **task lists** round-trip at all — they used to serialize to nothing

## What's left, by what it costs

| gap | examples | notes |
| --- | ---: | --- |
| **Emphasis: full delimiter stack** | 58 of 132 | We match pairs with flanking checks. Runs of 3+ (`foo***bar***baz`) need CommonMark's delimiter-stack algorithm, which nests emphasis inside strong. Also the last remaining round-trip instability. |
| **Link reference definitions** | 80 | `[foo]: /url "title"` plus `[foo]`. Needs a definition-collecting pass before inline parsing. Import-only — nothing we emit uses them. |
| **Raw HTML blocks and inline tags** | 58 | Pasted Markdown containing `<table>` or `<div>` is escaped into visible text. We already own a full HTML parser, so routing these through it is plausible rather than writing new code. Import-only. |
| **List structure** | 61 | Tight vs loose (see below), plus indentation-based nesting: an indented line that itself looks like a list marker still starts a sibling item rather than a nested list. |
| **Setext headings** | 19 | `===` / `---` underlines. `---` is also a thematic break, so this needs precedence: an underline directly after a paragraph wins. |
| **Indented code blocks** | ~17 | Four-space indentation. Much easier after tab expansion. |
| **Tab expansion** | 12 | Tabs as four-column stops. Feeds every indentation decision, so worth doing *before* indented code and nested lists. |
| **Blockquote lazy continuation** | 12 | `> bar\nbaz` — the unprefixed line should stay in the quote. |

Suggested order: **tabs**, then **indented code** and **nested lists** (both
much easier once tabs are normalized), then **setext** and **lazy
continuation**. Link reference definitions and raw HTML are the two large ones,
worth doing only if importing third-party Markdown becomes a real workflow.

## Divergences to keep

These follow from the document model. Listed so nobody spends time "fixing" them
or reads the agreement score as if they were failures.

- **Tight vs loose lists.** CommonMark emits `<li>one</li>` for a tight list and
  `<li><p>one</p></li>` for a loose one. A ProseMirror `listItem` always holds
  block content, so we always produce the paragraph form. Round-trips fine; only
  the HTML differs.
- **Exact whitespace and newlines between block elements**, `<hr />` vs `<hr>`,
  and which characters are entity-escaped. Cosmetic; normalized away above.
- **Percent-encoding of link destinations.** CommonMark writes `/my uri` as
  `/my%20uri`; we keep destinations as written, as the HTML parser does.
- **Raw HTML preserved verbatim.** Even after the raw-HTML work above, anything
  parsed into the document is re-serialized from the document, so
  byte-preservation of unknown markup is not a goal.

## Keeping it honest

Two properties are worth holding onto while changing any of this:

- the 652 examples currently **never throw and never crash** — the property that
  matters most for the paste path, where hostile input arrives;
- **round-trip stability catches what agreement doesn't.** Three changes in this
  work exist only because that number dropped when a feature went in: leaving
  control-character references alone, making the link scan escape-aware, and
  angle-wrapping awkward destinations.

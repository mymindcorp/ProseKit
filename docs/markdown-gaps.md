# Markdown parser gaps

Measured against the [CommonMark 0.31.2 spec test suite](https://spec.commonmark.org/0.31.2/spec.json)
(652 examples, CC-BY-SA 4.0 — not vendored; download it if you want to re-run).

Method: parse each example's Markdown with `MarkdownParser`, serialize the
document with `HTMLSerializer`, and compare against the expected HTML after
normalizing away pure serializer style (`<hr />` vs `<hr>`, `&quot;` vs `"`,
whitespace between block tags).

**Result: 137/652 (21%) agree. Nothing threw, and nothing crashed** — the 652
adversarial inputs are all handled safely, which is the property that matters
most for the paste path.

The parser is deliberately not a CommonMark implementation, so a low score is
expected. What follows separates the failures that are **bugs** (we mangle input
we already claim to support) from **missing features** (constructs we never
implemented) from **divergences** that follow from the document model and should
not be "fixed".

---

## A. Bugs — wrong output for input we already support

These corrupt ordinary text. They're independent of any decision about how much
of CommonMark to support, and each is small.

### A1. `==` in text is eaten by the highlight mark — corrupts setext headings

```
input:  Foo *bar*\n=========
want:   <h1>Foo <em>bar</em></h1>
got:    <p>Foo <em>bar</em> <mark></mark>=</p>
```

The `==highlight==` syntax (`Markdown.swift`, the `findSeq(chars, i + 2, "==")`
branch) consumes the `=` run: nine `=` become four empty `<mark>` pairs plus a
leftover. Any pasted document using setext headings — or a row of `=` as a
divider — is silently mangled. Highlight should require non-empty content and
probably shouldn't match across what is otherwise a heading underline.

*Also produces empty marks generally: `**` and `__` alone yield `<em></em>`
(spec example 46).*

### A2. A link title lands inside the URL

```
input:  [link](/uri "title")
want:   <a href="/uri" title="title">link</a>
got:    <a href="/uri &quot;title&quot;">link</a>
```

The destination is taken as everything up to `)`, so the title becomes part of
the href — a broken link, not just a lost title. Titles are common in real
Markdown. Related: `[link](<>)` keeps the angle brackets literally, and
`[link]()` drops the link entirely.

### A3. Emphasis ignores the flanking rules

```
input:  a * foo bar*        want: literal   got: a <em> foo bar</em>
input:  a*"foo"*            want: literal   got: a<em>"foo"</em>
input:  *\u{a0}a\u{a0}*     want: literal   got: <em> a </em>
```

CommonMark only opens emphasis on a *left-flanking* delimiter run (no whitespace
after the opener) and closes on a *right-flanking* one. We match any `*`…`*`
pair, so prose containing asterisks — footnote markers, `*` used as a bullet
mid-sentence, multiplication — turns into emphasis. This is the same class of
bug as the `$…$` currency case fixed in #26, and the fix has the same shape:
check the characters adjacent to the delimiter. 111 of the 515 failures are in
this section, so it's the single biggest lever.

### A4. Multi-backtick code spans are mangled

```
input:  `` foo ` bar ``     want: <code>foo ` bar</code>
                            got:  <code></code> foo <code> bar </code>`
```

Only single-backtick spans are recognized; a run of *n* backticks should open a
span that closes on the next run of exactly *n*. The current behavior produces
empty `<code>` elements and scrambles the text — the standard way to write a
code span containing a backtick.

### A5. Character entities are double-escaped

```
input:  &amp; &copy; &#35;
want:   & © #
got:    &amp;amp; &amp;copy; &amp;#35;
```

The Markdown parser doesn't decode entities, so the `&` is later escaped on the
way out and the entity becomes literal text. `HTMLParser.decodeEntities`
(`HTML.swift:1108`) already handles named, decimal and hex forms and is not
referenced from `Markdown.swift` at all — reusing it is most of the fix.

### A6. ATX headings keep their closing sequence and leading run

```
input:  ## foo ##          want: <h2>foo</h2>    got: <h2>foo ##</h2>
input:  #      foo         want: <h1>foo</h1>    got: <h1>     foo</h1>
```

An optional closing run of `#` should be stripped, and the space run after the
opener shouldn't survive into the text.

### A7. Hard line breaks need two trailing spaces

```
input:  foo␣␣\nbaz         want: foo<br />baz    got: foo baz
```

We support the backslash form (`foo\`) but not the two-trailing-spaces form,
which is what most editors emit. Cheap to add where the backslash form is
handled.

---

## B. Missing features, by how often they appear in real documents

Ordered by what actually turns up in pasted Markdown, not by spec example count.

| gap | examples | notes |
| --- | ---: | --- |
| **Link reference definitions** (`[foo]: /url "title"` + `[foo]`) | 80 | Common in hand-written docs and everything exported from wikis. Needs a definition pass before inline parsing. |
| **Raw HTML blocks and inline tags** | 58 | Pasted Markdown containing `<table>`, `<div>`, `<br>` is escaped into visible text. We *do* have a full HTML parser — routing these through it is plausible rather than writing new code. |
| **Setext headings** (`===` / `---` underlines) | 21 | Blocked on A1 either way. |
| **Indented code blocks** (4 spaces) | 19 | Already a documented limitation. Note `    ***` currently becomes `<hr>` rather than code. |
| **Tab expansion** (tabs as 4-column stops) | 12 | Affects indentation decisions everywhere, so worth doing before the indentation-sensitive items above. |
| **Autolinks** (`<https://example.com>`) | 11 | Left as literal text today. |
| **`~~~` fenced code** | — | Only ``` fences are recognized (`Markdown.swift`, the `hasPrefix("```")` branch), so a `~~~` block is parsed as Markdown and its contents can turn into blockquotes and emphasis. |
| **Blockquote lazy continuation** (`> bar\nbaz`) | 11 | The unprefixed line should stay in the quote; we end it and start a paragraph. |
| **Nested lists by indentation** | — | Partially addressed: indented continuation *blocks* now stay in their item (#26), but an indented line that itself looks like a list marker still starts a sibling item rather than a nested list. |

---

## C. Divergences to keep, not fix

These fall out of the document model. Listing them so nobody spends time
"fixing" them or reads the pass rate as if they were failures.

- **Tight vs loose lists.** CommonMark emits `<li>one</li>` for a tight list and
  `<li><p>one</p></li>` for a loose one. A ProseMirror `listItem` always holds
  block content, so we always produce the paragraph form. Round-trips fine; only
  the HTML differs.
- **Exact whitespace and newlines between block elements**, `<hr />` vs `<hr>`,
  and which characters are entity-escaped. Cosmetic; normalized away in the
  measurement above.
- **Raw HTML preserved verbatim.** Even after B's raw-HTML work, anything parsed
  into the document is re-serialized from the document, so byte-preservation of
  unknown markup is not a goal.

---

## Suggested order

1. **A1** (`==` eating `=` runs) — actively corrupts text and is contained.
2. **A5, A6, A7, A2** — small, self-contained, each removes a visible wrongness.
3. **A3** (emphasis flanking) — biggest single win, and the rule is written out
   plainly in the CommonMark spec's "delimiter run" definition.
4. **A4** (backtick runs) — self-contained.
5. **Tab expansion**, then the indentation-sensitive items (indented code,
   setext, nested lists), which are easier once tabs are normalized.
6. **Link reference definitions** and **raw HTML**, the two large features.

A useful guard while doing any of this: the 652 examples currently never throw.
Keeping that true — plus `parse → serialize → parse == parse` over the corpus —
catches regressions without requiring conformance.

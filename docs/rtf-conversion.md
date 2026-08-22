# RTF → document conversion

`RTFParser` (in `EditorSerialization`) reads RTF into a ProseMirror document
directly — Foundation only, no `NSAttributedString`, no Cocoa HTML writer, so it
works headless and on every platform this package builds for.

```swift
let doc = try RTFParser.parse(data, schema: schema)          // pasteboard bytes
let doc = try RTFParser.parse(rtfString, schema: schema)     // already decoded
let doc = try Node.fromRTF(data, schema: schema)             // same, matching Node.fromJSON
```

It is schema-aware in the same way the Apple Notes reader is: node and mark
types the schema doesn't declare degrade (heading → paragraph, table → its
cells' paragraphs, unknown mark → plain text) instead of failing. Only two
things throw: input that isn't RTF, and — defensively — a parsed document the
schema rejects.

## Where it's used

`EditorTextView.paste(_:)` reads RTF with this parser when the pasteboard offers
`public.rtf` **and nothing richer** — no `public.html`, no
`com.apple.notes.richtext`, no `com.apple.uikit.attributedstring`, no RTFD. Each
of those says something the plain RTF doesn't (its own parser, checklist state
RTF flattens, a conversion this skips, attachments living outside the RTF), so
those pastes keep the `NSAttributedString` bridge they already had. A plain-text
flavour alongside the RTF is not "richer" and doesn't divert the paste.

If the RTF won't parse, or parses to nothing, the paste falls through to that
bridge — the narrow path can only add outcomes, never take one away.

## What survives

| RTF | Document |
| --- | --- |
| `\par`, `\sect`, `\page` | paragraph break |
| `\line` | `hardBreak` |
| `\b \i \ul \strike \super \sub` | `bold` `italic` `underline` `strike` `superscript` `subscript` |
| `\cf` + `\colortbl` | `textColor` |
| `\highlight` / `\cb` + `\colortbl` | `backgroundColor` (or `highlight`) |
| `{\field{\*\fldinst HYPERLINK "…"}{\fldrslt …}}` | `link` (scheme-filtered by `sanitizeURL`) |
| `{\listtext …}` / `{\pntext …}`, `\ls`, `\ilvl`, `\li` | `bulletList` / `orderedList` / `taskList`, nested |
| `\*\listtable` + `\*\listoverridetable` | which levels are numbered (`\levelnfc`) and where they start (`\levelstartat` → `order`) |
| `☐ ☑ ✓` list markers | `taskItem` with `checked` |
| `\s` + `\stylesheet` names, `\outlinelevel` | `heading` (levels 1–6) |
| `\trowd … \cell … \row`, `\trhdr` | `table` / `tableRow` / `tableCell` / `tableHeader` |
| `\cellx`, `\trleft` | `colwidth`, in points per column |
| `\clmgf` / `\clmrg`, `\clvmgf` / `\clvmrg` | `colspan` / `rowspan` |
| `\itap`, `\nestcell` / `\nestrow`, `\*\nesttableprops` | tables nested inside a cell |
| a cell's own paragraphs, lists, headings, code blocks | real blocks inside the `tableCell`, not a flat run of paragraphs |
| `\qc` / `\qr` / `\qj` inside a cell | the cell's `align` |
| `\footnote` | `footnoteReference` in place + `footnoteDefinition` at the end |
| `\ansicpg`, `\fcharset` | text decoded in the code page it was written in, multi-byte pages included |
| `\pict\pngblip` / `\jpegblip`, hex or `\bin` | `image` with a `data:` URL, sized from `picwgoal` |
| `{\*\pn\pnlvlblt}` / `\pndec` / `\pnstart` | list kind and start for documents older than the list table |
| `HYPERLINK \\l "anchor"` | a `link` to `#anchor` |
| a monospaced-font paragraph run | `codeBlock`; a monospaced run inside prose → `code` mark |
| `\u`, `\'hh`, `\uc`, surrogate pairs, `\emdash`-style literals | text |
| `\v`, `\deleted`, `\info`, `\*\<unknown>` | dropped, along with their contents |

RTF has no notion of code, so the code mapping is a font heuristic
(`RTFConfig.monospaceAsCode`, on by default): it's what carries a monospaced
Apple Note or a pasted fenced block. Turn it off to keep such text as prose.

## What is approximated

- **List kind** comes from the `\listtable` definition the paragraph's `\ls`
  names — `\levelnfc23` is a bullet, every other code numbers. A checkbox glyph
  in the marker or in the level's `\leveltext` outranks it, since RTF has no
  checklist and the glyph is the only statement of one. Producers that ship no
  list table fall back to the drawn `\listtext` marker, and a bare `\ls` with
  neither reads as a bullet.
- **Numbering format** collapses: roman, lettered and ordinal levels all become
  one `orderedList`, because the document model has no per-level format. The
  *start* number survives (`\levelstartat`, and a `\lfolevel` override beats
  the definition).
- **Nesting depth** is `\ilvl` when present, otherwise `\li` divided by the
  half-inch step producers use. A document that indents by some other amount
  nests differently than it looked.
- **Headings** need either `\outlinelevel` (Word) or a stylesheet entry named
  "heading N" / "Title". RTF from a producer that spells headings only as "18pt
  bold" arrives as bold paragraphs, correctly — nothing in the file says
  "heading".
- **Code pages** are read: `\ansicpg` sets the document's, a font's
  `\fcharset` overrides it for runs in that font, and consecutive `\'hh` bytes
  are decoded together so multi-byte pages (Shift-JIS, GBK, Big5) come out
  right. A page this platform can't name, or bytes invalid in it, fall back to
  Windows-1252 rather than failing. The Symbol charset isn't a code page at all
  and is read as cp1252, which is enough for the bullet glyphs that reach a
  document.
- **Footnote labels** are the note's ordinal (1, 2, 3…), because RTF numbers
  footnotes by position and carries no identifier of its own.

## What is dropped — the gaps for a lossless round-trip

**Character formatting.** Font family and size (`\f` beyond the monospace
question, `\fs`), colour beyond fore/back (`\ul`-colour, shading patterns),
`\caps` / `\scaps` (small caps text arrives lowercase as authored), `\expnd`
letter-spacing, `\outl`, `\shad`, `\embo`, `\impr`. The document model has no
node or mark for any of these; adding one (e.g. a `fontSize` mark) is what it
would take.

**Paragraph formatting.** Alignment outside a table cell (there is no
`textAlign` on a paragraph in this schema — inside a cell it becomes the cell's
`align`), space before/after, line
spacing, first-line indent, tab stops, borders and shading, keep-with-next,
page breaks as such (`\page` is read as a plain paragraph break),
right-to-left/bidi (`\rtlpar`, `\ltrch`). Left indent (`\li`) is read *only* as
list nesting — an indented non-list paragraph loses its indent, and is **not**
turned into a `blockquote`, because indentation and quotation are genuinely
different things and guessing produces false quotes. RTF has no blockquote at
all, so no RTF file can round-trip one.

**Lists.** The numbering *format* per level (decimal vs roman vs lettered), the
marker's own text and suffix (`\leveltext` beyond its checkbox glyph),
restart-numbering, and continue-from-previous. What a level's format would need
is somewhere in the schema to put it — the start number, which the model does
have a place for, now survives.

**Tables.** Borders (`\clbrdr*`, `\trbrdr*`), cell shading (`\clcbpat`,
`\clshdng`), vertical alignment within a cell (`\clvertalt` / `\clvertalc` /
`\clvertalb`), row height (`\trrh`), cell padding (`\trgaph`, `\trpaddl`), table
indent and row alignment (`\trqc`, `\trleft` beyond the first column's width),
preferred widths and autofit (`\trwWidth`, `\trautofit`), keep-together
(`\trkeep`), and table styles (`\ts`). Structure — cells, rows, header rows,
spans, widths, nesting, and each cell's own blocks — is read; what's dropped is
decoration the document model has no attribute for.

`\clvmrg` cells whose anchor can't be found (a malformed row) are kept as plain
cells rather than dropped.

**Document structure.** Endnotes (`\*\aftn*`; footnotes proper are read),
headers, footers,
bookmarks (`\*\bkmkstart`), index and TOC entries, comments/annotations, fields
other than HYPERLINK (a `PAGE` or `DATE` field keeps its result text but loses
that it was a field), section and page setup, revision marks other than
`\deleted`, document metadata (`\info`: author, title, dates).

**Objects.** Embedded objects (`\object`: OLE, equations), drawings and shapes
(`\shp` beyond the `\shppict` picture wrapper), and WMF/EMF/PICT pictures (only
PNG and JPEG are inlined; a `\bin` payload of either is read). RTFD — the
directory format where Apple stores attachments in sibling files — isn't handled
at all; only the `.rtf` inside it would be.

**No serializer.** There is no document → RTF writer, so "lossless round-trip"
currently means RTF → document → HTML/Markdown/JSON. If RTF ever becomes an
export format, the pasteboard case (copy out of this editor, paste into Word)
is what would justify it.

## Speed

`PROSEKIT_BENCH=1 swift run -c release EditorSerializationTests` times it beside
the other formats. A 226 KB document — 1000 formatted paragraphs with lists,
tables, links and escapes — parses in about 13 ms. Three things account for most
of that having been 30 ms: the destination tables are built once at file scope
rather than per control word, a text run accumulates in one buffer instead of a
fresh string per character, and each font's "is this monospaced" answer is
decided when the font table is read rather than per run.

## Safety

Everything here is defensive: group state is parsed iteratively (no recursion to
overflow), `\bin` lengths and control-word parameters are bounded before use,
picture payloads are size-capped, link and image URLs go through `sanitizeURL`,
unknown `\*` destinations are dropped whole rather than guessed at, and table
nesting depth is clamped so a bogus `\itap` opens one table rather than nine.
Truncated, unbalanced, and hostile input parses to *something* valid or throws —
it never traps. The suite includes a deterministic sweep of random control-word
soup for that reason.

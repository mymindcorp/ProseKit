# ProseKit

A native Swift rich-text editor, heavily based on [Tiptap](https://tiptap.dev) (and the [ProseMirror](https://prosemirror.net) model beneath it): a value-typed document, transactional editing, and a Tiptap-style extension system, plus a CoreText-based renderer for UIKit / Mac Catalyst.

Everything except the renderer is pure, cross-platform Swift (value-typed document, invertible/mappable transaction steps, schema + extensions, JSON/HTML/Markdown). Only `EditorUIKit` touches UIKit. Minimum deployment targets: **iOS 18 / macOS 15**.

## Modules

| Module | Role |
| --- | --- |
| `DocumentModel` | Node / Fragment / Mark / Slice / Schema (the ProseMirror model) |
| `DocumentTransform` | Steps / StepMap / Mapping / Transform |
| `EditorStateKit` | EditorState / Transaction / Selection / Plugin |
| `EditorCommands`, `EditorHistory`, `EditorInputRules`, `EditorKeymap` | commands, undo/redo, input rules, keymap |
| `SchemaKit` | the Tiptap-style `Extension` layer + the `Editor` facade |
| `EditorSerialization` | ProseMirror-JSON, HTML, Markdown |
| `EditorUIKit` | the CoreText renderer: `EditorTextView` (editable) + `DocumentView` (read-only) |
| `EditorCollab` | rebaseable collaborative steps |
| `EditorSyntax` | optional: code-block syntax highlighting for the renderer's hook |
| `EditorMath` | optional: a native TeX typesetter for the renderer's math hook |

Each module ports a corresponding ProseMirror package; [docs/upstream-versions.md](docs/upstream-versions.md) tracks how far up each one has been reviewed/ported, so future ports know what's new to look for.

## Using the editor (no UI required)

HTML arriving from outside — a paste, a share sheet, a sync peer — is fitted to the schema on the way in: a bare `<li>` or `<td>` from a partial copy becomes a real list or table rather than an invalid document, and `HTMLParser.parse` either returns a document that passes `check()` or throws.

`Editor` owns the document and state. You change it by running named commands or dispatching transactions — all of this works headlessly (it's how the tests drive it).

```swift
import SchemaKit

// Build an editor from a set of extensions.
//   starterKit() — paragraphs, headings, lists, marks, blockquote, code, …
//   fullKit()    — starterKit + tables, task lists, collapsible details, math,
//                  images, wiki links, slash menu, collab cursors
let editor = try Editor(extensions: starterKit())

// Set the document: any node built against the editor's schema.
let s = editor.schema
editor.setContent(try s.node("doc", [:], content: .from([
    try s.node("heading", ["level": .int(1)], content: .from([s.text("Hello")])),
    try s.node("paragraph", [:], content: .from([s.text("World")])),
])))

// Run named commands contributed by the extensions.
editor.run("toggleBold")
editor.run("toggleBulletList")

// Or dispatch a transaction directly (inserts at the current selection).
let tr = editor.state.tr
try tr.insertText(" — edited")
editor.dispatch(tr)

// React to changes (re-render, autosave, …).
editor.onChange = { state in /* … */ }

// Read it back.
let document = editor.doc
```

### Serialization

```swift
import EditorSerialization

// Markdown
let markdown = editor.doc.toMarkdown()                         // → String
editor.setContent(try MarkdownParser.parse(markdown, schema: editor.schema))

// ProseMirror-shaped JSON (the canonical persistence format)
let json = try editor.doc.toJSONString(pretty: true)           // → String
editor.setContent(try Node.fromJSON(json, schema: editor.schema))
```

## Rendering to a surface

### Editable view

`EditorTextView` is a `UIView` that renders the editor and conforms to `UITextInput`, so you get the native caret, loupe, selection handles, IME/dictation, autocorrect, and edit menu for free. It is **viewport-virtualized**: pin it to a scroll view's viewport and it only ever draws the visible slice, so it stays fast on very large documents.

```swift
let editor = try Editor(extensions: fullKit())
editor.setContent(myDocument)

let textView = EditorTextView(editor: editor)   // also: EditorTextView(editor:theme:frame:)
let scroll = UIScrollView()
scroll.addSubview(textView)
textView.translatesAutoresizingMaskIntoConstraints = false
NSLayoutConstraint.activate([
    textView.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor),
    textView.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor),
    textView.topAnchor.constraint(equalTo: scroll.frameLayoutGuide.topAnchor),
    textView.bottomAnchor.constraint(equalTo: scroll.frameLayoutGuide.bottomAnchor),
])

// Drive the virtualization: feed the scroll offset in, size the content out.
textView.onDocumentHeightChange = { height in
    scroll.contentSize = CGSize(width: scroll.bounds.width, height: height)
}
// …in your UIScrollViewDelegate:
func scrollViewDidScroll(_ s: UIScrollView) { textView.contentOffsetY = s.contentOffset.y }

textView.becomeFirstResponder()
```

A complete SwiftUI host (document picker, virtualized scroll, prose loader, agent demo) lives in [Examples/EditorDemo](Examples/EditorDemo).

### Plain (read-only) renderer

`DocumentView` is the **plain, non-editable renderer**: it draws a document with the same layout engine but has no caret, no input, no spell-check, and no gestures. It **only draws the visible window**, so it's cheap even for huge documents. Use it for previews, thumbnails, feeds, or read-only displays. Pin it to a scroll viewport and feed `contentOffsetY` exactly like above, or use it at `documentHeight` for short content.

```swift
let view = DocumentView(document: myDocument)            // also: DocumentView(document:theme:)
let view = try DocumentView(json: jsonString, schema: schema)   // load + render in one step
```

To render into a surface you already own — another view's `draw(_:)`, a bitmap, a PDF page — call `render(into:height:offsetY:)`. Only blocks intersecting `[offsetY, offsetY + height]` are drawn:

```swift
override func draw(_ rect: CGRect) {
    guard let ctx = UIGraphicsGetCurrentContext() else { return }
    documentView.render(into: ctx, height: bounds.height, offsetY: scrollOffsetY)
}
```

## Customizing

- **Images** — `imageData` supplies bytes for an image node, `imageURLResolver` maps a node to a loadable URL, and `onImageDrop` persists dropped/pasted bytes. Images resolve *during* layout, so if the bytes weren't available yet the node laid out at a placeholder's size; call `reloadImages()` once they are and the document re-lays out around them. Images the renderer loads from a `src` URL adopt themselves.
- **Theme & fonts** — `EditorTextView.theme` / `DocumentView.theme` (a `TextTheme`): colors, spacing, and a custom typeface via `theme.fontName`, `theme.monoFontName`, and `theme.headingScale`. Dynamic Type is honored by default.
- **Suggestion menus** — any extension can provide a `SuggestionSource` and the renderer shows a popup for it. The `/` slash menu (`SlashMenuExtension`, `atLineStart` by default) and `[[` wiki links (`WikiLinkExtension(suggestions:)`) ship in `fullKit`; use `fullKit(wikiLinkSuggestions:)` to supply the candidate list.
- **Collapsible sections** — Tiptap's Details extension (`details` / `detailsSummary` / `detailsContent`, in `fullKit`): `editor.run("toggleDetails")` (also `Mod-Alt-d`, or `/details`) wraps the selected blocks in a section, and `toggleDetailsOpen` folds it. The renderer draws a disclosure triangle, and a closed section's body isn't laid out at all. Serializes to `<details><summary>…</summary>…</details>` in both HTML and Markdown.
- **Mathematics** — Tiptap's Mathematics extension (`inlineMath` / `blockMath`, in `fullKit`). See below.
- **Collaboration cursors** — `editor.setCollabCursor(id:anchor:head:color:label:)` draws another participant's caret (and selection); its position maps through every transaction. See the demo's "🤖 Agent" toggle for a worked example.

### Mathematics

Formulas are stored as LaTeX in a `latex` attribute on two atom nodes — `inlineMath`, which sits in a line of text, and `blockMath`, which takes its own row — matching Tiptap's Mathematics extension. Typing `$x^2$` converts inline; `$$…$$` alone in a block converts to display math. `/equation` inserts one from the slash menu.

```swift
editor.insertInlineMath(latex: "e^{i\\pi} + 1 = 0")
editor.insertBlockMath(latex: "\\sum_{n=1}^{\\infty} \\frac{1}{n^2} = \\frac{\\pi^2}{6}")
editor.updateInlineMath(latex: "x^3", at: pos)   // pos optional: defaults to the addressed node
editor.deleteBlockMath()
editor.migrateMathStrings()   // convert `$…$` runs in an older document into nodes
```

Rendering is opt-in, through `EditorMath` — a native TeX typesetter (no web view, no JavaScript) that implements KaTeX's box model with the same font parameters, drawing vectors through CoreText:

```swift
import EditorMath

editorView.mathRenderer = makeMathRenderer()
```

Without it, each formula draws its LaTeX source as monospaced text. Source the parser rejects is drawn verbatim in the muted code color rather than silently mis-rendered — KaTeX's `throwOnError: false` behavior.

Tapping a formula routes to `onActivateMath` (Tiptap's math `onClick`). The tap selects the node first, so a position-less `updateInlineMath` lands on the formula the user tapped:

```swift
editorView.onActivateMath = { node, pos in
    let latex = node.attrs["latex"]?.stringValue ?? ""
    presentEditor(for: latex) { edited in
        editor.updateInlineMath(latex: edited, at: pos)
    }
}
```

Leave it unset and a tap just places the caret. The demo app's "Math" document wires it to a prompt.

Both nodes round-trip through HTML (`<span data-type="inline-math" data-latex="…">`) and Markdown (`$…$` and `$$…$$`).

Tables and augmented matrices use `array`'s column spec, with `|` for vertical rules and `\hline` for horizontal ones:

```latex
\left[\begin{array}{cc|c} 1 & 2 & 3 \\ 4 & 5 & 6 \end{array}\right]
\begin{array}{|l|r|} \hline a & 1 \\ \hline b & 22 \\ \hline \end{array}
```

## Building & testing

The library and its tests build with plain SwiftPM; the demo needs Xcode's `xcodebuild`. See [AGENTS.md](AGENTS.md) for exact commands.

```sh
swift build
swift run SchemaKitTests        # the test suites are executable targets
```

## License & credits

ProseKit is released under the [MIT License](LICENSE) (© 2026 mymind, Inc.).

It is a Swift reimplementation heavily based on — and porting code and tests
from — two MIT-licensed projects, with gratitude:

- [**ProseMirror**](https://prosemirror.net) (© Marijn Haverbeke and others) — the document model, transforms, state, and the table/collab/changeset algorithms.
- [**Tiptap**](https://tiptap.dev) (© Tiptap GmbH) — the extension architecture, schema/mark naming, and editor ergonomics.

Their copyright and permission notices are reproduced in [NOTICE](NOTICE).

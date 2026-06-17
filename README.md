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

## Using the editor (no UI required)

`Editor` owns the document and state. You change it by running named commands or dispatching transactions — all of this works headlessly (it's how the tests drive it).

```swift
import SchemaKit

// Build an editor from a set of extensions.
//   starterKit() — paragraphs, headings, lists, marks, blockquote, code, …
//   fullKit()    — starterKit + tables, task lists, images, wiki links, slash menu, collab cursors
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

- **Theme & fonts** — `EditorTextView.theme` / `DocumentView.theme` (a `TextTheme`): colors, spacing, and a custom typeface via `theme.fontName`, `theme.monoFontName`, and `theme.headingScale`. Dynamic Type is honored by default.
- **Suggestion menus** — any extension can provide a `SuggestionSource` and the renderer shows a popup for it. The `/` slash menu (`SlashMenuExtension`, `atLineStart` by default) and `[[` wiki links (`WikiLinkExtension(suggestions:)`) ship in `fullKit`; use `fullKit(wikiLinkSuggestions:)` to supply the candidate list.
- **Collaboration cursors** — `editor.setCollabCursor(id:anchor:head:color:label:)` draws another participant's caret (and selection); its position maps through every transaction. See the demo's "🤖 Agent" toggle for a worked example.

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

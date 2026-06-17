import SwiftUI
import UIKit
import DocumentModel
import EditorStateKit
import SchemaKit
import EditorSerialization
import EditorUIKit
import EditorSyntax
import UniformTypeIdentifiers

@main
struct EditorDemoApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView().ignoresSafeArea(.container, edges: .horizontal)
        }
        // The editor supports inline marks but not fonts or text colors, so we
        // replace SwiftUI's default text-formatting menu (Fonts / sizes /
        // colors) with one offering only the supported formatting. Each command
        // routes through the responder chain to the focused EditorTextView.
        .commands {
            CommandGroup(replacing: .textFormatting) {
                ForEach(Array(EditorTextView.formatMenuActions.enumerated()), id: \.offset) { _, item in
                    Button(item.title) {
                        UIApplication.shared.sendAction(item.action, to: nil, from: nil, for: nil)
                    }
                }
            }
        }
    }
}

/// The documents the demo can switch between.
let demoDocuments: [(name: String, build: @Sendable (Schema) -> Node)] = [
    ("Showcase", sampleDocument),
    ("Long", longDocument),
    ("Empty", emptyDocument),
    ("Format", formattingDocument),
    ("Tables", tablesDocument),
    ("Code", codeDocument),
]

/// Inline formatting controls — the editor supports these marks but not fonts
/// or colors, so they live here rather than in a system Font menu. Each routes
/// through the responder chain to the focused `EditorTextView`.
struct FormattingToolbar: View {
    private let icons = ["Bold": "bold", "Italic": "italic", "Underline": "underline",
                         "Highlight": "highlighter", "Add Link…": "link"]
    var body: some View {
        HStack(spacing: 18) {
            ForEach(Array(EditorTextView.formatMenuActions.enumerated()), id: \.offset) { _, item in
                Button {
                    UIApplication.shared.sendAction(item.action, to: nil, from: nil, for: nil)
                } label: {
                    Image(systemName: icons[item.title] ?? "textformat")
                }
                .buttonStyle(.borderless)
                .help(item.title)
            }
            Spacer()
        }
        .font(.system(size: 15))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

struct ContentView: View {
    @State private var docIndex = 0
    /// The most recent paste-prose request, applied once by `EditorContainer`.
    @State private var proseLoad: ProseLoad?
    /// Monotonic id so each tap of "Load" is a distinct request.
    @State private var proseLoadSeq = 0
    @State private var showProseSheet = false
    @State private var proseDraft = sampleProseJSON
    @State private var loadError: String?
    /// Whether the simulated remote collaborator is inserting text as you type.
    @State private var agentOn = false
    /// Whether top-level blocks show drag handles for reordering.
    @State private var reorderOn = false
    /// Whether highlights render with the "real highlighter" drying-ink effect.
    @State private var dryingInkOn = false
    /// Whether the floating highlight bubble menu shows on selection.
    @State private var bubbleOn = false
    /// The live editor (handed up from the container) so the toolbar can read
    /// the current document — e.g. to dump its prose and verify marks.
    @State private var editorRef: Editor?
    /// The serialized document shown in the "View Prose" sheet (nil = hidden).
    @State private var proseOutput: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Document", selection: $docIndex) {
                    ForEach(demoDocuments.indices, id: \.self) { i in Text(demoDocuments[i].name).tag(i) }
                }
                .pickerStyle(.segmented)
                Button("Load Prose…") { showProseSheet = true }
                    .buttonStyle(.bordered)
                Button(agentOn ? "🤖 Stop" : "🤖 Agent") { agentOn.toggle() }
                    .buttonStyle(.bordered)
                    .tint(agentOn ? .orange : nil)
                Button(reorderOn ? "⠿ Reorder On" : "⠿ Reorder") { reorderOn.toggle() }
                    .buttonStyle(.bordered)
                    .tint(reorderOn ? .accentColor : nil)
                Button(dryingInkOn ? "🖍 Ink On" : "🖍 Ink") { dryingInkOn.toggle() }
                    .buttonStyle(.bordered)
                    .tint(dryingInkOn ? .accentColor : nil)
                Button(bubbleOn ? "💬 Bubble On" : "💬 Bubble") { bubbleOn.toggle() }
                    .buttonStyle(.bordered)
                    .tint(bubbleOn ? .accentColor : nil)
                Spacer()
                // Dump the live document's prose (ProseMirror JSON) so you can
                // confirm a highlight lands as a serializable `highlight` mark.
                Button("📄 Prose") {
                    proseOutput = editorRef.map { (try? DocumentJSON.string($0.doc, pretty: true)) ?? "(encode failed)" }
                        ?? "(no document)"
                }
                .buttonStyle(.bordered)
                .disabled(editorRef == nil)
            }
            .padding(8)
            Divider()
            // FormattingToolbar()  // hidden for now (struct kept for later)
            // Divider()
            EditorContainer(docIndex: docIndex, proseLoad: proseLoad, agentOn: agentOn,
                            reorder: reorderOn, useDryingInk: dryingInkOn, bubbleOn: bubbleOn,
                            onReady: { editorRef = $0 }) { message in
                loadError = message
            }
            .ignoresSafeArea(.keyboard)
        }
        .sheet(isPresented: $showProseSheet) {
            ProseSheet(json: $proseDraft, onLoad: {
                proseLoadSeq += 1
                proseLoad = ProseLoad(id: proseLoadSeq, json: proseDraft)
                showProseSheet = false
            }, onCancel: { showProseSheet = false })
        }
        .sheet(isPresented: Binding(get: { proseOutput != nil }, set: { if !$0 { proseOutput = nil } })) {
            ProseOutputSheet(text: proseOutput ?? "", onDone: { proseOutput = nil })
        }
        .alert("Couldn’t load prose", isPresented: Binding(
            get: { loadError != nil },
            set: { if !$0 { loadError = nil } }
        )) {
            Button("OK", role: .cancel) { loadError = nil }
        } message: {
            Text(loadError ?? "")
        }
    }
}

/// A single request to load pasted ProseMirror JSON into the editor. The `id`
/// lets the editor host apply each paste exactly once across SwiftUI updates.
struct ProseLoad: Equatable {
    let id: Int
    let json: String
}

/// Load a document from "prose" — ProseMirror-shaped JSON, the canonical
/// interchange format produced by `DocumentJSON.string(_:)` — into a live editor.
///
/// Decoding is done against the editor's own schema so the resulting node types
/// line up with the running document, then the content is swapped in via
/// `setContent` (which marks it non-undoable, like the initial document).
///
/// - Throws: `ModelError.invalidJSON` for malformed input, or a schema error if
///   the document references node or mark types the editor doesn't know about.
func loadProse(_ json: String, into editor: Editor) throws {
    let doc = try DocumentJSON.decode(editor.schema, json)
    editor.setContent(doc)
}

/// A sheet for pasting ProseMirror JSON and loading it into the editor.
struct ProseSheet: View {
    @Binding var json: String
    let onLoad: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            TextEditor(text: $json)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .padding(8)
                .navigationTitle("Load Prose")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Load", action: onLoad)
                            .disabled(json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
    }
}

/// A read-only sheet that dumps the live document's prose (ProseMirror JSON) so
/// you can confirm what actually landed in the node tree — e.g. that a highlight
/// shows up as `"marks": [ { "type": "highlight", ... } ]`.
struct ProseOutputSheet: View {
    let text: String
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .navigationTitle("Document Prose")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: onDone) }
            }
        }
    }
}

/// A small, valid ProseMirror document shown in the paste field by default, so
/// the expected JSON shape is obvious and "Load" works out of the box.
let sampleProseJSON = """
{
  "type": "doc",
  "content": [
    { "type": "heading", "attrs": { "level": 1 },
      "content": [ { "type": "text", "text": "Loaded from prose" } ] },
    { "type": "paragraph", "content": [
      { "type": "text", "text": "This document was decoded from ProseMirror JSON via " },
      { "type": "text", "marks": [ { "type": "code" } ], "text": "DocumentJSON.decode" },
      { "type": "text", "text": ". Edit the JSON above and tap Load." }
    ] },
    { "type": "bulletList", "content": [
      { "type": "listItem", "content": [
        { "type": "paragraph", "content": [ { "type": "text", "text": "Lists, marks, and headings all round-trip." } ] }
      ] }
    ] }
  ]
}
"""

/// Hosts an `EditorTextView` inside a scroll view, virtualized: the editor view
/// is pinned to the scroll viewport (never taller than the screen) and renders
/// only the visible window, while the scroll content height is the full document
/// height. This is what lets a 500-paragraph × 500-word document render at all.
struct EditorContainer: UIViewRepresentable {
    let docIndex: Int
    /// The latest pasted-prose request, or nil. Applied once per `id`.
    var proseLoad: ProseLoad?
    /// Whether the simulated collaborator ("Agent") is running.
    var agentOn: Bool = false
    /// Whether top-level blocks show drag handles for reordering.
    var reorder: Bool = false
    /// Whether highlights render as the "real highlighter" drying-ink effect.
    var useDryingInk: Bool = false
    /// Whether the floating highlight bubble menu shows on selection.
    var bubbleOn: Bool = false
    /// Hands the live editor up to the host once it's created (for the toolbar's
    /// "View Prose" dump).
    var onReady: ((Editor) -> Void)? = nil
    /// Surfaces a human-readable message when pasted prose fails to decode.
    var onLoadError: (String) -> Void

    @MainActor final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var editor: Editor?
        weak var textView: EditorTextView?
        weak var scroll: UIScrollView?
        var currentIndex = -1
        var lastProseID = 0
        var onLoadError: ((String) -> Void)?
        /// The demo drying-ink controller (records fresh highlights, draws ink).
        var dryingInk: DryingInk?
        /// The floating format bubble + whether it's currently enabled.
        var bubble: FormatBubble?
        var bubbleEnabled = false
        /// The selection range the bubble acts on (captured while it's shown, so a
        /// link applies to the right text even after the URL field takes focus).
        var bubbleRange: (from: Int, to: Int)?
        /// The last selection geometry, so the bubble can be re-laid-out when it
        /// changes its own size (Highlight → colors, Link → URL field).
        private var lastRects: [CGRect] = []
        private var lastEmpty = true
        /// Guards against reentrancy: `reset()` fires `onLayoutChange`, which calls
        /// back into `updateBubble` — without this it would recurse forever.
        private var layingOutBubble = false

        /// Position the bubble above the selection (or hide it), hosting it in the
        /// window so the scroll view can't clip it. Rects are in textView coords.
        func updateBubble(rects: [CGRect], isEmpty: Bool) {
            lastRects = rects; lastEmpty = isEmpty
            guard !layingOutBubble else { return }
            layingOutBubble = true
            defer { layingOutBubble = false }
            guard let bubble, let textView else { return }
            let wasHidden = bubble.isHidden
            guard bubbleEnabled, !isEmpty, let first = rects.first else {
                bubble.isHidden = true; bubbleRange = nil; return
            }
            let union = rects.dropFirst().reduce(first) { $0.union($1) }
            // Hide if the selection has scrolled out of the viewport.
            guard union.maxY > 0, union.minY < textView.bounds.height else { bubble.isHidden = true; return }
            // A fresh selection resets the bubble to its top-level buttons.
            if wasHidden { bubble.reset() }
            // Capture the range while it's still non-empty so a link applies even
            // after the URL field takes focus.
            if let sel = editor?.state.selection, !sel.empty { bubbleRange = (sel.from, sel.to) }

            let host = textView.overlayHost
            if bubble.superview !== host { bubble.removeFromSuperview(); host.addSubview(bubble) }
            let anchor = textView.convert(union, to: host)
            let b = host.bounds
            let size = bubble.fittingSize
            let x = min(max(anchor.midX - size.width / 2, 8), b.width - size.width - 8)
            var y = anchor.minY - size.height - 8
            if y < b.minY + 8 { y = anchor.maxY + 8 } // no room above → below
            bubble.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
            bubble.isHidden = false
            host.bringSubviewToFront(bubble)
        }

        /// Re-run layout against the last selection (the bubble resized itself).
        func relayoutBubble() { updateBubble(rects: lastRects, isEmpty: lastEmpty) }

        /// Apply (or, for an empty URL, remove) a link over the captured range.
        func applyBubbleLink(_ url: String) {
            guard let editor, let linkType = editor.schema.marks["link"],
                  let range = bubbleRange, range.to > range.from else { return }
            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            // Re-select the captured range (the URL field stole the doc selection).
            let doc = editor.state.doc
            let sel = TextSelection.create(doc, range.from, min(range.to, doc.content.size))
            editor.dispatch(editor.state.tr.setSelection(sel))
            editor.run(trimmed.isEmpty ? unsetLink(linkType) : setLink(linkType, href: trimmed))
        }

        // A simulated remote collaborator that inserts random words at random
        // positions — as transactions — while you type, to prove edits and
        // cursors interleave correctly.
        private var agentTimer: Timer?
        private var agentRunning = false
        private let agentWords = ["lorem", "ipsum", "banana", "quick", "fox", "editor",
                                  "swift", "async", "token", "river", "ember", "atlas", "pixel", "idea", "note"]

        func setAgent(_ on: Bool) {
            guard on != agentRunning else { return }
            agentRunning = on
            agentTimer?.invalidate()
            agentTimer = nil
            guard on, let editor else { return }
            editor.setCollabCursor(id: "agent", anchor: 1, head: 1, color: "#FF9500", label: "Agent")
            agentTimer = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return } // coordinator gone → stop
                Task { @MainActor in self.agentStep() }
            }
        }

        private func agentStep() {
            guard let editor, editor.doc.content.size > 2 else { return }
            // Mostly type a handful of words; sometimes delete one. Each is its
            // own transaction, so it maps the user's selection (and other cursors)
            // exactly how a real remote edit would arrive.
            if Int.random(in: 0 ..< 10) < 3 {
                agentDeleteWord(editor)
            } else {
                agentTypeWords(editor)
            }
        }

        private func agentTypeWords(_ editor: Editor) {
            let count = Int.random(in: 1 ... 5) // a handful in a row
            let text = (0 ..< count).map { _ in agentWords.randomElement() ?? "word" }.joined(separator: " ") + " "
            let pos = Int.random(in: 1 ..< editor.doc.content.size)
            let tr = editor.state.tr
            do { try tr.insertText(text, pos) } catch { return } // skip non-text positions
            editor.dispatch(tr)
            let head = min(pos + text.count, editor.doc.content.size)
            editor.setCollabCursor(id: "agent", anchor: head, head: head, color: "#FF9500", label: "Agent")
        }

        private func agentDeleteWord(_ editor: Editor) {
            let pos = Int.random(in: 1 ..< editor.doc.content.size)
            guard let (from, to) = agentWordRange(editor, at: pos) else { agentTypeWords(editor); return }
            let tr = editor.state.tr
            do { try tr.delete(from, to) } catch { return }
            editor.dispatch(tr)
            editor.setCollabCursor(id: "agent", anchor: from, head: from, color: "#FF9500", label: "Agent")
        }

        /// The document range of the word at `pos` (plus one trailing space), or
        /// nil if `pos` isn't inside a text word. Confined to a single textblock.
        private func agentWordRange(_ editor: Editor, at pos: Int) -> (Int, Int)? {
            let clamped = min(max(pos, 1), editor.doc.content.size)
            let resolved = editor.doc.resolve(clamped)
            guard resolved.parent.isTextblock, resolved.parent.content.size > 0 else { return nil }
            let chars = Array(resolved.parent.textBetween(0, resolved.parent.content.size))
            guard !chars.isEmpty else { return nil }
            let blockStart = clamped - resolved.parentOffset // doc position of the block's first character
            var i = min(resolved.parentOffset, chars.count - 1)
            if chars[i].isWhitespace, i > 0 { i -= 1 } // step back off a boundary
            guard !chars[i].isWhitespace else { return nil }
            var lo = i, hi = i + 1
            while lo > 0, !chars[lo - 1].isWhitespace { lo -= 1 }
            while hi < chars.count, !chars[hi].isWhitespace { hi += 1 }
            if hi < chars.count, chars[hi] == " " { hi += 1 } // also remove one trailing space
            return (blockStart + lo, blockStart + hi)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            textView?.contentOffsetY = scrollView.contentOffset.y
        }
        func syncContentHeight(_ height: CGFloat) {
            guard let scroll else { return }
            scroll.contentSize = CGSize(width: scroll.bounds.width, height: height)
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        // `[[` wiki-link suggestions from a fixed demo list. The provider lives on
        // the WikiLink extension (self-contained); the renderer just shows the
        // popup for whichever suggestion source is active. The `/` slash menu is
        // included by `fullKit` with its default commands.
        let editor = try! Editor(extensions: fullKit(wikiLinkSuggestions: { query in
            let pages = ["Home", "Getting Started", "Architecture", "ProseMirror", "Tiptap",
                         "Document Model", "Commands", "Keymap", "Schema", "Releases", "Roadmap"]
            guard !query.isEmpty else { return pages }
            return pages.filter { $0.range(of: query, options: .caseInsensitive) != nil }
        }))
        editor.setContent(demoDocuments[docIndex].build(editor.schema))

        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = true
        scroll.keyboardDismissMode = .interactive
        scroll.delegate = context.coordinator

        let textView = EditorTextView(editor: editor)
        // Vivid, near-fluorescent highlighter colors (the ink/flat highlight reads
        // these; the bubble/menu swatches use the same set — see HighlighterMenu).
        textView.theme.highlightColors = HighlighterMenu.themeColors
        // Opt into code-block syntax highlighting + language badges. Highlighting
        // only affects code blocks; detection only switches when confident.
        textView.syntaxHighlighter = makeSyntaxHighlighter()
        textView.codeLanguageLabel = makeCodeLanguageLabel()
        // Persist dropped/pasted images (incl. from Apple Notes) to a file and
        // reference them by path, instead of embedding huge data: URLs. The
        // built-in loader then loads the file:// src.
        textView.onImageDrop = { dropped in
            let ext = dropped.typeIdentifier.flatMap { UTType($0)?.preferredFilenameExtension } ?? "png"
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("drop-\(UUID().uuidString).\(ext)")
            guard (try? dropped.data.write(to: url)) != nil else { return nil } // nil → data: URL fallback
            return ["src": .string(url.absoluteString), "alt": .string(dropped.suggestedName ?? "image")]
        }
        // The drying-ink controller records fresh strokes and draws the marker ink;
        // the floating bubble routes color picks through it.
        let drying = DryingInk(textView: textView)
        context.coordinator.dryingInk = drying
        // NOTE: we deliberately do NOT set `textView.editMenuItems` here. Installing
        // a custom edit-menu interaction replaces the system callout (dropping the
        // OS Writing Tools / Rewrite items), so the highlighter lives in the bubble
        // instead and the native selection menu stays intact. `HighlighterMenu` is
        // still available as the edit-menu hook example.
        // Floating format bubble (Bold/Italic/Highlight/Link), shown over the
        // selection via onSelectionChange. Tapping Highlight reveals the colors;
        // tapping Link morphs into a URL field. Hosted in the window (un-clipped).
        let bubble = FormatBubble()
        bubble.isHidden = true
        bubble.onBold = { [weak coordinator = context.coordinator] in coordinator?.editor?.run("toggleBold") }
        bubble.onItalic = { [weak coordinator = context.coordinator] in coordinator?.editor?.run("toggleItalic") }
        bubble.onHighlight = { [weak coordinator = context.coordinator] color in
            guard let c = coordinator, let editor = c.editor else { return }
            c.dryingInk?.apply(color, to: editor)
        }
        bubble.onLink = { [weak coordinator = context.coordinator] url in
            coordinator?.applyBubbleLink(url)
        }
        bubble.onLayoutChange = { [weak coordinator = context.coordinator] in coordinator?.relayoutBubble() }
        context.coordinator.bubble = bubble
        textView.onSelectionChange = { [weak coordinator = context.coordinator] rects, isEmpty in
            coordinator?.updateBubble(rects: rects, isEmpty: isEmpty)
        }
        textView.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(textView)
        // Pinned to the viewport (frame), not the content — it stays screen-sized.
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor),
            textView.topAnchor.constraint(equalTo: scroll.frameLayoutGuide.topAnchor),
            textView.bottomAnchor.constraint(equalTo: scroll.frameLayoutGuide.bottomAnchor),
        ])
        textView.onDocumentHeightChange = { [weak coordinator = context.coordinator] height in
            coordinator?.syncContentHeight(height)
        }

        context.coordinator.editor = editor
        context.coordinator.textView = textView
        context.coordinator.scroll = scroll
        context.coordinator.currentIndex = docIndex

        DispatchQueue.main.async {
            _ = textView.becomeFirstResponder()
            context.coordinator.syncContentHeight(textView.documentHeight)
            onReady?(editor)
        }
        return scroll
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        let coordinator = context.coordinator
        guard let editor = coordinator.editor, let textView = coordinator.textView else { return }
        coordinator.onLoadError = onLoadError
        coordinator.setAgent(agentOn)
        textView.blockReorderingEnabled = reorder
        // Drying-ink highlight rendering (demo-only effect via highlightRenderer).
        coordinator.dryingInk?.enabled = useDryingInk
        textView.highlightRenderer = useDryingInk
            ? { [weak coordinator] ctx, runs in coordinator?.dryingInk?.render(ctx, runs) }
            : nil
        textView.setNeedsDisplay()
        // Floating highlight bubble menu (uses onSelectionChange).
        coordinator.bubbleEnabled = bubbleOn
        if !bubbleOn { coordinator.bubble?.isHidden = true }

        // A pasted-prose request takes priority and is applied exactly once.
        if let proseLoad, proseLoad.id != coordinator.lastProseID {
            coordinator.lastProseID = proseLoad.id
            do {
                try loadProse(proseLoad.json, into: editor)
                resetScroll(uiView, textView, coordinator)
            } catch {
                let message = String(describing: error)
                // Defer past the SwiftUI update phase before mutating @State.
                DispatchQueue.main.async { coordinator.onLoadError?(message) }
            }
            return
        }

        guard coordinator.currentIndex != docIndex else { return }
        editor.setContent(demoDocuments[docIndex].build(editor.schema))
        coordinator.currentIndex = docIndex
        resetScroll(uiView, textView, coordinator)
    }

    /// Scroll back to the top and resync the virtualized content height after a
    /// document swap.
    private func resetScroll(_ scroll: UIScrollView, _ textView: EditorTextView, _ coordinator: Coordinator) {
        scroll.setContentOffset(.zero, animated: false)
        textView.contentOffsetY = 0
        DispatchQueue.main.async { coordinator.syncContentHeight(textView.documentHeight) }
    }
}

/// A small helper for building documents against the editor's schema.
private struct B {
    let schema: Schema
    init(_ schema: Schema) { self.schema = schema }
    func n(_ type: String, _ attrs: Attrs = [:], _ content: [Node] = []) -> Node {
        try! schema.node(type, attrs, content: Fragment.from(content))
    }
    func p(_ c: Node...) -> Node { n("paragraph", [:], c) }
    func t(_ s: String) -> Node { schema.text(s) }
    func mark(_ s: String, _ m: String) -> Node { schema.text(s, [schema.mark(m)]) }
    func heading(_ level: Int, _ s: String) -> Node { n("heading", ["level": .int(level)], [t(s)]) }
}

/// A small gradient banner rendered to a data: URL, to demonstrate inline image
/// rendering without bundling an asset.
func sampleImageDataURL() -> String {
    let size = CGSize(width: 280, height: 80)
    let image = UIGraphicsImageRenderer(size: size).image { ctx in
        let colors = [UIColor.systemIndigo.cgColor, UIColor.systemTeal.cgColor]
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
        ctx.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        ("editor-swift" as NSString).draw(at: CGPoint(x: 16, y: 26),
            withAttributes: [.font: UIFont.boldSystemFont(ofSize: 26), .foregroundColor: UIColor.white])
    }
    return "data:image/png;base64," + (image.pngData()?.base64EncodedString() ?? "")
}

/// 1) A rich showcase exercising most node and mark types.
func sampleDocument(_ schema: Schema) -> Node {
    let b = B(schema)
    return b.n("doc", [:], [
        b.heading(1, "editor-swift"),
        b.n("image", ["src": .string(sampleImageDataURL()), "alt": .string("banner")]),
        b.p(b.t("A native Swift rich-text editor — a faithful Tiptap/ProseMirror port. Try typing, "),
            b.mark("bold", "bold"), b.t(", "), b.mark("italic", "italic"), b.t(", and "), b.mark("code", "code"), b.t(".")),
        b.heading(2, "Lists"),
        b.n("bulletList", [:], [
            b.n("listItem", [:], [b.p(b.t("immutable, value-typed document model"))]),
            b.n("listItem", [:], [b.p(b.t("transactional editing with undo/redo"))]),
            b.n("listItem", [:], [b.p(b.t("input rules: type "), b.mark("# ", "code"), b.t(" or "), b.mark("- ", "code"))]),
        ]),
        b.n("blockquote", [:], [b.p(b.t("All editing logic is shared; this view only renders + translates input."))]),
        b.p(b.t("Spell-check underlines a mispeled word as you type.")),
        b.p(b.t("\u{05E9}\u{05DC}\u{05D5}\u{05DD} \u{05E2}\u{05D5}\u{05DC}\u{05DD} — right-to-left text aligns from the right.")),
        b.heading(2, "Task list"),
        b.n("taskList", [:], [
            b.n("taskItem", ["checked": .bool(true)], [b.p(b.t("port the ProseMirror document model"))]),
            b.n("taskItem", ["checked": .bool(true)], [b.p(b.t("commands, history, input rules"))]),
            b.n("taskItem", ["checked": .bool(false)], [b.p(b.t("tap a checkbox to toggle it"))]),
            b.n("taskItem", ["checked": .bool(false)], [b.p(b.t("double-click a word to select it"))]),
        ]),
        b.heading(2, "Wiki links & tables"),
        b.p(b.t("See "), b.n("wikiLink", ["target": .string("Home"), "label": .string("the home page")]), b.t(" for more.")),
        b.n("table", [:], [
            b.n("tableRow", [:], [b.n("tableHeader", [:], [b.p(b.t("Feature"))]), b.n("tableHeader", [:], [b.p(b.t("Status"))])]),
            b.n("tableRow", [:], [b.n("tableCell", [:], [b.p(b.t("Marks"))]), b.n("tableCell", [:], [b.p(b.t("done"))])]),
            b.n("tableRow", [:], [b.n("tableCell", [:], [b.p(b.t("Tables"))]), b.n("tableCell", [:], [b.p(b.t("done"))])]),
        ]),
    ])
}

/// 2) A large document (520 paragraphs of ~500 words each + section headings)
/// for layout/scrolling performance — a deliberate torture test.
private let loremWords: [String] = """
lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore \
et dolore magna aliqua enim ad minim veniam quis nostrud exercitation ullamco laboris nisi aliquip \
ex ea commodo consequat duis aute irure in voluptate velit esse cillum eu fugiat nulla pariatur \
excepteur sint occaecat cupidatat non proident sunt culpa qui officia deserunt mollit anim id est laborum
""".split(separator: " ").map(String.init)

/// A paragraph of at least 500 words, varied per index.
private func longParagraphText(_ index: Int, words wordCount: Int = 500) -> String {
    var words = ["Paragraph", "\(index)."]
    var i = index
    while words.count < wordCount + 2 {
        var word = loremWords[i % loremWords.count]
        // A little sentence punctuation so it reads like prose, not a word list.
        if words.count % 12 == 0 { word += "," }
        if words.count % 23 == 0 { word += "." }
        words.append(word)
        i += 1
    }
    return words.joined(separator: " ") + "."
}

func longDocument(_ schema: Schema) -> Node {
    let b = B(schema)
    var blocks: [Node] = [b.heading(1, "Long document — 520 paragraphs × ~500 words")]
    for i in 1...520 {
        if i % 25 == 1 { blocks.append(b.heading(2, "Section \(i / 25 + 1)")) }
        blocks.append(b.p(b.t(longParagraphText(i))))
    }
    return b.n("doc", [:], blocks)
}

/// 3) An empty document (shows the placeholder).
func emptyDocument(_ schema: Schema) -> Node {
    let b = B(schema)
    return b.n("doc", [:], [b.p()])
}

/// 4) A formatting playground: every heading level, all marks, nested lists,
/// a blockquote, a code block, and a horizontal rule.
func formattingDocument(_ schema: Schema) -> Node {
    let b = B(schema)
    return b.n("doc", [:], [
        b.heading(1, "Heading 1"), b.heading(2, "Heading 2"), b.heading(3, "Heading 3"),
        b.heading(4, "Heading 4"), b.heading(5, "Heading 5"), b.heading(6, "Heading 6"),
        b.p(b.t("Marks: "), b.mark("bold", "bold"), b.t(" "), b.mark("italic", "italic"),
            b.t(" "), b.mark("strikethrough", "strike"), b.t(" "), b.mark("code", "code"), b.t(".")),
        b.n("bulletList", [:], [
            b.n("listItem", [:], [b.p(b.t("first")),
                b.n("bulletList", [:], [b.n("listItem", [:], [b.p(b.t("nested bullet"))])])]),
            b.n("listItem", [:], [b.p(b.t("second"))]),
        ]),
        b.n("orderedList", [:], [
            b.n("listItem", [:], [b.p(b.t("one"))]),
            b.n("listItem", [:], [b.p(b.t("two"))]),
        ]),
        b.n("blockquote", [:], [b.p(b.t("A blockquote spanning a sentence or two of text."))]),
        b.n("codeBlock", [:], [b.t("func greet(_ name: String) {\n    print(\"hello, \\(name)\")\n}")]),
        b.n("horizontalRule", [:], []),
        b.p(b.t("Text after the horizontal rule.")),
    ])
}

/// 6) Code blocks with syntax highlighting + language badges (EditorSyntax).
/// Some blocks are tagged with an explicit language; the last few carry no tag
/// and are auto-detected (only highlighted when detection is confident).
func codeDocument(_ schema: Schema) -> Node {
    let b = B(schema)
    func code(_ language: String?, _ source: String) -> Node {
        b.n("codeBlock", language.map { ["language": .string($0)] } ?? [:], [b.t(source)])
    }
    return b.n("doc", [:], [
        b.heading(1, "Code & Syntax Highlighting"),
        b.p(b.t("Blocks are highlighted by language with a badge in the corner. "),
            b.t("The tagged ones use their language; the auto-detected section has no tag.")),
        b.heading(3, "Swift"),
        code("swift", "func greet(_ name: String) -> String {\n    return \"Hello, \\(name)\"  // interpolation\n}"),
        b.heading(3, "TypeScript"),
        code("ts", "interface User { id: number; name: string }\nconst u: User = { id: 1, name: \"Ada\" }"),
        b.heading(3, "Python"),
        code("python", "def fib(n):\n    a, b = 0, 1\n    for _ in range(n):\n        a, b = b, a + b\n    return a  # nth Fibonacci"),
        b.heading(3, "CSS"),
        code("css", ".btn {\n  color: #ff3b30;\n  padding: 8px 12px;\n}"),
        b.heading(3, "JSON"),
        code("json", "{\n  \"name\": \"prosekit\",\n  \"version\": 1,\n  \"tags\": [\"editor\", \"swift\"]\n}"),
        b.heading(3, "SQL"),
        code("sql", "SELECT name, role FROM team\nWHERE active = true\nORDER BY name;"),
        b.heading(3, "Auto-detected (no language tag)"),
        code(nil, "package main\n\nfunc main() {\n    fmt.Println(\"detected as Go\")\n}"),
        code(nil, "fn main() {\n    let mut total = 0;\n    for i in 0..10 { total += i; }\n}"),
        code(nil, "#include <stdio.h>\nint main() { printf(\"hi\\n\"); return 0; }"),
    ])
}

/// 5) Tables and code blocks.
func tablesDocument(_ schema: Schema) -> Node {
    let b = B(schema)
    func cell(_ s: String, header: Bool = false) -> Node {
        b.n(header ? "tableHeader" : "tableCell", [:], [b.p(b.t(s))])
    }
    func row(_ cells: [Node]) -> Node { b.n("tableRow", [:], cells) }
    return b.n("doc", [:], [
        b.heading(2, "Tables"),
        b.p(b.t("Click a cell to edit it. Drag a column border to resize.")),
        b.n("table", [:], [
            row([cell("Name", header: true), cell("Role", header: true), cell("Team", header: true)]),
            row([cell("Ada"), cell("Engineer"), cell("Core")]),
            row([cell("Alan"), cell("Researcher"), cell("Theory")]),
            row([cell("Grace"), cell("Compiler"), cell("Tools")]),
        ]),
        b.heading(2, "Code"),
        b.n("codeBlock", [:], [b.t("let answer = 42\nprint(answer)  // Tab indents, Shift-Tab outdents")]),
    ])
}

// MARK: - Highlighter menu (sample selection edit-menu hook)

/// A dummy highlighter for the selection callout: a "Highlight" submenu with
/// five color choices plus a remove action. Wired via `EditorTextView.editMenuItems`.
enum HighlighterMenu {
    /// A highlighter ink that adapts to light/dark: vivid near-fluorescent over
    /// white paper; on dark, a slightly brighter hue that reads against the
    /// background (the ink renderer also switches to an additive blend in dark —
    /// see `DryingInk`, since `.multiply` collapses to invisible on dark).
    private static func ink(_ light: (CGFloat, CGFloat, CGFloat), _ dark: (CGFloat, CGFloat, CGFloat)) -> UIColor {
        UIColor { trait in
            let c = trait.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        }
    }

    /// (name — a `theme.highlightColors` key, display title, the swatch hue.)
    static let colors: [(name: String, title: String, swatch: UIColor)] = [
        ("yellow", "Yellow", ink((1.00, 0.95, 0.10), (0.95, 0.85, 0.28))),
        ("green",  "Green",  ink((0.40, 1.00, 0.20), (0.45, 0.92, 0.40))),
        ("blue",   "Blue",   ink((0.20, 0.80, 1.00), (0.35, 0.78, 1.00))),
        ("pink",   "Pink",   ink((1.00, 0.30, 0.65), (1.00, 0.45, 0.72))),
        ("orange", "Orange", ink((1.00, 0.55, 0.10), (1.00, 0.62, 0.28))),
    ]

    /// The highlight-mark colors for `theme.highlightColors` — the (dynamic)
    /// swatch hues at a translucent alpha, so flat highlights and the drying ink
    /// read as vivid in both light and dark.
    static var themeColors: [String: UIColor] {
        Dictionary(uniqueKeysWithValues: colors.map { ($0.name, $0.swatch.withAlphaComponent(0.55)) })
    }

    /// Builds the submenu, routing each choice through `apply` (a highlight color
    /// name, or nil to remove) so the host can also record it (e.g. drying ink).
    @MainActor
    static func items(apply: @escaping @MainActor (String?) -> Void) -> [UIMenuElement] {
        let colorActions: [UIMenuElement] = colors.map { color in
            UIAction(title: color.title, image: swatch(color.swatch)) { _ in apply(color.name) }
        }
        let remove = UIAction(title: "Remove", image: UIImage(systemName: "xmark.circle")) { _ in apply(nil) }
        return [UIMenu(title: "Highlight",
                       image: UIImage(systemName: "highlighter"),
                       children: colorActions + [remove])]
    }

    /// A small filled-circle swatch for a menu row.
    static func swatch(_ color: UIColor) -> UIImage {
        let size = CGSize(width: 20, height: 20)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            color.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2))
        }.withRenderingMode(.alwaysOriginal)
    }
}

// MARK: - Drying ink (demo-only "real highlighter" effect via highlightRenderer)

/// A small deterministic RNG so each highlight's imperfections are stable across
/// redraws and scrolling (no per-frame shimmer). Seeded by the run's position.
private struct SeededRNG {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed ^ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        var z = state
        z = (z ^ (z >> 33)) &* 0xFF51AFD7ED558CCD
        z = (z ^ (z >> 33)) &* 0xC4CEB9FE1A85EC53
        return z ^ (z >> 33)
    }
    mutating func unit() -> CGFloat { CGFloat(next() >> 11) * (1.0 / 9_007_199_254_740_992.0) }
    mutating func range(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * unit() }
}

/// Renders highlights as a translucent felt-tip marker over paper: ink overflows
/// the glyph box a little, density is uneven, ink pools at the ends, overlapping
/// strokes darken (multiply), and a freshly-applied stroke goes down "wet"
/// (darker, more spread, a faint sheen) and dries to a settled matte over ~1.3s.
@MainActor
final class DryingInk {
    weak var textView: EditorTextView?
    var enabled = false

    private struct Stroke { let from: Int; let to: Int; let at: CFTimeInterval }
    private var strokes: [Stroke] = []
    private var link: CADisplayLink?
    private let dryDuration: CFTimeInterval = 1.3
    /// Pen speed in characters/second — a natural hand-highlighting pace, so the
    /// sweep takes about as long as it would on a real page (longer text = longer).
    private let charSpeed: CGFloat = 52

    init(textView: EditorTextView) { self.textView = textView }

    /// Apply a highlight (`color` is a name, or nil to remove). When enabled, the
    /// applied range is recorded as fresh wet ink and the drying animation starts.
    func apply(_ color: String?, to editor: Editor) {
        let sel = editor.state.selection
        if enabled, color != nil, !sel.empty {
            strokes.append(Stroke(from: sel.from, to: sel.to, at: CACurrentMediaTime()))
            startLink()
        }
        editor.setHighlight(color)
        // Replace the system (blue) selection with the ink: collapse the caret to
        // the end of the highlighted range so the marker shows, not the selection.
        if color != nil, !sel.empty {
            let tr = editor.state.tr
            tr.setSelection(TextSelection.create(tr.doc, min(sel.to, tr.doc.content.size)))
            editor.dispatch(tr)
        }
    }

    private var isDark: Bool { textView?.traitCollection.userInterfaceStyle == .dark }

    /// The `EditorTextView.highlightRenderer`: draw each run as marker ink.
    func render(_ ctx: CGContext, _ runs: [HighlightRun]) {
        let now = CACurrentMediaTime()
        ctx.saveGState()
        // Over white paper, multiply makes translucent ink read like a real marker
        // (overlapping strokes darken). On a dark background multiply collapses to
        // invisible, so add light instead — the ink glows.
        ctx.setBlendMode(isDark ? .plusLighter : .multiply)
        for run in runs { drawInk(ctx, run, now: now) }
        ctx.restoreGState()
    }

    /// The most recent fresh stroke covering this run (nil once it has expired).
    private func freshStroke(for run: HighlightRun) -> Stroke? {
        var best: Stroke?
        for s in strokes where run.from < s.to && run.to > s.from {
            if best == nil || s.at > best!.at { best = s }
        }
        return best
    }

    private func drawInk(_ ctx: CGContext, _ run: HighlightRun, now: CFTimeInterval) {
        let stroke = freshStroke(for: run)
        // Per-position timing: the pen sweeps left→right at a constant, natural
        // speed; each spot is wet the instant the pen passes and dries behind it —
        // exactly as dragging a real highlighter across the page would look.
        var p: CGFloat = 1        // 0 = wet, 1 = dry
        var revealed: CGFloat = 1 // fraction of this run the pen has covered
        if let s = stroke {
            let elapsed = CGFloat(now - s.at)
            let penChars = elapsed * charSpeed
            let startChar = CGFloat(run.from - s.from)
            let runChars = max(1, CGFloat(run.to - run.from))
            revealed = min(1, max(0, (penChars - startChar) / runChars))
            if revealed <= 0.001 { return }                  // pen hasn't arrived here
            let localElapsed = elapsed - startChar / charSpeed // time since the pen entered
            p = min(1, max(0, localElapsed / CGFloat(dryDuration)))
        }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        run.color.getRed(&r, green: &g, blue: &b, alpha: &a)
        func ink(_ alpha: CGFloat) -> UIColor { UIColor(red: r, green: g, blue: b, alpha: alpha) }
        func lerp(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * p }

        // Wet ink is more opaque and spreads further; it dries lighter and the
        // bleed sets in tighter. (Additive dark mode needs lower alpha.)
        let alpha = isDark ? lerp(0.52, 0.34) : lerp(0.78, 0.62)
        let bleedX = lerp(3.0, 1.5), bleedTop = lerp(2.0, 1.0), bleedBot = lerp(2.8, 1.5)
        let main = CGRect(x: run.rect.minX - bleedX, y: run.rect.minY - bleedTop,
                          width: run.rect.width + bleedX * 2,
                          height: run.rect.height + bleedTop + bleedBot)
        // Chisel-tip marker: nearly flat (square) ends, not round pills.
        let rounding: CGFloat = 2
        func rrect(_ rect: CGRect, _ rad: CGFloat) -> UIBezierPath { UIBezierPath(roundedRect: rect, cornerRadius: rad) }
        var rng = SeededRNG(UInt64(bitPattern: Int64(run.from)) &* 0x2545F4914F6CDD1D)

        func paint() {
            // Soft halo: faint spread past the glyphs.
            ink(alpha * 0.40).setFill()
            rrect(main.insetBy(dx: -1.0, dy: -0.8), rounding + 1).fill()
            // Body.
            ink(alpha).setFill()
            rrect(main, rounding).fill()
            // Uneven density: short seeded streaks (felt pressure varies).
            let streaks = max(2, Int(main.width / 42))
            for _ in 0..<streaks {
                let w = rng.range(main.width * 0.15, main.width * 0.42)
                let x = rng.range(main.minX, max(main.minX, main.maxX - w))
                let dy = rng.range(-1.0, 1.2)
                let h = max(2, main.height - rng.range(1, 3))
                ink(alpha * 0.24).setFill()
                rrect(CGRect(x: x, y: main.minY + dy + (main.height - h) / 2, width: w, height: h), rounding).fill()
            }
            // Ink builds a touch at the start and stop (chiseled, square caps).
            ink(alpha * 0.5).setFill()
            let cap = main.height * 0.5
            rrect(CGRect(x: main.minX, y: main.minY, width: cap, height: main.height), rounding).fill()
            rrect(CGRect(x: main.maxX - cap, y: main.minY, width: cap, height: main.height), rounding).fill()
            // Wet sheen: a faint bright band near the top while still wet.
            if p < 1 {
                ctx.saveGState()
                ctx.setBlendMode(.screen)
                UIColor(white: 1, alpha: (1 - p) * 0.16).setFill()
                rrect(CGRect(x: main.minX + 3, y: main.minY + 1.5,
                             width: max(0, main.width - 6), height: max(1, main.height * 0.2)), 1.5).fill()
                ctx.restoreGState()
            }
        }

        // Clip to the swept portion so the ink "draws on" with a crisp chisel edge.
        if revealed < 1 {
            ctx.saveGState()
            let w = main.width * revealed + rounding
            ctx.clip(to: CGRect(x: main.minX - 3, y: main.minY - 10, width: w + 3, height: main.height + 20))
            paint()
            ctx.restoreGState()
        } else {
            paint()
        }
    }

    private func startLink() {
        guard link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        // A stroke is done once the pen has crossed its whole length and the last
        // spot has dried (so long highlights keep animating for their full sweep).
        strokes.removeAll { s in
            let sweep = Double(s.to - s.from) / Double(charSpeed)
            return now - s.at > sweep + dryDuration
        }
        textView?.setNeedsDisplay()
        if strokes.isEmpty { link?.invalidate(); link = nil }
    }
}

// MARK: - Floating selection bubbles (via onSelectionChange)

/// A floating bar the host positions over the selection. `onLayoutChange` lets
/// the bubble ask to be repositioned when its own size changes (e.g. the link
/// field appears); `fittingSize` is its natural size.
@MainActor
protocol FloatingBubble: UIView {
    var fittingSize: CGSize { get }
    var onLayoutChange: (() -> Void)? { get set }
}

/// A floating formatting bar shown over the selection: **Bold · Italic ·
/// Highlight · Link**. Tapping *Highlight* reveals the five highlight colors
/// (plus remove); tapping *Link* morphs the bar into a URL field. A back chevron
/// returns to the buttons. The host positions it via `onSelectionChange`.
@MainActor
final class FormatBubble: UIView, FloatingBubble {
    var onLayoutChange: (() -> Void)?
    var onBold: (() -> Void)?
    var onItalic: (() -> Void)?
    /// A highlight color name, or nil to remove the highlight.
    var onHighlight: ((String?) -> Void)?
    /// The submitted URL (empty string removes the link).
    var onLink: ((String) -> Void)?

    private enum Mode { case buttons, colors, link }
    private let content = UIStackView()
    private let urlField = UITextField()

    init() {
        super.init(frame: .zero)
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 11
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.22
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: 2)

        content.axis = .horizontal
        content.spacing = 6
        content.alignment = .center
        content.isLayoutMarginsRelativeArrangement = true
        content.layoutMargins = UIEdgeInsets(top: 6, left: 9, bottom: 6, right: 9)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        urlField.placeholder = "https://…"
        urlField.font = .preferredFont(forTextStyle: .body)
        urlField.autocapitalizationType = .none
        urlField.autocorrectionType = .no
        urlField.keyboardType = .URL
        urlField.clearButtonMode = .whileEditing
        urlField.returnKeyType = .done
        urlField.translatesAutoresizingMaskIntoConstraints = false
        urlField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        urlField.addAction(UIAction { [weak self] _ in self?.submitLink() }, for: .editingDidEndOnExit)

        show(.buttons)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Reset to the buttons row (e.g. when a fresh selection is made).
    func reset() { if !content.arrangedSubviews.isEmpty { show(.buttons) } }

    var fittingSize: CGSize { systemLayoutSizeFitting(UIView.layoutFittingCompressedSize) }

    // MARK: - Rows

    private func toolButton(_ symbol: String, tint: UIColor = .label, _ action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .system)
        b.setImage(UIImage(systemName: symbol), for: .normal)
        b.tintColor = tint
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 30).isActive = true
        b.heightAnchor.constraint(equalToConstant: 28).isActive = true
        b.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return b
    }

    private func separator() -> UIView {
        let v = UIView()
        v.backgroundColor = .separator
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return v
    }

    private func swatchButton(_ color: (name: String, title: String, swatch: UIColor)) -> UIButton {
        let dot = UIButton(type: .system)
        dot.backgroundColor = color.swatch
        dot.layer.cornerRadius = 11
        dot.layer.borderColor = UIColor.separator.cgColor
        dot.layer.borderWidth = 0.5
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 22).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 22).isActive = true
        dot.addAction(UIAction { [weak self] _ in self?.onHighlight?(color.name); self?.show(.buttons) }, for: .touchUpInside)
        return dot
    }

    private func viewsFor(_ mode: Mode) -> [UIView] {
        switch mode {
        case .buttons:
            return [
                toolButton("bold") { [weak self] in self?.onBold?() },
                toolButton("italic") { [weak self] in self?.onItalic?() },
                separator(),
                toolButton("highlighter") { [weak self] in self?.show(.colors) },
                toolButton("link") { [weak self] in self?.show(.link) },
            ]
        case .colors:
            var views: [UIView] = [toolButton("chevron.left") { [weak self] in self?.show(.buttons) }, separator()]
            views += HighlighterMenu.colors.map { swatchButton($0) }
            views.append(toolButton("xmark", tint: .secondaryLabel) { [weak self] in
                self?.onHighlight?(nil); self?.show(.buttons)
            })
            return views
        case .link:
            return [
                toolButton("chevron.left") { [weak self] in self?.show(.buttons) },
                urlField,
                toolButton("checkmark", tint: .systemBlue) { [weak self] in self?.submitLink() },
            ]
        }
    }

    private func show(_ mode: Mode) {
        for v in content.arrangedSubviews { content.removeArrangedSubview(v); v.removeFromSuperview() }
        for v in viewsFor(mode) { content.addArrangedSubview(v) }
        if mode == .link { urlField.becomeFirstResponder() } else { urlField.resignFirstResponder() }
        onLayoutChange?()
    }

    private func submitLink() {
        onLink?(urlField.text ?? "")
        urlField.text = ""
        show(.buttons)
    }
}

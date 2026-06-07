import SwiftUI
import UIKit
import DocumentModel
import EditorStateKit
import SchemaKit
import EditorSerialization
import EditorUIKit

@main
struct EditorDemoApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView().ignoresSafeArea(.container, edges: .horizontal)
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
]

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
            }
            .padding(8)
            Divider()
            EditorContainer(docIndex: docIndex, proseLoad: proseLoad, agentOn: agentOn) { message in
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
    /// Surfaces a human-readable message when pasted prose fails to decode.
    var onLoadError: (String) -> Void

    @MainActor final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var editor: Editor?
        weak var textView: EditorTextView?
        weak var scroll: UIScrollView?
        var currentIndex = -1
        var lastProseID = 0
        var onLoadError: ((String) -> Void)?

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
        }
        return scroll
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        let coordinator = context.coordinator
        guard let editor = coordinator.editor, let textView = coordinator.textView else { return }
        coordinator.onLoadError = onLoadError
        coordinator.setAgent(agentOn)

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
        b.p(b.n("image", ["src": .string(sampleImageDataURL()), "alt": .string("banner")])),
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

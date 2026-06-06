import SwiftUI
import UIKit
import DocumentModel
import EditorStateKit
import SchemaKit
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
    var body: some View {
        VStack(spacing: 0) {
            Picker("Document", selection: $docIndex) {
                ForEach(demoDocuments.indices, id: \.self) { i in Text(demoDocuments[i].name).tag(i) }
            }
            .pickerStyle(.segmented)
            .padding(8)
            Divider()
            EditorContainer(docIndex: docIndex)
                .ignoresSafeArea(.keyboard)
        }
    }
}

/// Hosts an `EditorTextView` inside a scroll view, virtualized: the editor view
/// is pinned to the scroll viewport (never taller than the screen) and renders
/// only the visible window, while the scroll content height is the full document
/// height. This is what lets a 500-paragraph × 500-word document render at all.
struct EditorContainer: UIViewRepresentable {
    let docIndex: Int

    @MainActor final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var editor: Editor?
        weak var textView: EditorTextView?
        weak var scroll: UIScrollView?
        var currentIndex = -1

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
        let editor = try! Editor(extensions: fullKit())
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
        guard context.coordinator.currentIndex != docIndex,
              let editor = context.coordinator.editor, let textView = context.coordinator.textView else { return }
        editor.setContent(demoDocuments[docIndex].build(editor.schema))
        context.coordinator.currentIndex = docIndex
        uiView.setContentOffset(.zero, animated: false)
        textView.contentOffsetY = 0
        DispatchQueue.main.async { context.coordinator.syncContentHeight(textView.documentHeight) }
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

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

struct ContentView: View {
    var body: some View {
        EditorContainer()
            .ignoresSafeArea(.keyboard)
    }
}

/// Hosts an `EditorTextView` inside a scroll view.
struct EditorContainer: UIViewRepresentable {
    func makeUIView(context: Context) -> UIScrollView {
        let editor = try! Editor(extensions: fullKit())
        editor.setContent(sampleDocument(editor.schema))

        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = true
        scroll.keyboardDismissMode = .interactive

        let textView = EditorTextView(editor: editor)
        textView.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            textView.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            textView.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            textView.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        ])
        DispatchQueue.main.async { _ = textView.becomeFirstResponder() }
        return scroll
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {}
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

/// Build a rich sample document using the editor's own schema instances.
func sampleDocument(_ schema: Schema) -> Node {
    func n(_ type: String, _ attrs: Attrs = [:], _ content: [Node] = []) -> Node {
        try! schema.node(type, attrs, content: Fragment.from(content))
    }
    func p(_ c: Node...) -> Node { n("paragraph", [:], c) }
    func t(_ s: String) -> Node { schema.text(s) }
    func mark(_ s: String, _ m: String) -> Node { schema.text(s, [schema.mark(m)]) }

    return n("doc", [:], [
        n("heading", ["level": .int(1)], [t("editor-swift")]),
        p(n("image", ["src": .string(sampleImageDataURL()), "alt": .string("banner")])),
        p(t("A native Swift rich-text editor — a faithful Tiptap/ProseMirror port. Try typing, "),
          mark("bold", "bold"), t(", "), mark("italic", "italic"), t(", and "), mark("code", "code"), t(".")),
        n("heading", ["level": .int(2)], [t("Lists")]),
        n("bulletList", [:], [
            n("listItem", [:], [p(t("immutable, value-typed document model"))]),
            n("listItem", [:], [p(t("transactional editing with undo/redo"))]),
            n("listItem", [:], [p(t("input rules: type "), mark("# ", "code"), t(" or "), mark("- ", "code"))]),
        ]),
        n("blockquote", [:], [p(t("All editing logic is shared; this view only renders + translates input."))]),
        p(t("Spell-check underlines a mispeled word as you type.")),
        p(t("\u{05E9}\u{05DC}\u{05D5}\u{05DD} \u{05E2}\u{05D5}\u{05DC}\u{05DD} — right-to-left text aligns from the right.")),
        n("heading", ["level": .int(2)], [t("Task list")]),
        n("taskList", [:], [
            n("taskItem", ["checked": .bool(true)], [p(t("port the ProseMirror document model"))]),
            n("taskItem", ["checked": .bool(true)], [p(t("commands, history, input rules"))]),
            n("taskItem", ["checked": .bool(false)], [p(t("tap a checkbox to toggle it"))]),
            n("taskItem", ["checked": .bool(false)], [p(t("double-click a word to select it"))]),
        ]),
        n("heading", ["level": .int(2)], [t("Wiki links & tables")]),
        p(t("See "), n("wikiLink", ["target": .string("Home"), "label": .string("the home page")]),
          t(" for more.")),
        n("table", [:], [
            n("tableRow", [:], [
                n("tableHeader", [:], [p(t("Feature"))]),
                n("tableHeader", [:], [p(t("Status"))]),
            ]),
            n("tableRow", [:], [
                n("tableCell", [:], [p(t("Marks"))]),
                n("tableCell", [:], [p(t("done"))]),
            ]),
            n("tableRow", [:], [
                n("tableCell", [:], [p(t("Tables"))]),
                n("tableCell", [:], [p(t("done"))]),
            ]),
        ]),
    ])
}

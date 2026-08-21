import SwiftUI
import UIKit
import DocumentModel
import EditorStateKit
import SchemaKit
import EditorSerialization
import EditorUIKit
import EditorSyntax
import EditorMath
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
    ("Math", mathDocument),
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
    /// Whether misspelled words are underlined (the editor's built-in checker).
    @State private var spellCheckOn = true
    /// Whether the demo installs an `onLinkClick` handler. Without one a link is
    /// inert — the click just places the caret — since the editor opens nothing
    /// on its own.
    @State private var linkClickOpensOn = false
    /// When on, swap the editable editor for the read-only `DocumentView` (the
    /// shared `DocumentLayout` renderer), seeded from the current document.
    @State private var readOnly = false
    /// The live editor (handed up from the container) so the toolbar can read
    /// the current document — e.g. to dump its prose and verify marks.
    @State private var editorRef: Editor?
    /// The serialized document shown in the "View Prose" sheet (nil = hidden).
    @State private var proseOutput: String?
    /// Live, user-editable theme (via the 🎨 Theme panel).
    @State private var themeSettings = ThemeSettings()
    @State private var showThemePanel = false

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
                Button(spellCheckOn ? "✓ Spell On" : "✓ Spell") { spellCheckOn.toggle() }
                    .buttonStyle(.bordered)
                    .tint(spellCheckOn ? .accentColor : nil)
                Button(readOnly ? "👁 Read-Only" : "✏️ Editable") { readOnly.toggle() }
                    .buttonStyle(.bordered)
                    .tint(readOnly ? .accentColor : nil)
                Button("🎨 Theme") { showThemePanel = true }
                    .buttonStyle(.bordered)
                    .popover(isPresented: $showThemePanel) {
                        ThemePanel(settings: $themeSettings, handleLinkClicks: $linkClickOpensOn,
                                   onReset: { themeSettings = ThemeSettings() })
                    }
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
            if readOnly {
                // The read-only renderer (`DocumentView` over the shared
                // `DocumentLayout`), seeded from the live document so you can see
                // the same content — including non-interactive checkboxes.
                ReadOnlyContainer(document: editorRef?.doc, themeSettings: themeSettings)
                    .ignoresSafeArea(.keyboard)
            } else {
                EditorContainer(docIndex: docIndex, proseLoad: proseLoad, agentOn: agentOn,
                                reorder: reorderOn, useDryingInk: dryingInkOn, bubbleOn: bubbleOn,
                                spellCheck: spellCheckOn, handleLinkClicks: linkClickOpensOn,
                                themeSettings: themeSettings,
                                onReady: { editorRef = $0 }) { message in
                    loadError = message
                }
                .ignoresSafeArea(.keyboard)
            }
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

// MARK: - Theme config panel

/// The editable subset of `DocumentTheme` the demo's theme panel exposes. Held as
/// SwiftUI-friendly values (`Double`, `Color`) and converted to a `DocumentTheme`
/// via `makeTheme()`. `Equatable` so the host only re-applies it on a real change.
struct ThemeSettings: Equatable {
    // Font & spacing
    var bodyFontSize: Double = 17
    // Spacing is in ems — a multiple of the body size — so it holds its
    // proportion as the size slider moves.
    var lineSpacing: Double = 0.18
    var paragraphSpacing: Double = 1.0
    var listIndent: Double = 1.6
    var fontName: String = systemFont
    // Text colors
    var textColor = Color(uiColor: .label)
    var caretColor = Color(uiColor: .tintColor)
    var selectionColor = Color(uiColor: .tintColor)
    // Headings
    var headingFontName: String = inheritFont
    var headingH1Scale: Double = 1.8
    var headingLineHeightOn = false
    var headingLineHeight: Double = 1.0
    var headingTracking: Double = 0
    var headingWeight: String = defaultWeight
    var headingAlignment: String = "Natural"
    var headingSpaceBefore: Double = 1.0
    var headingSpaceAfter: Double = 1.0
    var headingRuleOn = false
    var headingColorOn = false
    var headingColor = Color(uiColor: .label)
    // Links
    var linkColor = Color(uiColor: .link)
    var linkUnderline = true
    // Code
    var codeColor = Color(uiColor: .secondaryLabel)
    var codeBackgroundOn = false
    var codeBackground = Color(uiColor: .secondarySystemFill)
    var codeBlockBackgroundOn = false
    var codeBlockBackground = Color(uiColor: .secondarySystemBackground)
    var codeBlockPadding: Double = 0.6
    // Tables
    var tableCellPadding: Double = 0.35

    static let systemFont = "System"
    static let fontChoices = [systemFont, "Georgia", "Charter", "Palatino", "Times New Roman", "Avenir Next"]
    /// Headings can take the body face or one of their own.
    static let inheritFont = "Inherit"
    static let headingFontChoices = [inheritFont] + fontChoices
    /// "Bold" is the theme's own default when no weight is named.
    static let defaultWeight = "Bold"
    static let weightChoices: [(String, UIFont.Weight)] = [
        ("Light", .light), ("Regular", .regular), ("Medium", .medium),
        ("Semibold", .semibold), (defaultWeight, .bold), ("Heavy", .heavy),
    ]
    static let alignmentChoices: [(String, NSTextAlignment?)] = [
        ("Natural", nil), ("Left", .left), ("Center", .center), ("Right", .right),
    ]

    /// The heading face, or nil to inherit the body face (the theme's own default).
    private var headingFace: String? {
        switch headingFontName {
        case ThemeSettings.inheritFont: nil
        case ThemeSettings.systemFont: nil
        default: headingFontName
        }
    }

    /// Build the `DocumentTheme` these settings describe (keeping the demo's vivid
    /// highlighter palette). Dynamic Type is turned off so the size slider wins.
    func makeTheme() -> DocumentTheme {
        var t = DocumentTheme()
        t.dynamicType = false
        t.fixedBodyFontSize = bodyFontSize
        t.lineSpacing = Em(lineSpacing)
        t.paragraphSpacing = Em(paragraphSpacing)
        t.listIndent = Em(listIndent)
        t.fontName = (fontName == ThemeSettings.systemFont) ? nil : fontName
        t.textColor = UIColor(textColor)
        t.selection.caret = UIColor(caretColor)
        t.selection.fill = UIColor(selectionColor).withAlphaComponent(0.25)
        t.heading.fontName = headingFace
        t.heading.scale[0] = headingH1Scale
        t.heading.lineHeight = headingLineHeightOn ? headingLineHeight : nil
        t.heading.tracking = headingTracking == 0 ? nil : headingTracking
        t.heading.weight = ThemeSettings.weightChoices.first { $0.0 == headingWeight }?.1
        t.heading.alignment = ThemeSettings.alignmentChoices.first { $0.0 == headingAlignment }?.1
        t.heading.spacingBefore = Em(headingSpaceBefore)
        t.heading.spacingAfter = Em(headingSpaceAfter)
        t.heading.rule = headingRuleOn ? DocumentTheme.Heading.Rule() : nil
        t.heading.color = headingColorOn ? UIColor(headingColor) : nil
        t.link.color = UIColor(linkColor)
        t.link.underline = linkUnderline
        t.code.color = UIColor(codeColor)
        t.code.inline.background = codeBackgroundOn ? UIColor(codeBackground) : nil
        t.code.block.background = codeBlockBackgroundOn ? UIColor(codeBlockBackground) : nil
        // Padding without a background just indents the code, so it follows it.
        t.code.block.padding = codeBlockBackgroundOn ? EmInsets(Em(codeBlockPadding)) : .zero
        t.table.cellPadding = EmInsets(Em(tableCellPadding))
        t.highlighters = HighlighterMenu.themeHighlighters
        return t
    }
}

/// A small live theme editor: tweak fonts, spacing, and colors and watch the
/// editor repaint. Bound to a `ThemeSettings` the host feeds to the editor view.
struct ThemePanel: View {
    @Binding var settings: ThemeSettings
    /// Not a theme value — a view behaviour — so it rides alongside `settings`
    /// rather than inside it, and `onReset` leaves it alone.
    @Binding var handleLinkClicks: Bool
    let onReset: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Font") {
                    Picker("Face", selection: $settings.fontName) {
                        ForEach(ThemeSettings.fontChoices, id: \.self) { Text($0).tag($0) }
                    }
                    themeSlider("Body size", $settings.bodyFontSize, 11...28, unit: "pt")
                }
                Section("Spacing") {
                    themeSlider("Line", $settings.lineSpacing, 0...0.8, unit: "em", decimals: 2)
                    themeSlider("Paragraph", $settings.paragraphSpacing, 0...2, unit: "em", decimals: 2)
                    themeSlider("List indent", $settings.listIndent, 0.5...3, unit: "em", decimals: 2)
                }
                Section("Text") {
                    ColorPicker("Text", selection: $settings.textColor)
                    ColorPicker("Caret", selection: $settings.caretColor)
                    ColorPicker("Selection", selection: $settings.selectionColor)
                }
                Section("Headings") {
                    Picker("Face", selection: $settings.headingFontName) {
                        ForEach(ThemeSettings.headingFontChoices, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Weight", selection: $settings.headingWeight) {
                        ForEach(ThemeSettings.weightChoices, id: \.0) { Text($0.0).tag($0.0) }
                    }
                    Picker("Alignment", selection: $settings.headingAlignment) {
                        ForEach(ThemeSettings.alignmentChoices, id: \.0) { Text($0.0).tag($0.0) }
                    }
                    themeSlider("H1 size", $settings.headingH1Scale, 1.0...2.5, unit: "×", decimals: 2)
                    themeSlider("Tracking", $settings.headingTracking, -0.06...0.06, unit: "em", decimals: 3)
                    themeSlider("Space before", $settings.headingSpaceBefore, 0...2.5, unit: "em", decimals: 2)
                    themeSlider("Space after", $settings.headingSpaceAfter, 0...2.5, unit: "em", decimals: 2)
                    Toggle("Rule below", isOn: $settings.headingRuleOn)
                    Toggle("Custom line height", isOn: $settings.headingLineHeightOn)
                    if settings.headingLineHeightOn {
                        themeSlider("Line height", $settings.headingLineHeight, 0.8...1.8, unit: "×", decimals: 2)
                    }
                    Toggle("Custom color", isOn: $settings.headingColorOn)
                    if settings.headingColorOn {
                        ColorPicker("Heading color", selection: $settings.headingColor)
                    }
                }
                Section("Links") {
                    ColorPicker("Link color", selection: $settings.linkColor)
                    Toggle("Underline", isOn: $settings.linkUnderline)
                    Toggle("Open on click", isOn: $handleLinkClicks)
                }
                Section("Code") {
                    ColorPicker("Inline code", selection: $settings.codeColor)
                    Toggle("Background pill", isOn: $settings.codeBackgroundOn)
                    if settings.codeBackgroundOn {
                        ColorPicker("Pill color", selection: $settings.codeBackground)
                    }
                    Toggle("Block background", isOn: $settings.codeBlockBackgroundOn)
                    if settings.codeBlockBackgroundOn {
                        ColorPicker("Block color", selection: $settings.codeBlockBackground)
                        themeSlider("Block padding", $settings.codeBlockPadding, 0...1.5, unit: "em", decimals: 2)
                    }
                }
                Section("Tables") {
                    themeSlider("Cell padding", $settings.tableCellPadding, 0...1.2, unit: "em", decimals: 2)
                }
            }
            .navigationTitle("Theme")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Reset", action: onReset) } }
        }
        .frame(minWidth: 340, minHeight: 520)
    }

    private func themeSlider(_ label: String, _ value: Binding<Double>,
                             _ range: ClosedRange<Double>, unit: String = "",
                             decimals: Int = 0) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                Text("\(value.wrappedValue, specifier: "%.\(decimals)f")\(unit)")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: value, in: range)
        }
    }
}

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
    /// Whether the editor underlines misspellings.
    var spellCheck: Bool = true
    /// Whether clicking a link opens it — i.e. whether an `onLinkClick` handler
    /// is installed at all.
    var handleLinkClicks: Bool = false
    /// The live, user-editable theme from the 🎨 Theme panel.
    var themeSettings: ThemeSettings = ThemeSettings()
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
        /// The theme settings currently applied, so we only rebuild on a change.
        var lastThemeSettings = ThemeSettings()
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
        // `[[` wiki-link suggestions via the ASYNC provider — simulating a DB /
        // search-index lookup (250ms latency). The source debounces, cancels
        // superseded queries, and repaints the popup when results arrive; the `/`
        // slash menu stays synchronous (included by `fullKit`).
        let editor = try! Editor(extensions: fullKit(wikiLinkAsyncSuggestions: { query in
            try? await Task.sleep(for: .milliseconds(250)) // pretend to hit the index
            let pages = ["Home", "Getting Started", "Architecture", "ProseMirror", "Tiptap",
                         "Document Model", "Commands", "Keymap", "Schema", "Releases", "Roadmap"]
            guard !query.isEmpty else { return pages }
            return pages.filter { $0.range(of: query, options: .caseInsensitive) != nil }
        }, mentionSuggestions: { query in
            // `@` mentions from a small in-memory directory (synchronous source).
            let people = ["Ada Lovelace", "Alan Turing", "Grace Hopper", "Katherine Johnson",
                          "Margaret Hamilton", "Marijn Haverbeke", "Barbara Liskov", "Donald Knuth"]
            guard !query.isEmpty else { return people }
            return people.filter { $0.range(of: query, options: .caseInsensitive) != nil }
        }))
        editor.setContent(demoDocuments[docIndex].build(editor.schema))

        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = true
        scroll.keyboardDismissMode = .interactive
        scroll.delegate = context.coordinator

        let textView = EditorTextView(editor: editor)
        // The live theme from the 🎨 panel (its `makeTheme()` includes the vivid
        // highlighter palette below; the bubble/menu swatches use the same set).
        textView.theme = themeSettings.makeTheme()
        context.coordinator.lastThemeSettings = themeSettings
        textView.theme.highlighters = HighlighterMenu.themeHighlighters
        // Opt into code-block syntax highlighting + language badges. Highlighting
        // only affects code blocks; detection only switches when confident.
        textView.syntaxHighlighter = makeSyntaxHighlighter()
        textView.codeLanguageLabel = makeCodeLanguageLabel()
        // Opt into native LaTeX typesetting for the math nodes. Without this,
        // formulas render as their monospaced source.
        textView.mathRenderer = makeMathRenderer()
        // Tapping a formula opens a prompt for its LaTeX — the same flow
        // Tiptap's math `onClick` documentation demonstrates.
        textView.onActivateMath = { [weak textView] node, pos in
            guard let textView else { return }
            let isInline = node.type.name == "inlineMath"
            let alert = UIAlertController(title: "Edit \(isInline ? "inline " : "")equation",
                                          message: "LaTeX source", preferredStyle: .alert)
            alert.addTextField { $0.text = node.attrs["latex"]?.stringValue ?? "" }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Save", style: .default) { _ in
                guard let latex = alert.textFields?.first?.text, !latex.isEmpty else { return }
                if isInline {
                    textView.editor.updateInlineMath(latex: latex, at: pos)
                } else {
                    textView.editor.updateBlockMath(latex: latex, at: pos)
                }
            })
            textView.window?.rootViewController?.present(alert, animated: true)
        }
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
        // Keep wet strokes pinned to their text across edits, so ink mid-sweep
        // when you type elsewhere finishes drying where it was laid down.
        textView.onDocumentChange = { [weak drying] tr in drying?.map(through: tr) }
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
        // Live theme edits from the 🎨 panel — re-apply (and resync height) only
        // when something actually changed; `theme`'s didSet rebuilds the layout.
        if coordinator.lastThemeSettings != themeSettings {
            coordinator.lastThemeSettings = themeSettings
            textView.theme = themeSettings.makeTheme()
            DispatchQueue.main.async { coordinator.syncContentHeight(textView.documentHeight) }
        }
        textView.blockReorderingEnabled = reorder
        textView.spellCheckingEnabled = spellCheck
        // The editor opens nothing itself: a click is only a link click because
        // the host says what one means. This one honours https and refuses the
        // rest, and reports a wiki-link/mention by name rather than as a URL.
        textView.onLinkClick = handleLinkClicks ? { link in
            guard let url = link.url, url.scheme == "https" || url.scheme == "http" else {
                print("EditorDemo: ignoring link \(link.node.type.name) \(link.attrs)")
                return
            }
            UIApplication.shared.open(url)
        } : nil
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

/// Hosts the read-only `DocumentView` (the shared `DocumentLayout` renderer)
/// inside a scroll view, virtualized the same way as `EditorContainer`: the view
/// is pinned to the viewport and renders only the visible window, while the
/// scroll content height is the full document height. Checkboxes here use the
/// same `DefaultTaskCheckboxView` as the editor, just non-interactive.
struct ReadOnlyContainer: UIViewRepresentable {
    /// The document to display (the live editor's current doc).
    var document: Node?
    /// The live, user-editable theme from the 🎨 Theme panel.
    var themeSettings: ThemeSettings = ThemeSettings()

    @MainActor final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var documentView: DocumentView?
        weak var scroll: UIScrollView?
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            documentView?.contentOffsetY = scrollView.contentOffset.y
        }
        func syncContentHeight(_ height: CGFloat) {
            guard let scroll else { return }
            scroll.contentSize = CGSize(width: scroll.bounds.width, height: height)
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = true
        scroll.delegate = context.coordinator

        let documentView = DocumentView(document: document, theme: themeSettings.makeTheme())
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.onDocumentHeightChange = { [weak coordinator = context.coordinator] height in
            coordinator?.syncContentHeight(height)
        }
        scroll.addSubview(documentView)
        // Pinned to the viewport (frame), not the content — it stays screen-sized.
        NSLayoutConstraint.activate([
            documentView.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scroll.frameLayoutGuide.topAnchor),
            documentView.bottomAnchor.constraint(equalTo: scroll.frameLayoutGuide.bottomAnchor),
        ])
        context.coordinator.documentView = documentView
        context.coordinator.scroll = scroll
        DispatchQueue.main.async { context.coordinator.syncContentHeight(documentView.documentHeight) }
        return scroll
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        guard let documentView = context.coordinator.documentView else { return }
        documentView.theme = themeSettings.makeTheme()
        documentView.document = document
        DispatchQueue.main.async { context.coordinator.syncContentHeight(documentView.documentHeight) }
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

/// 7) LaTeX math, typeset natively by EditorMath — `blockMath` on its own row
/// and `inlineMath` within a line. Type `$x^2$` to make one, or `/equation`.
func mathDocument(_ schema: Schema) -> Node {
    let b = B(schema)
    func block(_ latex: String) -> Node { b.n("blockMath", ["latex": .string(latex)]) }
    func inline(_ latex: String) -> Node { b.n("inlineMath", ["latex": .string(latex)]) }
    return b.n("doc", [:], [
        b.heading(1, "Mathematics"),
        b.p(b.t("Formulas are stored as LaTeX and typeset natively — no web view. "),
            b.t("An inline one like "), inline("e^{i\\pi} + 1 = 0"),
            b.t(" shares the line's baseline; a block one gets its own row.")),
        b.heading(3, "Display math"),
        block("\\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}"),
        block("\\sum_{n=1}^{\\infty} \\frac{1}{n^2} = \\frac{\\pi^2}{6}"),
        block("\\int_0^\\infty e^{-x^2}\\,dx = \\frac{\\sqrt{\\pi}}{2}"),
        b.heading(3, "Matrices and cases"),
        block("\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}"),
        block("f(x) = \\begin{cases} 1 & x > 0 \\\\ 0 & x \\le 0 \\end{cases}"),
        b.heading(3, "Inline within prose"),
        b.p(b.t("Given "), inline("\\varepsilon > 0"), b.t(", choose "), inline("\\delta"),
            b.t(" so that "), inline("|f(x) - L| < \\varepsilon"), b.t(" whenever "),
            inline("0 < |x - a| < \\delta"), b.t(".")),
        b.p(b.t("Set notation ("), inline("\\mathbb{R} \\subset \\mathbb{C}"),
            b.t("), accents ("), inline("\\vec{v} \\cdot \\hat{n}"),
            b.t("), and functions ("), inline("\\sin^2\\theta + \\cos^2\\theta = 1"),
            b.t(") all work.")),
        b.heading(3, "Source that doesn't parse"),
        b.p(b.t("Invalid LaTeX is shown verbatim in the muted code color rather than mis-rendered:")),
        block("\\frac{a}"),
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

    /// (name — a `theme.highlighters` name, the swatch hue). The menu label is
    /// the highlighter's own `displayTitle`.
    static let colors: [(name: String, swatch: UIColor)] = [
        ("yellow", ink((1.00, 0.95, 0.10), (0.95, 0.85, 0.28))),
        ("green",  ink((0.40, 1.00, 0.20), (0.45, 0.92, 0.40))),
        ("blue",   ink((0.20, 0.80, 1.00), (0.35, 0.78, 1.00))),
        ("pink",   ink((1.00, 0.30, 0.65), (1.00, 0.45, 0.72))),
        ("orange", ink((1.00, 0.55, 0.10), (1.00, 0.62, 0.28))),
    ]

    /// The highlighters for `theme.highlighters` — the (dynamic) swatch hues at
    /// a translucent alpha, so flat highlights and the drying ink read as vivid
    /// in both light and dark. Menu order is `colors`' order.
    static var themeHighlighters: [DocumentTheme.Highlighter] {
        colors.map { .init(name: $0.name, background: $0.swatch.withAlphaComponent(0.55)) }
    }

    /// Builds the submenu, routing each choice through `apply` (a highlight color
    /// name, or nil to remove) so the host can also record it (e.g. drying ink).
    @MainActor
    static func items(apply: @escaping @MainActor (String?) -> Void) -> [UIMenuElement] {
        // Labels come from the highlighters themselves, so the menu and the
        // document can't drift apart; the swatch stays the vivid full-alpha hue.
        let colorActions: [UIMenuElement] = zip(colors, themeHighlighters).map { color, highlighter in
            UIAction(title: highlighter.displayTitle, image: swatch(color.swatch)) { _ in apply(color.name) }
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

/// Renders highlights as a chisel-tip highlighter on paper. Translucent dye
/// (multiply over white, additive on dark) lays down left→right at a brisk hand
/// speed and dries behind the tip. Dried ink is an even, uniform band with angled
/// (chiseled) ends, a hair of edge bleed, and a slight deterministic hand wobble —
/// low variance, the way real highlighter looks once dry. Every feel knob lives in
/// `Config`; set `drying.config` to tune timing, color, shape, wobble, or aim.
@MainActor
final class DryingInk {
    /// All the tunable "feel" parameters. Defaults are the dialed-in values; set
    /// `drying.config = …` (or mutate fields) to change how the ink behaves.
    struct Config {
        // Timing
        var tipSpeed: CGFloat = 104             // laydown speed, characters/second
        var maxSweep: CFTimeInterval = 0.3      // cap on the full sweep (long text snaps on)
        var dryDuration: CFTimeInterval = 0.6   // wet → dry settle time

        // Color / density (the mark's hue drawn translucent)
        var lightAlpha: CGFloat = 0.60          // dried opacity over a light page
        var darkAlpha: CGFloat = 0.34           // dried opacity over a dark page (additive)
        var wetBoost: CGFloat = 0.12            // extra density while still wet

        // Chisel shape
        var slantFraction: CGFloat = 0.32       // end angle as a fraction of line height…
        var slantMax: CGFloat = 4.5             // …capped at this many points
        var verticalBleed: CGFloat = 1.5        // over/under-bleed past the line (points)
        var edgeFeather: CGFloat = 0.8          // soft edge-bleed ring width (points)
        var edgeAlpha: CGFloat = 0.45           // edge ring opacity, × body

        // Hand wobble (deterministic, sub-pixel — stable, never shimmers)
        var driftAmp: CGFloat = 0.8             // slow baseline wander
        var edgeWobble: CGFloat = 0.4           // fine top/bottom edge jitter
        var endTaper: CGFloat = 0.9             // lighter pressure at the very ends

        // End aim (points): real strokes rarely land flush
        var undershoot: CGFloat = 3             // max it stops short
        var overshoot: CGFloat = 2              // max it runs past
        var undershootBias: CGFloat = 0.7       // fraction of ends that stop short
    }
    var config = Config()

    weak var textView: EditorTextView?
    var enabled = false

    private struct Stroke { let from: Int; let to: Int; let at: CFTimeInterval }
    private var strokes: [Stroke] = []
    private var link: CADisplayLink?

    /// Carry wet strokes through a document change (via `onDocumentChange`).
    ///
    /// A stroke is a range of *text*, not of positions: ink laid on "the quick
    /// fox" should keep drying over those words even if you type a paragraph
    /// above them mid-sweep. Unmapped, the recorded range would stay put while
    /// the text slid out from under it, and the tip would finish its sweep over
    /// whatever moved in.
    ///
    /// Biased outward-exclusive (`1` at the start, `-1` at the end), matching how
    /// the highlight mark itself behaves: typing at either edge falls outside the
    /// stroke, typing inside extends it. A stroke deleted out of existence is
    /// dropped. (Qualified: SwiftUI has a `Transaction` of its own.)
    func map(through tr: EditorStateKit.Transaction) {
        guard !strokes.isEmpty else { return }
        strokes = strokes.compactMap {
            let from = tr.mapping.map($0.from, 1), to = tr.mapping.map($0.to, -1)
            return from < to ? Stroke(from: from, to: to, at: $0.at) : nil
        }
        if strokes.isEmpty { link?.invalidate(); link = nil }
    }

    init(textView: EditorTextView) { self.textView = textView }

    /// How long the tip takes to cross a stroke: length / speed, capped at `maxSweep`.
    private func sweepDuration(_ s: Stroke) -> CFTimeInterval {
        min(config.maxSweep, Double(max(1, s.to - s.from)) / Double(config.tipSpeed))
    }
    /// The effective tip speed for a stroke (chars/sec), raised above `tipSpeed`
    /// when the cap kicks in so the whole stroke still lands within `maxSweep`.
    private func strokeSpeed(_ s: Stroke) -> CGFloat {
        CGFloat(max(1, s.to - s.from)) / CGFloat(sweepDuration(s))
    }

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
        // Translucent dye darkens what's under it (multiply); on a dark page that
        // collapses to invisible, so add light instead — the ink glows.
        ctx.setBlendMode(isDark ? .plusLighter : .multiply)
        for run in runs { drawInk(ctx, run, now: now) }
        ctx.restoreGState()
    }

    /// The most recent fresh stroke covering this run (nil once it has expired).
    /// Tested against the run's own line, not the whole highlight: a stroke that
    /// reaches only the first line of a wrapped highlight shouldn't wet the rest.
    private func freshStroke(for run: HighlightRun) -> Stroke? {
        var best: Stroke?
        for s in strokes where run.lineFrom < s.to && run.lineTo > s.from {
            if best == nil || s.at > best!.at { best = s }
        }
        return best
    }

    private func drawInk(_ ctx: CGContext, _ run: HighlightRun, now: CFTimeInterval) {
        // Per-position timing: the chisel sweeps left→right at a constant speed;
        // each spot is wet the instant the tip passes and dries behind it.
        var p: CGFloat = 1        // 0 = wet, 1 = dry
        var revealed: CGFloat = 1 // fraction of this run the tip has crossed
        if let s = freshStroke(for: run) {
            let elapsed = CGFloat(now - s.at)
            let speed = strokeSpeed(s)
            let penChars = elapsed * speed
            // Measured against this *line's* slice, so a wrapped highlight lays
            // down the way a hand moves — line one, then line two — rather than
            // every line fading up together on the whole highlight's clock.
            let startChar = CGFloat(run.lineFrom - s.from)
            let runChars = max(1, CGFloat(run.lineTo - run.lineFrom))
            revealed = min(1, max(0, (penChars - startChar) / runChars))
            if revealed <= 0.001 { return }                  // tip hasn't arrived yet
            let localElapsed = elapsed - startChar / speed
            p = min(1, max(0, localElapsed / CGFloat(config.dryDuration)))
        }

        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        run.color.getRed(&r, green: &g, blue: &b, alpha: &a)
        func ink(_ alpha: CGFloat) -> UIColor { UIColor(red: r, green: g, blue: b, alpha: alpha) }

        // Dry ink is an even translucent band; wet ink is only a touch denser and
        // settles to the same matte everywhere (so the dried variance is tiny).
        let alpha = (isDark ? config.darkAlpha : config.lightAlpha) + (1 - p) * config.wetBoost

        // The chisel covers the line plus a hair of vertical bleed.
        let rect = run.rect.insetBy(dx: 0, dy: -config.verticalBleed)
        // A wedge marker lays a slanted band — flat-ish top/bottom, angled ends
        // (the hallmark of a chisel tip).
        let slant = min(rect.height * config.slantFraction, config.slantMax)

        // Every random-looking part of the stroke below is keyed to this run's
        // *geometry*, never to its document positions. Geometry only moves when
        // the ink itself moves: editing earlier in the document shifts a run's
        // `from`/`to` (and its y) but not its x, so the shape a highlight dried
        // into survives typing elsewhere instead of re-rolling each keystroke.
        //
        // Quantized so two layout passes that agree to within a hair still land
        // on the same seed.
        func seed(_ x: CGFloat) -> Int { Int((x * 4).rounded()) }

        // Deterministic, sub-pixel hand wobble keyed to document x: stable across
        // frames and scroll (so it doesn't shimmer) and tiny (so dried ink still
        // reads even). 1-D value noise: smooth-interpolated hashes per cell.
        func hash01(_ n: Int) -> CGFloat {
            var x = UInt64(bitPattern: Int64(n)) &+ 0x9E3779B97F4A7C15
            x = (x ^ (x >> 30)) &* 0xBF58476D1CE4E5B9
            x = (x ^ (x >> 27)) &* 0x94D049BB133111EB
            return CGFloat((x ^ (x >> 31)) >> 40) / CGFloat(1 << 24)
        }
        func wobble(_ x: CGFloat, _ seed: Int, _ cell: CGFloat, _ amp: CGFloat) -> CGFloat {
            let t = x / cell
            let i = Int(t.rounded(.down))
            let f = t - CGFloat(i)
            let s = f * f * (3 - 2 * f) // smoothstep
            let a = hash01(i &* 1_103_515_245 &+ seed)
            let b = hash01((i &+ 1) &* 1_103_515_245 &+ seed)
            return ((a + (b - a) * s) * 2 - 1) * amp
        }

        // A hand-drawn slanted band over [x0, x1] within `box`: the top edge is
        // shifted right by `slant`, both edges wobble a touch, the very ends taper
        // (lighter pressure), and the caps bow slightly so they're not perfect lines.
        func band(_ x0: CGFloat, _ x1: CGFloat, _ box: CGRect) -> UIBezierPath {
            func drift(_ x: CGFloat) -> CGFloat { wobble(x, 11, 38, config.driftAmp) } // baseline wander
            func taper(_ x: CGFloat) -> CGFloat {                              // ends fade in/out
                let d = min(x - x0, x1 - x)
                return d >= 6 ? 0 : (6 - max(0, d)) / 6 * config.endTaper
            }
            func topY(_ x: CGFloat) -> CGFloat { box.minY + drift(x) + wobble(x, 23, 15, config.edgeWobble) + taper(x) }
            func botY(_ x: CGFloat) -> CGFloat { box.maxY + drift(x) + wobble(x, 37, 15, config.edgeWobble) - taper(x) }

            var xs: [CGFloat] = []
            var x = x0
            let step: CGFloat = 13
            while x < x1 - 0.1 { xs.append(x); x += step }
            xs.append(x1)

            let path = UIBezierPath()
            for (k, cx) in xs.enumerated() {                                   // bottom edge L→R
                let pt = CGPoint(x: cx, y: botY(cx))
                k == 0 ? path.move(to: pt) : path.addLine(to: pt)
            }
            path.addLine(to: CGPoint(x: x1 + slant * 0.5 + wobble(x1, 51, 7, config.driftAmp), // end cap, bowed
                                     y: (botY(x1) + topY(x1)) / 2))
            path.addLine(to: CGPoint(x: x1 + slant, y: topY(x1)))
            for cx in xs.reversed() { path.addLine(to: CGPoint(x: cx + slant, y: topY(cx))) } // top R→L
            path.addLine(to: CGPoint(x: x0 + slant * 0.5 + wobble(x0, 67, 7, config.driftAmp), // start cap, bowed
                                     y: (botY(x0) + topY(x0)) / 2))
            path.close()
            return path
        }

        // Real highlighting rarely lands flush: each end under- or overshoots the
        // text. Bias toward undershoot (stopping a hair short) ~70% of the time,
        // capped to ~3px under / ~2px over, keyed per end so it's stable. Keyed
        // to each end's x (not `run.from`/`run.to`, which every edit above this
        // run renumbers — that made dried ends jump on unrelated keystrokes).
        let bias = config.undershootBias
        func shoot(_ n: Int) -> CGFloat {             // + = undershoot (inset), − = overshoot
            let u = hash01(n)
            return u < bias
                ? 1 + (u / bias) * (config.undershoot - 1)
                : -(1 + (u - bias) / (1 - bias) * (config.overshoot - 1))
        }
        let leftX = run.rect.minX + shoot(seed(run.rect.minX) &* 2 &+ 1)
        let rightX = run.rect.maxX - shoot(seed(run.rect.maxX) &* 2 &+ 5)
        let penX = leftX + max(0, rightX - leftX) * revealed

        // Soft edge bleed as a ring (outer − body), even-odd so it feathers the
        // edges — including the slanted ends and tip — without double-darkening
        // the body (which overlapping multiply fills would otherwise do).
        let feather = config.edgeFeather
        let outer = rect.insetBy(dx: -feather, dy: -feather)
        let ring = band(leftX - feather, penX + feather, outer)
        ring.append(band(leftX, penX, rect))
        ring.usesEvenOddFillRule = true
        ink(alpha * config.edgeAlpha).setFill()
        ring.fill()

        // Even body — one uniform color throughout.
        ink(alpha).setFill()
        band(leftX, penX, rect).fill()
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
        strokes.removeAll { s in now - s.at > sweepDuration(s) + config.dryDuration }
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

    private func swatchButton(_ color: (name: String, swatch: UIColor),
                              _ highlighter: DocumentTheme.Highlighter) -> UIButton {
        let dot = UIButton(type: .system)
        dot.backgroundColor = color.swatch
        // A bare colored dot says nothing out loud, so the highlighter's own
        // label names it.
        dot.accessibilityLabel = highlighter.displayTitle
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
            views += zip(HighlighterMenu.colors, HighlighterMenu.themeHighlighters)
                .map { swatchButton($0, $1) }
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

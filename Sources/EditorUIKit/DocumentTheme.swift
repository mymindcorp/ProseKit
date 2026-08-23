#if canImport(UIKit)
public import UIKit
public import DocumentModel

extension UIColor {
    /// Create a color from a `#RRGGBB` (or `#RRGGBBAA`) hex string.
    /// Parse `#rgb` / `#rrggbb` / `#rrggbbaa` (with or without `#`). The single
    /// hex parser in the module — `DocumentTheme.parseColor` adds named colors on top.
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() } // #rgb → #rrggbb
        guard s.count == 6 || s.count == 8, let value = UInt64(s, radix: 16) else { return nil }
        let hasAlpha = s.count == 8
        let r = CGFloat((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = CGFloat((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = CGFloat((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? CGFloat(value & 0xFF) / 255 : 1
        self.init(red: r, green: g, blue: b, alpha: a)
    }
}

/// A length in ems — a multiple of the body font's size, the unit typography
/// has always used for space around type.
///
/// Space authored in points freezes at the size it was chosen for: enlarge the
/// text and the gaps stay put, so the page tightens exactly for the reader who
/// enlarged it to read more easily. An em scales with the text by construction.
///
/// Written as a plain number — `theme.paragraphSpacing = 0.6` — but distinct
/// from `CGFloat` so a point value can't be assigned to an em by accident.
/// Hairlines and `pageInsets` stay in points: a border answers to the device's
/// pixels and a page margin to its screen, neither to the type.
public struct Em: Sendable, Equatable, Comparable, ExpressibleByFloatLiteral {
    public var value: CGFloat
    public init(_ value: CGFloat) { self.value = value }
    public init(floatLiteral value: Double) { self.value = CGFloat(value) }
    /// The em that renders as `points` at `DocumentTheme.referenceBodySize` —
    /// for porting a value that was authored in points.
    public static func points(_ points: CGFloat) -> Em {
        Em(points / DocumentTheme.referenceBodySize)
    }
    public static func < (a: Em, b: Em) -> Bool { a.value < b.value }
    public static func + (a: Em, b: Em) -> Em { Em(a.value + b.value) }
}

/// Insets in ems — `Em`'s counterpart to `UIEdgeInsets`.
public struct EmInsets: Sendable, Equatable {
    public var top: Em, left: Em, bottom: Em, right: Em
    public static let zero = EmInsets(0.0)
    public init(top: Em, left: Em, bottom: Em, right: Em) {
        self.top = top; self.left = left; self.bottom = bottom; self.right = right
    }
    /// The same inset on all four sides.
    public init(_ all: Em) { self.init(top: all, left: all, bottom: all, right: all) }
}

/// Visual styling for a rendered document: fonts, colors, and block spacing.
/// The layout engine reads this to build attributed strings and position
/// blocks. Shared by the editable `EditorTextView` and the read-only
/// `DocumentView` — hence "document" rather than "editor"; the editor's own
/// chrome (find bar, popups) just borrows colors from it.
public struct DocumentTheme: Sendable, Equatable {
    /// When true, fonts track the user's Dynamic Type content-size setting.
    public var dynamicType: Bool = true
    /// The base body point size used when `dynamicType` is off.
    public var fixedBodyFontSize: CGFloat = 17
    /// A custom font face name for body text (e.g. "Georgia", "Charter").
    /// When nil, the system font is used.
    public var fontName: String?
    /// The effective body point size (drives caret vertical movement).
    public var baseFontSize: CGFloat { bodyFont.pointSize }
    public var textColor: UIColor = .label
    /// The hairline shared by every 1pt rule and border: table cells, `hr`, an
    /// image placeholder's box, an unchecked checkbox's outline, and the
    /// editor's own chrome (find bar, popups). A blockquote's bar can follow it
    /// or set its own — see `quote`.
    public var hairlineColor: UIColor = .separator

    public struct Link: Sendable, Equatable {
        public var color: UIColor = .link
        /// Whether link text is underlined. Off gives color-only links.
        public var underline = true
        public init() {}
    }
    public var link = Link()

    /// A `[[wiki-link]]`: an inline atom naming something in the host's own
    /// store. Plain themed text by default, which is what it has always been;
    /// set `background` to draw it as a chip, and give the view a
    /// `wikiLinkIcon` to put the target's own glyph inside one.
    public struct WikiLink: Sendable, Equatable {
        /// nil = `link.color`, so a wiki-link follows ordinary links unless a
        /// theme says otherwise.
        public var color: UIColor?
        /// The chip behind the label. nil (the default) draws none.
        public var background: UIColor?
        /// Reserved *inside* the atom's own advance rather than added around it,
        /// so neighbouring text can't sit under the chip.
        public var paddingX: Em = 0.35
        /// Vertical only — it overhangs the line the way an inline-code pill does.
        public var paddingY: Em = 0.1
        public var cornerRadius: Em = 0.4
        /// The square box a `wikiLinkIcon` glyph is drawn into, and the gap
        /// between it and the label. The box is reserved whether or not the host
        /// answers with an image, so a late icon repaints without re-measuring.
        public var iconSize: Em = 0.9
        public var iconGap: Em = 0.2
        /// Underlining a chip is one decoration too many, so this does not
        /// follow `link.underline` unless a theme opts in.
        public var underline = false
        public init() {}
    }
    public var wikiLink = WikiLink()

    /// Code: the face and color both forms share, then what distinguishes a
    /// run inside a sentence from a block standing on its own.
    public struct Code: Sendable, Equatable {
        /// A custom monospaced face (e.g. "Menlo", "Courier"). When nil, the
        /// system monospaced font is used.
        public var fontName: String?
        public var color: UIColor = .secondaryLabel

        /// A `code` run inside a line of prose: the pill drawn behind it.
        public struct Inline: Sendable, Equatable {
            /// Background pill behind the run. On by default — an inline code
            /// run is set in the same size as the prose around it, so without a
            /// pill it reads as ordinary text in a slightly different face.
            /// A fill rather than a fixed grey, so it adapts to light and dark
            /// and sits on whatever the document's background is. Set nil for
            /// no pill.
            public var background: UIColor? = .secondarySystemFill
            /// How far the pill extends past the text it wraps.
            public var paddingX: Em = 0.12
            public var paddingY: Em = 0.06
            public var cornerRadius: Em = 0.25
            public init() {}
        }
        public var inline = Inline()

        /// A fenced code block.
        public struct Block: Sendable, Equatable {
            /// Text color inside the block. nil = the document's `textColor`,
            /// which is what a block has always used — unlike an inline run,
            /// which quiets down to `code.color` to sit inside a sentence.
            public var color: UIColor?
            /// Background behind the whole block (nil = none, the default —
            /// code has always been set apart by its face alone here).
            public var background: UIColor?
            /// Inset between the background's edge and the code. Zero by
            /// default, so a block sits where it always has; set it along with
            /// `background`, which otherwise hugs the text.
            public var padding = EmInsets.zero
            public var cornerRadius: Em = 0.35
            public init() {}
        }
        public var block = Block()
        public init() {}
    }
    public var code = Code()

    /// Tables: how much air a cell gives its content, and the grid around it.
    public struct Table: Sendable, Equatable {
        /// Space between a cell's border and its content.
        public var cellPadding = EmInsets(0.35)
        /// The shortest a row may be, whatever it holds — an empty row still
        /// needs to be tappable.
        public var minimumRowHeight: Em = 1.65
        /// nil = `hairlineColor`.
        public var borderColor: UIColor?
        public var borderWidth: CGFloat = 1
        /// Gap below the table, before whatever follows it.
        public var spacingAfter: Em = 0.35
        public init() {}
    }
    public var table = Table()

    /// Blockquotes: the bar down their left edge, and how far it pushes them in.
    public struct Quote: Sendable, Equatable {
        /// nil = `hairlineColor`, so a theme that sets one hairline gets a
        /// matching bar without naming it twice.
        public var barColor: UIColor?
        public var barWidth: CGFloat = 3
        /// How far a quote's content is indented past the bar.
        public var indent: Em = 0.95
        public init() {}
    }
    public var quote = Quote()

    /// The `hr` between sections: the line itself and the air around it.
    ///
    /// This is a block that stands on its own, so its spacing is *added to* the
    /// gap `spacing(before:after:)` already put above it. `heading.rule` is the
    /// other kind of rule — one that hugs the text above it rather than
    /// standing apart from it.
    public struct HorizontalRule: Sendable, Equatable {
        /// nil = `hairlineColor`.
        public var color: UIColor?
        public var thickness: CGFloat = 1
        public var spacingBefore: Em = 0.5
        public var spacingAfter: Em = 0.5
        /// How far each end pulls in from the content column — 0 draws the full
        /// width, a large inset gives the short centred rule print uses to break
        /// a scene rather than a section.
        public var inset: Em = 0.0
        public init() {}
    }
    public var horizontalRule = HorizontalRule()

    /// The caret and the selection behind it.
    public struct Selection: Sendable, Equatable {
        public var caret: UIColor = .tintColor
        public var fill: UIColor = UIColor.tintColor.withAlphaComponent(0.25)
        public init() {}
    }
    public var selection = Selection()

    /// The blockquote bar's color: its own if it names one, else the shared
    /// hairline.
    public var quoteBarColor: UIColor { quote.barColor ?? hairlineColor }

    /// Headings: their size ramp, face, weight, leading, tracking, alignment,
    /// spacing, color, and optional rule. Everything a host needs to make h1–h6
    /// read differently from body text without restyling the whole document.
    ///
    /// Each property styles all six levels; `levels` overrides any of them for
    /// one level, so the common case stays a single assignment.
    public struct Heading: Sendable, Equatable {
        /// A hairline under a heading — the rule markdown stylesheets
        /// conventionally put under h1 and h2.
        public struct Rule: Sendable, Equatable {
            /// nil = `hairlineColor`, the theme's shared rule color.
            public var color: UIColor?
            public var thickness: CGFloat = 1
            /// Gap between the heading's last line and the rule.
            public var spacing: Em = 0.25
            public init() {}
            public init(color: UIColor? = nil, thickness: CGFloat = 1, spacing: Em = 0.25) {
                self.color = color; self.thickness = thickness; self.spacing = spacing
            }
        }

        /// One level's overrides. Anything left nil falls back to the
        /// heading-wide property of the same name.
        public struct Level: Sendable, Equatable {
            public var fontName: String?
            public var weight: UIFont.Weight?
            public var color: UIColor?
            public var lineHeight: CGFloat?
            public var tracking: CGFloat?
            public var alignment: NSTextAlignment?
            public var spacingBefore: Em?
            public var spacingAfter: Em?
            public var rule: Rule?
            public init() {}
        }

        /// A level's settled style: its override where it has one, else the
        /// heading-wide value. What the layout engine actually reads.
        public struct Resolved: Sendable, Equatable {
            public var scale: CGFloat
            public var fontName: String?
            public var weight: UIFont.Weight?
            public var color: UIColor?
            public var lineHeight: CGFloat?
            public var tracking: CGFloat?
            public var alignment: NSTextAlignment?
            public var spacingBefore: Em?
            public var spacingAfter: Em?
            public var rule: Rule?
        }

        /// Point sizes as multiples of the body size, for levels 1…6.
        ///
        /// Applied when a custom face is set (`fontName` here or on the theme)
        /// or when `dynamicType` is off. With Dynamic Type on *and* the system
        /// font, headings map to `textStyles` so they scale with the user's
        /// setting, and this ramp is not consulted.
        public var scale: [CGFloat] = [1.8, 1.5, 1.25, 1.1, 1.0, 0.9]
        /// A custom face for headings only (e.g. "Georgia" headings over a
        /// system-font body). When nil, headings inherit the theme's `fontName`.
        public var fontName: String?
        /// Stroke weight. When nil, headings are bold — the long-standing
        /// default. Set it for the lighter display faces that bold ruins.
        public var weight: UIFont.Weight?
        /// Line height as a multiple of the heading font's natural line height —
        /// 1.0 sets the lines solid, below that tightens them. Large type looks
        /// loose at body leading, so headings usually want less. When nil, they
        /// use the document's `lineSpacing` like any other block.
        public var lineHeight: CGFloat?
        /// Letter spacing as a fraction of the font's point size, the unit type
        /// designers use (an em). Negative tightens, which is what display sizes
        /// nearly always want. nil = the face's own spacing.
        public var tracking: CGFloat?
        /// Paragraph alignment (nil = natural, following the writing direction).
        public var alignment: NSTextAlignment?
        /// Space above a heading (nil = the document's `paragraphSpacing`).
        public var spacingBefore: Em?
        /// Space below a heading (nil = the document's `paragraphSpacing`).
        /// A heading usually wants more air above than below, so it binds to the
        /// text it introduces rather than floating between two blocks.
        public var spacingAfter: Em?
        /// A hairline under the heading (nil = none).
        public var rule: Rule?
        /// Override color for heading text (nil = inherit `textColor`).
        ///
        /// Applied to h2–h6: an h1 is the document's title and keeps `textColor`
        /// unless `levels[1]` names a color of its own.
        public var color: UIColor?
        /// The Dynamic Type styles levels 1…6 map to when no custom face is set.
        /// The ramp descends, so h4–h6 stay distinguishable — h4 and h5 shared
        /// `.headline` before this was configurable and rendered identically.
        public var textStyles: [UIFont.TextStyle] = [
            .title1, .title2, .title3, .headline, .callout, .subheadline,
        ]
        /// Per-level overrides, keyed by level (1…6).
        public var levels: [Int: Level] = [:]
        public init() {}

        /// The size multiple for `level`, clamped to 1…6 and tolerant of a
        /// `scale` array a host left short (missing levels stay at body size).
        public func scale(forLevel level: Int) -> CGFloat {
            let index = Heading.clamp(level) - 1
            return index < scale.count ? scale[index] : 1
        }

        /// The Dynamic Type style for `level`, tolerant of a short array.
        public func textStyle(forLevel level: Int) -> UIFont.TextStyle {
            let index = Heading.clamp(level) - 1
            return index < textStyles.count ? textStyles[index] : .headline
        }

        /// `level`'s settled style.
        public func resolved(forLevel level: Int) -> Resolved {
            let level = Heading.clamp(level)
            let o = levels[level]
            return Resolved(
                scale: scale(forLevel: level),
                fontName: o?.fontName ?? fontName,
                weight: o?.weight ?? weight,
                // The heading-wide color skips the h1 title; a level's own
                // color is an explicit instruction, so it applies anywhere.
                color: o?.color ?? (level > 1 ? color : nil),
                lineHeight: o?.lineHeight ?? lineHeight,
                tracking: o?.tracking ?? tracking,
                alignment: o?.alignment ?? alignment,
                spacingBefore: o?.spacingBefore ?? spacingBefore,
                spacingAfter: o?.spacingAfter ?? spacingAfter,
                rule: o?.rule ?? rule)
        }

        /// `node`'s settled style, or nil if it isn't a heading — the form the
        /// layout engine wants, since it asks about arbitrary blocks.
        public func resolved(for node: Node) -> Resolved? {
            guard node.type.name == "heading" else { return nil }
            return resolved(forLevel: Heading.level(of: node))
        }

        /// A heading node's level, clamped to 1…6.
        public static func level(of node: Node) -> Int {
            clamp(node.attrs["level"]?.intValue ?? 1)
        }

        private static func clamp(_ level: Int) -> Int { min(max(level, 1), 6) }
    }
    public var heading = Heading()

    /// A figure's caption: smaller and quieter than body text, and centred under
    /// what it describes, which is the convention print and the web share.
    public struct Caption: Sendable, Equatable {
        public var color: UIColor = .secondaryLabel
        /// Caption size relative to body text, used when Dynamic Type is off or
        /// a custom face is set (Dynamic Type maps to `.footnote` instead).
        public var scale: CGFloat = 0.85
        public var alignment: NSTextAlignment = .center
        /// Gap between a figure's content and its caption.
        public var spacing: Em = 0.25
        public init() {}
    }
    public var caption = Caption()

    /// Pictures: how an `image` is drawn, wherever it sits — as a block, inline
    /// in a paragraph, or inside a figure.
    public struct Image: Sendable, Equatable {
        /// Corner radius of the drawn picture, in points. 0 (the default) draws
        /// the square corners the bytes came with.
        ///
        /// Points rather than ems: a picture's box is measured in points and
        /// doesn't grow with the type, so a radius in ems would round harder
        /// every time the reader enlarged the text. Clamped at draw time to half
        /// the shorter side, so a large value gives a capsule rather than an
        /// undefined path.
        ///
        /// The placeholder box drawn while the bytes load takes the same radius,
        /// so nothing changes shape when the picture arrives.
        public var cornerRadius: CGFloat = 0
        public init() {}
    }
    public var image = Image()

    /// Task items: how a *checked* item's text reads, and the checkbox's own
    /// colors. Both text options are off by default, so a checked item looks
    /// like any other line until a host opts in.
    public struct TaskItem: Sendable, Equatable {
        /// Strike through the text of a checked item (Tiptap's `[data-checked]`
        /// line-through, which we can't express in CSS).
        public var strikethroughWhenChecked = false
        /// Text color for a checked item (nil = inherit `textColor`). Marks that
        /// set their own color still win, as they do over every base color.
        public var checkedTextColor: UIColor?
        /// Fill of a checked checkbox (nil = `selection.caret`).
        public var checkboxTint: UIColor?
        /// Outline of an unchecked checkbox (nil = `hairlineColor`).
        public var checkboxBorderColor: UIColor?
        public init() {}
    }
    public var taskItem = TaskItem()

    /// One named highlighter: what it paints, in each appearance.
    ///
    /// `name` is what a highlight mark stores in its `color` attribute, so it
    /// travels with the document — renaming one orphans existing marks, which
    /// then fall back to the default highlighter.
    public struct Highlighter: Sendable, Equatable {
        /// The ink for one appearance.
        public struct Style: Sendable, Equatable {
            public var background: UIColor
            /// Text color inside the highlight. nil leaves the run's own color,
            /// which is what a translucent highlighter wants; set it when the
            /// background is opaque enough to swallow the text.
            public var text: UIColor?
            public init(background: UIColor, text: UIColor? = nil) {
                self.background = background
                self.text = text
            }
        }
        public var name: String
        /// Menu label. nil is the common case — see `displayTitle`. Set it for a
        /// localized label, or a name the document stores that doesn't read as
        /// one ("brand-2").
        public var title: String?
        public var light: Style
        public var dark: Style

        public init(name: String, title: String? = nil, light: Style, dark: Style) {
            self.name = name; self.title = title; self.light = light; self.dark = dark
        }
        /// A highlighter that paints the same in both appearances — the right
        /// initializer when the colors are already dynamic (a system color, or
        /// one built with `UIColor(dynamicProvider:)`).
        public init(name: String, title: String? = nil, background: UIColor, text: UIColor? = nil) {
            let style = Style(background: background, text: text)
            self.init(name: name, title: title, light: style, dark: style)
        }

        /// What to label this highlighter in a menu: its `title`, else its name
        /// capitalized — which is already right for the color words a stock
        /// palette uses, so most themes never set a title at all.
        public var displayTitle: String { title ?? name.capitalized }

        /// The background as one appearance-resolving color.
        public var background: UIColor {
            Highlighter.dynamic(light.background, dark.background)
        }
        /// The text color, or nil if neither appearance names one. A color given
        /// for just one appearance is used in both — a host that sets a single
        /// value means it, and the alternative is a run whose color changes with
        /// the appearance for no stated reason.
        public var textColor: UIColor? {
            guard let light = light.text ?? dark.text,
                  let dark = dark.text ?? self.light.text else { return nil }
            return Highlighter.dynamic(light, dark)
        }

        private static func dynamic(_ light: UIColor, _ dark: UIColor) -> UIColor {
            guard light != dark else { return light }
            return UIColor { $0.userInterfaceStyle == .dark ? dark : light }
        }
    }

    /// The highlighters a document can use, in menu order. The first is the
    /// default — what a highlight mark gets when it names no color, or names one
    /// this theme doesn't have.
    ///
    /// The stock set is tuned with alpha rather than an explicit text color, so
    /// dark text stays legible over it in both appearances.
    public var highlighters: [Highlighter] = [
        Highlighter(name: "yellow", background: UIColor.systemYellow.withAlphaComponent(0.40)),
        Highlighter(name: "green", background: UIColor.systemGreen.withAlphaComponent(0.35)),
        Highlighter(name: "blue", background: UIColor.systemBlue.withAlphaComponent(0.30)),
        Highlighter(name: "pink", background: UIColor.systemPink.withAlphaComponent(0.30)),
        Highlighter(name: "orange", background: UIColor.systemOrange.withAlphaComponent(0.35)),
        Highlighter(name: "purple", background: UIColor.systemPurple.withAlphaComponent(0.30)),
    ]

    /// The highlighter a mark's `color` name refers to, falling back to the
    /// first one. nil only when a theme has no highlighters at all.
    public func highlighter(_ name: String?) -> Highlighter? {
        if let name, let match = highlighters.first(where: { $0.name == name }) { return match }
        return highlighters.first
    }

    /// The background painted behind a highlight mark with the given name.
    public func highlightColor(_ name: String?) -> UIColor {
        highlighter(name)?.background ?? UIColor.systemYellow.withAlphaComponent(0.40)
    }

    /// The text color inside a highlight mark with the given name, if its
    /// highlighter sets one.
    public func highlightTextColor(_ name: String?) -> UIColor? {
        highlighter(name)?.textColor
    }

    /// Background of the suggestion popup (slash menu / wiki-link menu).
    public var popupBackground: UIColor = .secondarySystemBackground
    public var pageInsets = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
    /// Gap between blocks — a whole em, matching the margin every browser puts
    /// on a `<p>`.
    ///
    /// CSS states that margin twice, above and below, and collapses adjacent
    /// ones to the larger; `spacing(before:after:)` collapses the same way, so
    /// one em stated once lands in the same place.
    public var paragraphSpacing: Em = 1.0
    /// Extra leading added to every line.
    public var lineSpacing: Em = 0.18
    /// The gutter a list's markers sit in. It has to hold the widest marker —
    /// a task checkbox is sized from the text's cap height — plus
    /// `listMarkerGap`, which is why 1.6 rather than the 1.4 it once was.
    public var listIndent: Em = 1.6
    /// Gap between a list marker (or checkbox) and the text it labels.
    public var listMarkerGap: Em = 0.45

    public init() {}

    /// The body size an em-authored theme reads as: `Em.points(10)` is the em
    /// that renders as 10pt here. Only a porting aid — nothing renders at this
    /// size unless the body happens to be it.
    public static let referenceBodySize: CGFloat = 17

    /// `em` resolved against the body size actually in use.
    public func points(_ em: Em) -> CGFloat { em.value * bodyPointSize }

    /// `insets` resolved against the body size actually in use.
    public func points(_ insets: EmInsets) -> UIEdgeInsets {
        UIEdgeInsets(top: points(insets.top), left: points(insets.left),
                     bottom: points(insets.bottom), right: points(insets.right))
    }

    /// The body point size (Dynamic Type scaled, or fixed).
    private var bodyPointSize: CGFloat {
        dynamicType ? UIFont.preferredFont(forTextStyle: .body).pointSize : fixedBodyFontSize
    }

    /// The base (body) font — custom face if configured, else the system font.
    public var bodyFont: UIFont {
        if let fontName, let custom = UIFont(name: fontName, size: bodyPointSize) { return custom }
        return dynamicType ? UIFont.preferredFont(forTextStyle: .body) : UIFont.systemFont(ofSize: fixedBodyFontSize)
    }

    public var monoFont: UIFont {
        let size = bodyPointSize - 1
        if let fontName = code.fontName, let custom = UIFont(name: fontName, size: size) { return custom }
        return UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// `font` at `weight`, or bolded when no weight is asked for — the shape
    /// every heading branch needs. A face without the requested weight keeps its
    /// own, which is why the descriptor result is optional.
    private static func weighted(_ font: UIFont, _ weight: UIFont.Weight?) -> UIFont {
        guard let weight else {
            let descriptor = font.fontDescriptor.withSymbolicTraits(.traitBold) ?? font.fontDescriptor
            return UIFont(descriptor: descriptor, size: font.pointSize)
        }
        let descriptor = font.fontDescriptor.addingAttributes(
            [.traits: [UIFontDescriptor.TraitKey.weight: weight]])
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }

    /// The font for a block node (heading sizes, code blocks, etc.).
    public func blockFont(_ node: Node) -> UIFont {
        switch node.type.name {
        case "heading":
            let style = heading.resolved(for: node) ?? heading.resolved(forLevel: 1)
            let size = bodyPointSize * style.scale
            // A custom face — the heading's own, else the document's — scaled by
            // the level's multiple. An unavailable face falls through to the next
            // candidate rather than dropping straight to the system font, so a
            // bad `heading.fontName` still tracks the body face.
            for name in [style.fontName, fontName].compactMap({ $0 }) {
                guard let custom = UIFont(name: name, size: size) else { continue }
                return DocumentTheme.weighted(custom, style.weight)
            }
            // System font: prefer the matching Dynamic Type text style.
            if dynamicType {
                let level = Heading.level(of: node)
                let font = UIFont.preferredFont(forTextStyle: heading.textStyle(forLevel: level))
                return DocumentTheme.weighted(font, style.weight)
            }
            return UIFont.systemFont(ofSize: size, weight: style.weight ?? .bold)
        case "codeBlock":
            return monoFont
        case "figcaption":
            if let fontName, let custom = UIFont(name: fontName, size: bodyPointSize * caption.scale) {
                return custom
            }
            if dynamicType { return UIFont.preferredFont(forTextStyle: .footnote) }
            return UIFont.systemFont(ofSize: fixedBodyFontSize * caption.scale)
        case "detailsSummary":
            // The always-visible title of a collapsible section reads as a label.
            let descriptor = bodyFont.fontDescriptor.withSymbolicTraits(.traitBold) ?? bodyFont.fontDescriptor
            return UIFont(descriptor: descriptor, size: bodyFont.pointSize)
        default:
            return bodyFont
        }
    }

    /// The gap between `previous` and `node`. `previous` is nil for the first
    /// block in its container, which opens flush against the container's top.
    ///
    /// Where both sides ask for a gap — a heading's `spacingAfter` meeting the
    /// next heading's `spacingBefore` — they collapse to the larger, so a
    /// heading between two blocks doesn't stack two full gaps. A side that says
    /// nothing doesn't count as asking for `paragraphSpacing`, so an explicitly
    /// *tighter* heading still reads as tight.
    public func spacing(before node: Node, after previous: Node?) -> CGFloat {
        guard let previous else { return 0 }
        // A caption belongs to what sits above it, so it tucks up close rather
        // than floating a full paragraph away.
        if node.type.name == "figcaption" { return points(caption.spacing) }
        let before = heading.resolved(for: node)?.spacingBefore
        let after = heading.resolved(for: previous)?.spacingAfter
        switch (before, after) {
        case (nil, nil): return points(paragraphSpacing)
        case let (value?, nil), let (nil, value?): return points(value)
        case let (before?, after?): return points(max(before, after))
        }
    }

    /// A block's paragraph alignment, or nil to follow the writing direction.
    public func alignment(for node: Node) -> NSTextAlignment? {
        if node.type.name == "figcaption" { return caption.alignment }
        return heading.resolved(for: node)?.alignment
    }

    /// The height of one laid-out line of `node`, given the line's natural
    /// height (its typographic ascent + descent + leading).
    ///
    /// Body text adds `lineSpacing` as extra leading; a heading with its own
    /// `lineHeight` multiplies instead, because at display sizes the leading
    /// that suits body text reads as a gap.
    public func lineHeight(for node: Node, naturalHeight: CGFloat) -> CGFloat {
        if let multiple = heading.resolved(for: node)?.lineHeight {
            return naturalHeight * multiple
        }
        return naturalHeight + points(lineSpacing)
    }

    /// Apply inline marks to a font + attribute dictionary. `baseColor` overrides
    /// the default text color for this run (e.g. heading text); marks that set
    /// their own color (code/link/textColor) still win over it. `tracking` is
    /// letter spacing as a fraction of the font's point size.
    public func attributes(for marks: [Mark], baseFont: UIFont,
                           baseColor: UIColor? = nil,
                           tracking: CGFloat? = nil) -> [NSAttributedString.Key: Any] {
        var font = baseFont
        var traits = font.fontDescriptor.symbolicTraits
        var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: baseColor ?? textColor]
        var sizeScale: CGFloat = 1
        var baselineOffset: CGFloat = 0

        for mark in marks {
            switch mark.type.name {
            case "bold": traits.insert(.traitBold)
            case "italic": traits.insert(.traitItalic)
            case "code":
                font = monoFont
                attrs[.foregroundColor] = code.color
            case "strike":
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            case "underline":
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            case "link":
                attrs[.foregroundColor] = link.color
                if link.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            case "textColor":
                if let color = DocumentTheme.parseColor(mark.attrs["color"]?.stringValue) {
                    attrs[.foregroundColor] = color
                }
            // backgroundColor is painted behind the run by DocumentLayout (CoreText
            // ignores .backgroundColor), so it's not applied here.
            case "subscript":
                sizeScale = 0.75; baselineOffset = -baseFont.pointSize * 0.2
            case "superscript":
                sizeScale = 0.75; baselineOffset = baseFont.pointSize * 0.35
            default: break
            }
        }
        if sizeScale != 1 { font = font.withSize(font.pointSize * sizeScale) }
        if baselineOffset != 0 { attrs[.baselineOffset] = baselineOffset }
        if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
            font = UIFont(descriptor: descriptor, size: font.pointSize)
        }
        // A highlighter's own text color is the last word: it was picked against
        // the background about to be painted behind this run, so it outranks a
        // `textColor` mark that knows nothing about that background.
        if let highlight = marks.first(where: { $0.type.name == "highlight" }),
           let color = highlightTextColor(highlight.attrs["color"]?.stringValue) {
            attrs[.foregroundColor] = color
        }
        // Tracking is an em fraction, so it follows the run's settled size.
        if let tracking, tracking != 0 { attrs[.kern] = font.pointSize * tracking }
        attrs[.font] = font
        return attrs
    }

    /// Parse a CSS color string — a common named color, or `#rgb`/`#rrggbb`/
    /// `#rrggbbaa` (with or without `#`) — into a UIColor. nil if unparseable.
    public static func parseColor(_ string: String?) -> UIColor? {
        guard let s = string?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if let named = namedColors[s.lowercased()] { return named }
        return UIColor(hex: s)
    }

    private static let namedColors: [String: UIColor] = [
        "black": .black, "white": .white, "red": .red, "green": .green, "blue": .blue,
        "yellow": .yellow, "orange": .orange, "purple": .purple, "gray": .gray, "grey": .gray,
        "brown": .brown, "cyan": .cyan, "magenta": .magenta, "clear": .clear,
    ]
}
#endif

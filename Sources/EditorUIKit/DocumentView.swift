#if canImport(UIKit)
import UIKit
import DocumentModel

/// A lightweight, **read-only** view that renders a document with the shared
/// layout engine and **only draws the visible window**.
///
/// Pin it to a scroll view's viewport and feed `contentOffsetY` to virtualize an
/// arbitrarily tall document (the same technique the editable `EditorTextView`
/// uses), or drop it in at its full `documentHeight` for short documents. Either
/// way, `draw(_:)` only paints the slice `[contentOffsetY, contentOffsetY +
/// bounds.height]`, so cost is independent of document length.
public final class DocumentView: UIView {
    /// The document to render. Setting it rebuilds the layout (incrementally,
    /// reusing unchanged blocks from the previous layout).
    public var document: Node? { didSet { invalidateLayout() } }
    /// Visual styling (fonts, colors, spacing).
    public var theme: TextTheme { didSet { invalidateLayout() } }
    /// The enclosing viewport's vertical scroll offset. Only the slice
    /// `[contentOffsetY, contentOffsetY + bounds.height]` is drawn.
    public var contentOffsetY: CGFloat = 0 { didSet { if oldValue != contentOffsetY { setNeedsDisplay() } } }
    /// Reports the rendered document height when it changes (size the scroll content from this).
    public var onDocumentHeightChange: ((CGFloat) -> Void)?
    /// Resolves image `src`s to images (data:, file:, or pre-cached). Optional.
    public var imageProvider: ((String) -> UIImage?)?

    private var layout: DocumentLayout?
    private var layoutWidth: CGFloat = 0
    private let blockCache = TextBlockLayoutCache()
    private var lastReportedHeight: CGFloat = -1

    public init(document: Node? = nil, theme: TextTheme = TextTheme()) {
        self.document = document
        self.theme = theme
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Discard the cached layout and redraw.
    public func invalidateLayout() {
        layout = nil
        setNeedsDisplay()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        if layoutWidth != bounds.width { layout = nil; setNeedsDisplay() }
    }

    /// The cached layout for the current document + width, rebuilding if needed.
    @discardableResult
    func ensureLayout() -> DocumentLayout? {
        guard let document else { return nil }
        if let layout, layoutWidth == bounds.width { return layout }
        let l = DocumentLayout(doc: document, width: max(bounds.width, 1), theme: theme,
                               imageProvider: { [weak self] src in self?.imageProvider?(src) },
                               blockCache: blockCache, previous: layout)
        layout = l
        layoutWidth = bounds.width
        if l.height != lastReportedHeight {
            lastReportedHeight = l.height
            onDocumentHeightChange?(l.height)
        }
        return l
    }

    /// The full height of the rendered document (use it to size scroll content).
    public var documentHeight: CGFloat { ensureLayout()?.height ?? 0 }

    public override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: documentHeight)
    }

    public override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        render(into: ctx, height: bounds.height, offsetY: contentOffsetY)
    }

    /// Render this document's **visible window** into an arbitrary context —
    /// another view's `draw(_:)`, a bitmap, a PDF page. The slice starting at
    /// `offsetY` is translated to the top of the target and only blocks
    /// intersecting `[offsetY, offsetY + height]` are drawn (the rest is culled).
    public func render(into ctx: CGContext, height: CGFloat, offsetY: CGFloat) {
        guard let l = ensureLayout() else { return }
        ctx.saveGState()
        ctx.translateBy(x: 0, y: -offsetY)
        l.draw(in: ctx, clipY: offsetY ... (offsetY + max(height, 1)))
        ctx.restoreGState()
    }
}
#endif

#if canImport(UIKit)
import UIKit

/// A popup list shown near the caret for suggestions (the `/` slash menu, the
/// `[[` wiki-link menu, `@` mentions). A rounded card of rich rows — leading
/// icon, title, optional subtitle — with a highlighted index navigable by
/// keyboard, scrolling when the list is long, and tap-to-choose. Its look is
/// `DocumentTheme.suggestionMenu`; rows in more than one section get headers.
final class SuggestionPopupView: UIView {
    struct Item: Equatable {
        let title: String
        let subtitle: String?
        let icon: String?
        var section: String? = nil
    }

    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private var rowViews: [RowView] = []
    /// The section headers on screen, in order. (For tests/inspection.)
    private(set) var sectionHeaders: [String] = []
    private(set) var items: [Item] = []
    private let theme: DocumentTheme
    private var style: DocumentTheme.SuggestionMenu { theme.suggestionMenu }

    /// Invoked when a row is chosen (on touch-down; see `touchesBegan`).
    var onSelect: ((Int) -> Void)?

    var selectedIndex = 0 { didSet { updateHighlight(); scrollToSelection() } }
    var selected: Int? { items.indices.contains(selectedIndex) ? selectedIndex : nil }

    init(theme: DocumentTheme) {
        self.theme = theme
        super.init(frame: .zero)
        let style = theme.suggestionMenu
        backgroundColor = theme.popupBackground
        layer.cornerRadius = style.cornerRadius
        layer.cornerCurve = .continuous
        layer.borderWidth = 0.5
        layer.borderColor = (style.borderColor ?? theme.hairlineColor.withAlphaComponent(0.35)).cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = style.shadowOpacity
        layer.shadowRadius = style.shadowRadius
        layer.shadowOffset = CGSize(width: 0, height: 6)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsVerticalScrollIndicator = true
        scroll.alwaysBounceVertical = false
        // The card floats over the window, often across its safe area; insetting
        // for that would push the rows down out of the height measured for them.
        scroll.contentInsetAdjustmentBehavior = .never
        addSubview(scroll)
        stack.axis = .vertical
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Replace the rows. Resets the highlight to the first item.
    func setItems(_ items: [Item]) {
        guard items != self.items else { return }
        self.items = items
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rowViews = []
        sectionHeaders = []
        let headed = style.showsSectionHeaders && Set(items.map(\.section)).count > 1
        var section: String?? = .none
        for item in items {
            if headed, item.section != section, let title = item.section {
                sectionHeaders.append(title)
                stack.addArrangedSubview(SectionHeaderView(title: title, theme: theme))
            }
            section = item.section
            let row = RowView(item: item, theme: theme)
            stack.addArrangedSubview(row)
            rowViews.append(row)
        }
        selectedIndex = 0
        updateHighlight()
    }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + items.count) % items.count
    }

    /// The card size for the current items: tall enough for `maxVisibleRows`
    /// rows and the headers among them, then scrolling.
    func fittingSize() -> CGSize {
        let width = style.width
        var height: CGFloat = 0, rows = 0, views = 0
        for view in stack.arrangedSubviews {
            // Stop at the first row past the cap — or the header that leads it.
            guard rows < max(1, style.maxVisibleRows) else { break }
            if view is RowView { rows += 1 }
            height += view.systemLayoutSizeFitting(
                CGSize(width: width, height: 0),
                withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
            views += 1
        }
        if views == 0 { height = 36; views = 1 }
        return CGSize(width: width, height: height + CGFloat(views - 1) * stack.spacing + 10)
    }

    /// The rows wholly inside the card's visible area. For tests/inspection.
    var fullyVisibleTitles: [String] {
        layoutIfNeeded()
        let visible = CGRect(origin: scroll.contentOffset, size: scroll.bounds.size)
            .insetBy(dx: 0, dy: -0.5) // allow for rounding
        return zip(items, rowViews).compactMap { item, row in
            let frame = row.convert(row.bounds, to: scroll)
            return visible.contains(frame) ? item.title : nil
        }
    }

    private func updateHighlight() {
        for (i, row) in rowViews.enumerated() { row.setHighlighted(i == selectedIndex) }
    }

    private func scrollToSelection() {
        guard rowViews.indices.contains(selectedIndex) else { return }
        layoutIfNeeded()
        // Bring a section's header into view along with its first row.
        let row = rowViews[selectedIndex]
        var frame = row.frame
        if let index = stack.arrangedSubviews.firstIndex(of: row), index > 0,
           let header = stack.arrangedSubviews[index - 1] as? SectionHeaderView {
            frame = frame.union(header.frame)
        }
        scroll.scrollRectToVisible(frame, animated: false)
    }

    // Select on touch-DOWN, not a tap recognizer: the editor's UITextInteraction
    // tap (which fires on touch-up) would move the caret first and tear down the
    // popup before a tap-based selection could apply.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let point = touches.first?.location(in: stack) else { return }
        for (i, row) in rowViews.enumerated() where row.frame.minY <= point.y && point.y <= row.frame.maxY {
            selectedIndex = i
            onSelect?(i)
            return
        }
    }

    /// An SF Symbol by name, else an image from the app's asset catalog
    /// fitted to the same box, else a plain dot.
    static func icon(_ name: String?, pointSize: CGFloat) -> UIImage? {
        let symbol = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        if let name, let image = UIImage(systemName: name) { return image.withConfiguration(symbol) }
        if let name, let image = UIImage(named: name) {
            let side = pointSize * 1.2
            let scale = min(side / max(image.size.width, 1), side / max(image.size.height, 1))
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            return UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
                .withRenderingMode(image.renderingMode)
        }
        return UIImage(systemName: "circle.fill")?.withConfiguration(symbol)
    }

    override var intrinsicContentSize: CGSize { CGSize(width: style.width, height: UIView.noIntrinsicMetric) }

    // MARK: - Section header

    private final class SectionHeaderView: UIView {
        init(title: String, theme: DocumentTheme) {
            super.init(frame: .zero)
            let style = theme.suggestionMenu
            let label = UILabel()
            label.text = title
            label.font = style.sectionHeaderFont ?? .systemFont(ofSize: max(11, theme.bodyFont.pointSize - 5), weight: .semibold)
            label.textColor = style.sectionHeaderColor ?? .secondaryLabel
            label.translatesAutoresizingMaskIntoConstraints = false
            accessibilityTraits = .header
            isAccessibilityElement = true
            accessibilityLabel = title
            addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
                label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            ])
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    }

    // MARK: - Row

    private final class RowView: UIView {
        private let iconView = UIImageView()
        private let titleLabel = UILabel()
        private let subtitleLabel = UILabel()
        private let highlight = UIView()
        private let theme: DocumentTheme

        init(item: Item, theme: DocumentTheme) {
            self.theme = theme
            super.init(frame: .zero)
            let style = theme.suggestionMenu

            highlight.backgroundColor = style.highlightColor ?? theme.selection.caret.withAlphaComponent(0.14)
            highlight.layer.cornerRadius = style.highlightCornerRadius
            highlight.layer.cornerCurve = .continuous
            highlight.isHidden = true
            highlight.translatesAutoresizingMaskIntoConstraints = false
            addSubview(highlight)

            iconView.contentMode = .scaleAspectFit
            iconView.tintColor = style.iconColor ?? theme.selection.caret
            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.image = SuggestionPopupView.icon(item.icon, pointSize: style.iconSize)
            iconView.setContentHuggingPriority(.required, for: .horizontal)
            iconView.isHidden = !style.showsIcons

            titleLabel.text = item.title
            titleLabel.font = style.titleFont ?? .systemFont(ofSize: theme.bodyFont.pointSize, weight: .medium)
            titleLabel.textColor = style.titleColor ?? theme.textColor
            titleLabel.translatesAutoresizingMaskIntoConstraints = false

            subtitleLabel.text = item.subtitle
            subtitleLabel.font = style.subtitleFont ?? .systemFont(ofSize: max(11, theme.bodyFont.pointSize - 4))
            subtitleLabel.textColor = style.subtitleColor ?? theme.code.color
            subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

            let showsSubtitle = style.showsSubtitles && item.subtitle != nil
            let text = UIStackView(arrangedSubviews: showsSubtitle ? [titleLabel, subtitleLabel] : [titleLabel])
            text.axis = .vertical
            text.spacing = 1
            text.translatesAutoresizingMaskIntoConstraints = false

            addSubview(iconView)
            addSubview(text)
            // Without an icon, the text takes the icon's place at the leading edge.
            let textLeading = style.showsIcons
                ? text.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10)
                : text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14)
            NSLayoutConstraint.activate([
                highlight.topAnchor.constraint(equalTo: topAnchor, constant: 1),
                highlight.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
                highlight.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
                highlight.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),

                iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
                iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: max(20, style.iconSize + 5)),
                iconView.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor),

                textLeading,
                text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
                text.topAnchor.constraint(equalTo: topAnchor, constant: style.rowVerticalPadding),
                text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -style.rowVerticalPadding),
            ])
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }


        func setHighlighted(_ on: Bool) { highlight.isHidden = !on }
    }
}
#endif

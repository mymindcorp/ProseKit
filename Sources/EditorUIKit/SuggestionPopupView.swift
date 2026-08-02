#if canImport(UIKit)
import UIKit

/// A popup list shown near the caret for suggestions (the `/` slash menu, the
/// `[[` wiki-link menu, `@` mentions). A rounded card of rich rows — leading
/// icon, title, optional subtitle — with a highlighted index navigable by
/// keyboard, scrolling when the list is long, and tap-to-choose.
final class SuggestionPopupView: UIView {
    struct Item: Equatable {
        var title: String
        var subtitle: String?
        var icon: String?
    }

    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private var rowViews: [RowView] = []
    private(set) var items: [Item] = []
    private let theme: DocumentTheme

    /// Card width and the maximum number of rows shown before scrolling.
    private let width: CGFloat = 280
    private let maxVisibleRows = 7

    /// Invoked when a row is chosen (by tap).
    var onSelect: ((Int) -> Void)?

    var selectedIndex = 0 { didSet { updateHighlight(); scrollToSelection() } }
    var selected: Int? { items.indices.contains(selectedIndex) ? selectedIndex : nil }

    init(theme: DocumentTheme) {
        self.theme = theme
        super.init(frame: .zero)
        backgroundColor = theme.popupBackground
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        layer.borderWidth = 0.5
        layer.borderColor = theme.quoteBarColor.withAlphaComponent(0.35).cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.20
        layer.shadowRadius = 16
        layer.shadowOffset = CGSize(width: 0, height: 6)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsVerticalScrollIndicator = true
        scroll.alwaysBounceVertical = false
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
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = items.map { item in
            let row = RowView(item: item, theme: theme)
            stack.addArrangedSubview(row)
            return row
        }
        selectedIndex = 0
        updateHighlight()
    }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + items.count) % items.count
    }

    /// The card size for the current items (height capped to `maxVisibleRows`).
    func fittingSize() -> CGSize {
        let rowHeight = rowViews.first?.systemLayoutSizeFitting(
            CGSize(width: width, height: 0),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height ?? 36
        let rows = CGFloat(min(max(items.count, 1), maxVisibleRows))
        let spacing = max(0, rows - 1) * stack.spacing
        return CGSize(width: width, height: rows * rowHeight + spacing + 10)
    }

    private func updateHighlight() {
        for (i, row) in rowViews.enumerated() { row.setHighlighted(i == selectedIndex) }
    }

    private func scrollToSelection() {
        guard rowViews.indices.contains(selectedIndex) else { return }
        layoutIfNeeded()
        scroll.scrollRectToVisible(rowViews[selectedIndex].frame, animated: false)
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

    override var intrinsicContentSize: CGSize { CGSize(width: width, height: UIView.noIntrinsicMetric) }

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

            highlight.backgroundColor = theme.caretColor.withAlphaComponent(0.14)
            highlight.layer.cornerRadius = 7
            highlight.layer.cornerCurve = .continuous
            highlight.isHidden = true
            highlight.translatesAutoresizingMaskIntoConstraints = false
            addSubview(highlight)

            iconView.contentMode = .scaleAspectFit
            iconView.tintColor = theme.caretColor
            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.image = UIImage(systemName: item.icon ?? "circle.fill")?
                .withConfiguration(UIImage.SymbolConfiguration(pointSize: 15, weight: .regular))
            iconView.setContentHuggingPriority(.required, for: .horizontal)

            titleLabel.text = item.title
            titleLabel.font = .systemFont(ofSize: theme.bodyFont.pointSize, weight: .medium)
            titleLabel.textColor = theme.textColor
            titleLabel.translatesAutoresizingMaskIntoConstraints = false

            subtitleLabel.text = item.subtitle
            subtitleLabel.font = .systemFont(ofSize: max(11, theme.bodyFont.pointSize - 4))
            subtitleLabel.textColor = theme.codeColor
            subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

            let text = UIStackView(arrangedSubviews: item.subtitle == nil ? [titleLabel] : [titleLabel, subtitleLabel])
            text.axis = .vertical
            text.spacing = 1
            text.translatesAutoresizingMaskIntoConstraints = false

            addSubview(iconView)
            addSubview(text)
            NSLayoutConstraint.activate([
                highlight.topAnchor.constraint(equalTo: topAnchor, constant: 1),
                highlight.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
                highlight.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
                highlight.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),

                iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
                iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: 20),

                text.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
                text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
                text.topAnchor.constraint(equalTo: topAnchor, constant: 7),
                text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            ])
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        func setHighlighted(_ on: Bool) { highlight.isHidden = !on }
    }
}
#endif

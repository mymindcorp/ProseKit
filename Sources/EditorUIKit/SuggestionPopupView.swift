#if canImport(UIKit)
import UIKit

/// A lightweight popup list shown near the caret for suggestions (the `/` slash
/// menu and the `[[` wiki-link menu). Renders a rounded card of rows, tracks a
/// highlighted index navigable by keyboard, and reports taps.
final class SuggestionPopupView: UIView {
    private let stack = UIStackView()
    private var rowViews: [UIView] = []
    private(set) var items: [String] = []
    private let theme: TextTheme

    /// Invoked when a row is chosen (by tap).
    var onSelect: ((Int) -> Void)?

    var selectedIndex = 0 { didSet { updateHighlight() } }
    var selected: Int? { items.indices.contains(selectedIndex) ? selectedIndex : nil }

    init(theme: TextTheme) {
        self.theme = theme
        super.init(frame: .zero)
        backgroundColor = theme.popupBackground
        layer.cornerRadius = 10
        layer.borderWidth = 0.5
        layer.borderColor = theme.quoteBarColor.withAlphaComponent(0.4).cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: 4)

        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Replace the rows. Resets the highlight to the first item.
    func setItems(_ items: [String]) {
        guard items != self.items else { return }
        self.items = items
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = items.map { makeRow($0) }
        rowViews.forEach { stack.addArrangedSubview($0) }
        selectedIndex = 0
        invalidateIntrinsicContentSize()
    }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + items.count) % items.count
    }

    private func makeRow(_ title: String) -> UIView {
        let label = UILabel()
        label.text = title
        label.font = theme.bodyFont
        label.textColor = theme.textColor
        label.translatesAutoresizingMaskIntoConstraints = false
        let row = UIView()
        row.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: row.topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -6),
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
        ])
        return row
    }

    private func updateHighlight() {
        for (i, row) in rowViews.enumerated() {
            row.backgroundColor = (i == selectedIndex) ? theme.selectionColor : .clear
        }
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

    override var intrinsicContentSize: CGSize {
        CGSize(width: 260, height: UIView.noIntrinsicMetric)
    }
}
#endif

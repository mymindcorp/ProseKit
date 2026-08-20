#if canImport(UIKit)
import UIKit

/// A find / replace bar that drives the editor's search API. The renderer shows
/// it on ⌘F; it reports actions via closures and displays the match count.
final class FindBarView: UIView, UITextFieldDelegate {
    let queryField = UITextField()
    let replaceField = UITextField()
    private let countLabel = UILabel()

    var onQueryChange: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onReplace: (() -> Void)?
    var onReplaceAll: (() -> Void)?
    var onClose: (() -> Void)?

    init(theme: DocumentTheme) {
        super.init(frame: .zero)
        backgroundColor = theme.popupBackground
        layer.cornerRadius = 10
        layer.borderWidth = 0.5
        layer.borderColor = theme.hairlineColor.cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.15
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 2)

        configure(queryField, placeholder: "Find")
        configure(replaceField, placeholder: "Replace")
        queryField.addTarget(self, action: #selector(queryChanged), for: .editingChanged)
        queryField.delegate = self
        replaceField.delegate = self

        countLabel.font = .systemFont(ofSize: 12, weight: .regular)
        countLabel.textColor = theme.code.color
        countLabel.textAlignment = .center
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        setCount(current: -1, total: 0)

        let stack = UIStackView(arrangedSubviews: [
            queryField, countLabel,
            button("chevron.up", #selector(previousTapped)),
            button("chevron.down", #selector(nextTapped)),
            separator(theme),
            replaceField,
            textButton("Replace", #selector(replaceTapped)),
            textButton("All", #selector(replaceAllTapped)),
            button("xmark", #selector(closeTapped)),
        ])
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            queryField.widthAnchor.constraint(equalToConstant: 160),
            replaceField.widthAnchor.constraint(equalToConstant: 140),
            countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Update the "current/total" indicator. `current` is a 0-based index, or < 0
    /// when no match is selected yet.
    func setCount(current: Int, total: Int) {
        countLabel.text = total == 0 ? "0/0" : "\(max(current, 0) + 1)/\(total)"
    }

    private func configure(_ field: UITextField, placeholder: String) {
        field.placeholder = placeholder
        field.borderStyle = .roundedRect
        field.font = .systemFont(ofSize: 13)
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.clearButtonMode = .whileEditing
        field.returnKeyType = .search
    }

    private func separator(_ theme: DocumentTheme) -> UIView {
        let v = UIView()
        v.backgroundColor = theme.hairlineColor
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return v
    }

    private func button(_ systemName: String, _ action: Selector) -> UIButton {
        let b = UIButton(type: .system)
        b.setImage(UIImage(systemName: systemName), for: .normal)
        b.addTarget(self, action: action, for: .touchUpInside)
        return b
    }

    private func textButton(_ title: String, _ action: Selector) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 13)
        b.addTarget(self, action: action, for: .touchUpInside)
        return b
    }

    @objc private func queryChanged() { onQueryChange?(queryField.text ?? "") }
    @objc private func nextTapped() { onNext?() }
    @objc private func previousTapped() { onPrevious?() }
    @objc private func replaceTapped() { onReplace?() }
    @objc private func replaceAllTapped() { onReplaceAll?() }
    @objc private func closeTapped() { onClose?() }

    // Return finds next (or replaces, from the replace field) without giving up
    // focus; Escape closes. Available while a field is first responder via the
    // responder chain.
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === replaceField { onReplace?() } else { onNext?() }
        return false
    }

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(closeTapped))]
    }
}
#endif

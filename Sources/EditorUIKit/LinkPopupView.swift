#if canImport(UIKit)
import UIKit

/// A small popover for adding/editing a link: a URL field with Apply, plus a
/// Remove button when editing an existing link. Shown near the selection; its
/// field takes first responder (the editor keeps its model selection, which the
/// caller captured to apply against on submit).
final class LinkPopupView: UIView, UITextFieldDelegate {
    private let field = UITextField()
    private let theme: DocumentTheme

    /// The entered URL (empty string means "remove the link").
    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?

    init(theme: DocumentTheme, initialURL: String?, showRemove: Bool) {
        self.theme = theme
        super.init(frame: .zero)
        backgroundColor = theme.popupBackground
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous
        layer.borderWidth = 0.5
        layer.borderColor = theme.quoteBarColor.withAlphaComponent(0.35).cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.20
        layer.shadowRadius = 16
        layer.shadowOffset = CGSize(width: 0, height: 6)

        let globe = UIImageView(image: UIImage(systemName: "link"))
        globe.tintColor = theme.codeColor
        globe.contentMode = .scaleAspectFit
        globe.setContentHuggingPriority(.required, for: .horizontal)

        field.placeholder = "https://example.com"
        field.text = initialURL
        field.font = theme.bodyFont
        field.textColor = theme.textColor
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.keyboardType = .URL
        field.returnKeyType = .done
        field.clearButtonMode = .whileEditing
        field.delegate = self
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let apply = UIButton(type: .system)
        apply.setImage(UIImage(systemName: "checkmark.circle.fill"), for: .normal)
        apply.tintColor = theme.caretColor
        apply.addTarget(self, action: #selector(applyTapped), for: .touchUpInside)
        apply.setContentHuggingPriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [globe, field, apply])
        if showRemove {
            let remove = UIButton(type: .system)
            remove.setImage(UIImage(systemName: "trash"), for: .normal)
            remove.tintColor = .systemRed
            remove.addTarget(self, action: #selector(removeTapped), for: .touchUpInside)
            remove.setContentHuggingPriority(.required, for: .horizontal)
            row.addArrangedSubview(remove)
        }
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func focus() { field.becomeFirstResponder() }

    @objc private func applyTapped() { submit() }
    @objc private func removeTapped() { onSubmit?("") }

    private func submit() {
        let raw = field.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.isEmpty { onCancel?(); return }
        // Bare domains get an https scheme, matching the autolink rule.
        let url = (raw.contains("://") || raw.hasPrefix("mailto:")) ? raw : "https://" + raw
        onSubmit?(url)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        submit()
        return true
    }

    override var intrinsicContentSize: CGSize { CGSize(width: 320, height: UIView.noIntrinsicMetric) }
}
#endif

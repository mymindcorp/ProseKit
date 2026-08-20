#if canImport(UIKit)
public import UIKit

/// The contract for a task-item checkbox view. The editor positions and
/// recycles these as task items scroll into view, sets `isChecked` to reflect
/// the document, and invokes `onToggle` when the user activates the control
/// (the editor then writes the new `checked` attribute back through a
/// transaction, which flows back as an `isChecked` update).
///
/// The frame you are given is the checkbox's *touch* rect, which is padded well
/// past the box the reader sees — it is sized to the text beside it and then
/// grown for the finger. Draw inside `bounds`, not to its edges;
/// `DefaultTaskCheckboxView` centres a circle in it, which is the size the
/// layout intends.
///
/// Supply your own via `EditorTextView.checkboxViewProvider`; when none is set
/// the editor uses `DefaultTaskCheckboxView`.
public protocol TaskCheckboxView: UIView {
    /// The current checked state. Set by the editor to sync with the document;
    /// implementations must update silently (no toggle animation) on set, since
    /// it also fires during scrolling and recycling.
    var isChecked: Bool { get set }
    /// Called when the user activates the checkbox. The editor commits the
    /// change; do not mutate `isChecked` yourself in response.
    var onToggle: (() -> Void)? { get set }
    /// The editor hands over the current theme on every sync, so a custom
    /// checkbox can follow `taskItem.checkboxTint`, `checkboxBorderColor`, or
    /// anything else it wants from the theme — including after the host swaps
    /// the theme at runtime. Called often; do nothing if nothing changed.
    ///
    /// Optional: the default implementation ignores it.
    func apply(_ theme: DocumentTheme)
}

public extension TaskCheckboxView {
    func apply(_ theme: DocumentTheme) {}
}

/// The built-in checkbox: a circle in both states (the platform task idiom) —
/// a filled accent circle with a white check when checked, a soft outline
/// circle when not — with a check-on animation and a pointer hover highlight.
public final class DefaultTaskCheckboxView: UIView, TaskCheckboxView {
    public var onToggle: (() -> Void)?

    /// Colors come from the editor's theme. Re-applied on every sync, so the
    /// setter earns its keep by ignoring an unchanged theme.
    public var theme = DocumentTheme() {
        didSet { guard theme != oldValue else { return }; updateColors() }
    }

    public func apply(_ theme: DocumentTheme) { self.theme = theme }

    public var isChecked: Bool = false {
        didSet { guard isChecked != oldValue else { return }; applyState() }
    }

    private let fillLayer = CAShapeLayer()
    private let strokeLayer = CAShapeLayer()
    private let checkLayer = CAShapeLayer()

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        strokeLayer.fillColor = nil
        strokeLayer.lineWidth = 1.5
        checkLayer.fillColor = nil
        checkLayer.lineWidth = 2
        checkLayer.lineCap = .round
        checkLayer.lineJoin = .round
        checkLayer.strokeColor = UIColor.white.cgColor
        for l in [fillLayer, strokeLayer, checkLayer] { layer.addSublayer(l) }

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
        addInteraction(UIPointerInteraction(delegate: self))
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "Task"
        updateColors()
        applyState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The drawn circle, centered in the (touch-padded) frame.
    private var circleRect: CGRect {
        let side = max(8, min(bounds.width, bounds.height) - 14)
        return CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        Self.withoutImplicitAnimations {
            for l in [fillLayer, strokeLayer, checkLayer] { l.frame = bounds }
            let circle = circleRect
            fillLayer.path = UIBezierPath(ovalIn: circle).cgPath
            strokeLayer.path = UIBezierPath(ovalIn: circle.insetBy(dx: 0.75, dy: 0.75)).cgPath
            checkLayer.path = DocumentLayout.checkmarkPath(in: circle).cgPath
        }
        applyState()
    }

    /// Layer-property changes (state sync, repositioning during recycling)
    /// must be instant — only the explicit check-on transition animates.
    /// Otherwise CALayer's default actions fade every `isHidden`/`path` change,
    /// which flashes the whole row when views are reassigned (delete, scroll).
    private static func withoutImplicitAnimations(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    private func updateColors() {
        fillLayer.fillColor = (theme.taskItem.checkboxTint ?? theme.selection.caret).cgColor
        strokeLayer.strokeColor = (theme.taskItem.checkboxBorderColor ?? theme.hairlineColor).cgColor
    }

    /// Set the static (non-animated) visual state for `isChecked`.
    private func applyState() {
        Self.withoutImplicitAnimations {
            fillLayer.isHidden = !isChecked
            checkLayer.isHidden = !isChecked
            strokeLayer.isHidden = isChecked
        }
        accessibilityValue = isChecked ? "Checked" : "Unchecked"
    }

    @objc private func handleTap() {
        // Optimistic check-on animation; uncheck is instant (system behavior).
        // The authoritative state arrives via `isChecked` once the editor
        // commits the toggle.
        if !isChecked, unsafe !UIAccessibility.isReduceMotionEnabled { playCheckOn() }
        onToggle?()
    }

    private func playCheckOn() {
        Self.withoutImplicitAnimations {
            fillLayer.isHidden = false
            checkLayer.isHidden = false
            strokeLayer.isHidden = true
        }

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.4
        scale.toValue = 1.0
        scale.duration = 0.16
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fillLayer.add(scale, forKey: "checkOnScale")

        let stroke = CABasicAnimation(keyPath: "strokeEnd")
        stroke.fromValue = 0.0
        stroke.toValue = 1.0
        stroke.duration = 0.14
        stroke.beginTime = CACurrentMediaTime() + 0.08
        stroke.fillMode = .backwards
        stroke.timingFunction = CAMediaTimingFunction(name: .easeOut)
        checkLayer.add(stroke, forKey: "checkOnStroke")
    }
}

extension DefaultTaskCheckboxView: UIPointerInteractionDelegate {
    public func pointerInteraction(_ interaction: UIPointerInteraction,
                                   regionFor request: UIPointerRegionRequest,
                                   defaultRegion: UIPointerRegion) -> UIPointerRegion? {
        // Only the circle is interactive (the frame is touch-padded).
        return circleRect.insetBy(dx: -4, dy: -4).contains(request.location)
            ? UIPointerRegion(rect: circleRect.insetBy(dx: -3, dy: -3)) : nil
    }

    public func pointerInteraction(_ interaction: UIPointerInteraction,
                                   styleFor region: UIPointerRegion) -> UIPointerStyle? {
        // A circular hover highlight — the "clickable" affordance.
        return UIPointerStyle(shape: .roundedRect(region.rect, radius: region.rect.height / 2))
    }
}
#endif

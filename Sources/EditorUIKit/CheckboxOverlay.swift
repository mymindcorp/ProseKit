#if canImport(UIKit)
import UIKit

/// Positions and recycles task-item checkbox views over a host view, given the
/// checkbox rects produced by `DocumentLayout`. Shared by the editable
/// `EditorTextView` (interactive — taps toggle the document) and the read-only
/// `DocumentView` (non-interactive — checkboxes render but don't respond), so
/// both configure the checkbox the same way (`checkboxViewProvider`) and get the
/// same default look.
///
/// Views are reused IN ORDER: the i-th visible checkbox keeps the i-th active
/// view across syncs, so a toggle touches only the toggled view and a deleted
/// row shifts the rest up by one rather than recreating them. Combined with the
/// checkbox view's instant (non-animated) state updates, neither flashes the row.
@MainActor
final class CheckboxOverlay {
    /// Supplies the view for each checkbox; nil uses `DefaultTaskCheckboxView`.
    var provider: CheckboxViewProvider?
    /// Theme applied to freshly made default checkbox views.
    var theme = DocumentTheme()
    /// Invoked when a checkbox is activated, with the task item's document
    /// position. Leave nil to make the checkboxes non-interactive (read-only):
    /// they render and sync their checked state but ignore taps.
    var onToggle: ((Int) -> Void)?

    private unowned let host: UIView
    private var active: [(pos: Int, view: any TaskCheckboxView)] = []
    private var pool: [any TaskCheckboxView] = []

    init(host: UIView) { self.host = host }

    private func makeView() -> any TaskCheckboxView {
        provider?() ?? DefaultTaskCheckboxView(frame: .zero)
    }

    /// Position a recycled view over every checkbox visible in the window
    /// `[offsetY, offsetY + viewportHeight]` (padded), syncing its checked state
    /// and toggle action. Off-screen views are parked in a small reuse pool.
    /// `attached` is whether the host is in a window — when it's detached with
    /// nothing active and no checkboxes, syncing is skipped entirely.
    func sync(_ checkboxes: [(rect: CGRect, pos: Int, checked: Bool)],
              offsetY: CGFloat, viewportHeight: CGFloat, attached: Bool) {
        guard attached || !active.isEmpty || !checkboxes.isEmpty else { return }
        let lo = offsetY - 60, hi = offsetY + max(viewportHeight, 1) + 60
        let visible = checkboxes.filter { $0.rect.maxY >= lo && $0.rect.minY <= hi }
        let interactive = onToggle != nil

        var newActive: [(pos: Int, view: any TaskCheckboxView)] = []
        for (i, box) in visible.enumerated() {
            let view: any TaskCheckboxView = i < active.count
                ? active[i].view
                : (pool.popLast() ?? makeView())
            if view.superview !== host { host.addSubview(view) }
            view.isHidden = false
            view.frame = box.rect.offsetBy(dx: 0, dy: -offsetY)
            view.isChecked = box.checked // silent sync (setter is a no-op if unchanged)
            // Themed here rather than at construction: a host can swap the theme
            // at any time, and these views outlive any single layout.
            view.apply(theme)
            let pos = box.pos
            view.onToggle = onToggle.map { toggle in { toggle(pos) } }
            // Read-only checkboxes (no toggle handler) ignore taps and pointer.
            view.isUserInteractionEnabled = interactive
            newActive.append((pos, view))
        }
        // Park the surplus views (fewer items than before).
        if active.count > visible.count {
            for entry in active[visible.count...] {
                entry.view.isHidden = true
                if pool.count < 12 { pool.append(entry.view) } else { entry.view.removeFromSuperview() }
            }
        }
        active = newActive
    }

    /// Remove all checkbox views (e.g. when the provider changes).
    func discard() {
        for entry in active { entry.view.removeFromSuperview() }
        for view in pool { view.removeFromSuperview() }
        active.removeAll()
        pool.removeAll()
    }
}
#endif

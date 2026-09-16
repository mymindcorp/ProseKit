#if canImport(UIKit)
import UIKit

/// A pointer press is a selection gesture immediately. Waiting for a pan's
/// movement threshold lets native caret/drag gestures claim slow click-drags.
/// Touch input and command/control/option clicks remain native interactions.
@MainActor
class MouseSelectionRecognizer: UIGestureRecognizer {
    var anchorAtPoint: ((CGPoint) -> Int?)?
    private(set) var anchor: Int?
    private(set) var pressPoint = CGPoint.zero
    private(set) var currentPoint = CGPoint.zero
    private(set) var clickCount = 1
    private(set) var extendsSelection = false

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .possible, touches.count == 1, let touch = touches.first,
              touch.type == .indirectPointer, event.buttonMask == .primary,
              event.modifierFlags.intersection([.control, .alternate, .command]).isEmpty,
              let position = anchorAtPoint?(touch.location(in: view)) else {
            state = .failed
            return
        }
        anchor = position
        pressPoint = touch.location(in: view)
        currentPoint = pressPoint
        clickCount = touch.tapCount
        extendsSelection = event.modifierFlags.contains(.shift)
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .began || state == .changed, let touch = touches.first else { return }
        currentPoint = touch.location(in: view)
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .began || state == .changed else { return }
        if let touch = touches.first { currentPoint = touch.location(in: view) }
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .cancelled
    }

    override func reset() {
        super.reset()
        anchor = nil
        clickCount = 1
        extendsSelection = false
    }
}
#endif

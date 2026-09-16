#if canImport(UIKit)
import UIKit

/// Own plain pointer drags from press through release. Native text interaction
/// still owns clicks, multi-clicks, modified clicks, and touch selection.
@MainActor
class MouseSelectionRecognizer: UIPanGestureRecognizer {
    var anchorAtPoint: ((CGPoint) -> Int?)?
    private(set) var anchor: Int?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard touches.count == 1, let touch = touches.first,
              touch.type == .indirectPointer, touch.tapCount == 1,
              event.buttonMask == .primary,
              event.modifierFlags.intersection([.shift, .control, .alternate, .command]).isEmpty,
              let position = anchorAtPoint?(touch.location(in: view)) else {
            state = .failed
            return
        }
        // Save the document position now, before recognition's movement
        // threshold or selection scrolling can change the hit-test geometry.
        anchor = position
    }

    override func reset() {
        super.reset()
        anchor = nil
    }
}
#endif

import AppKit
import SwiftUI

/// Only the header starts a native window drag. Content and header buttons keep
/// their normal click behaviour.
struct PanelDragRegion: NSViewRepresentable {
    let began: () -> Void
    let ended: (Bool) -> Void

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {
        view.began = began
        view.ended = ended
        view.toolTip = "Drag to move SneakPeek. Reset position from the menu bar."
    }

    final class DragView: NSView {
        var began: (() -> Void)?
        var ended: ((Bool) -> Void)?

        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            began?()
            let origin = window.frame.origin
            window.performDrag(with: event)
            let moved = hypot(window.frame.minX - origin.x, window.frame.minY - origin.y) > 2
            ended?(moved)
        }
    }
}

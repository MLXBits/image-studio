import AppKit

enum EventLocationHitTest {
    /// Flips a window-space point (AppKit, bottom-left origin) into SwiftUI `.global`
    /// space (top-left origin) for a window content area of the given height.
    static func globalPoint(windowPoint: CGPoint, contentHeight: CGFloat) -> CGPoint {
        CGPoint(x: windowPoint.x, y: contentHeight - windowPoint.y)
    }

    /// The event's location in SwiftUI `.global` space when it falls inside `frame`
    /// (also in `.global` space); nil when the pointer is outside it.
    static func globalPoint(of event: NSEvent, inside frame: CGRect) -> CGPoint? {
        guard let contentView = (event.window ?? NSApp.keyWindow)?.contentView else { return nil }
        let point = globalPoint(windowPoint: event.locationInWindow, contentHeight: contentView.bounds.height)
        return frame.contains(point) ? point : nil
    }
}

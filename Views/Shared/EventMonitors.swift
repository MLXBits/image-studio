import AppKit

/// The local event monitors an image viewer installs while it is on screen:
/// its keys, and scroll and pinch turned into zoom. Hold one in `@State`,
/// install in `onAppear` and call ``removeAll()`` in `onDisappear`.
final class EventMonitors {
    /// A pinch's magnification, or a trackpad or mouse-wheel scroll; nil for a
    /// purely horizontal scroll, which is left to the views beneath.
    private static func zoomFactor(of event: NSEvent) -> CGFloat? {
        if event.type == .magnify {
            return 1 + event.magnification
        }
        guard event.scrollingDeltaY != 0 else { return nil }
        return ScrollZoom.factor(deltaY: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas)
    }

    private var tokens: [Any] = []

    /// False until the first monitor is added, so a second `onAppear` adds none.
    var isInstalled: Bool {
        !tokens.isEmpty
    }

    /// Key-downs sent to `host`'s window. `handle` returns nil to consume one.
    func addKeys(host: WindowRef, _ handle: @escaping (NSEvent) -> NSEvent?) {
        add(matching: .keyDown) { event in
            host.owns(event) ? handle(event) : event
        }
    }

    /// Scroll-wheel and pinch events over `frame()` (in SwiftUI `.global` space)
    /// in `host`'s window, as a zoom factor and the pointer's `.global` location.
    /// Those events are consumed, so the scroll views beneath do not also move.
    func addZoom(host: WindowRef, over frame: @escaping () -> CGRect, onZoom zoom: @escaping (CGFloat, CGPoint) -> Void) {
        add(matching: [.scrollWheel, .magnify]) { event in
            guard let pointer = EventLocationHitTest.globalPoint(of: event, in: host, inside: frame()),
                  let factor = Self.zoomFactor(of: event) else { return event }
            zoom(factor, pointer)
            return nil
        }
    }

    func removeAll() {
        tokens.forEach { NSEvent.removeMonitor($0) }
        tokens.removeAll()
    }

    private func add(matching mask: NSEvent.EventTypeMask, _ handler: @escaping (NSEvent) -> NSEvent?) {
        if let token = NSEvent.addLocalMonitorForEvents(matching: mask, handler: handler) {
            tokens.append(token)
        }
    }
}

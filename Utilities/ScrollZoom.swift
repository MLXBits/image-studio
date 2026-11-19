import CoreGraphics

/// Zoom factor for one scroll-wheel event in the image viewers.
nonisolated enum ScrollZoom {
    /// Zoom per mouse-wheel notch: 12%.
    static let notchFactor: CGFloat = 1.12

    /// A trackpad sends many small precise deltas, so it zooms exponentially on the
    /// raw delta. A mouse wheel sends about ±1 per notch, so each notch is one
    /// `notchFactor` step. Accelerated wheels send larger deltas; those are capped
    /// at 3 notches per event so a fast flick cannot jump straight to the limit.
    static func factor(deltaY: CGFloat, precise: Bool) -> CGFloat {
        if precise {
            return exp(deltaY * 0.005)
        }
        let notches = min(max(deltaY, -3), 3)
        return pow(notchFactor, notches)
    }
}

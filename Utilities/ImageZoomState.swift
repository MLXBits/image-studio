import CoreGraphics

/// Zoom and pan for an image fitted into a pane: the full-size viewer's one
/// image, or Compare's two panes, which share one scale and offset.
///
/// The view applies `scaleEffect(scale)` anchored at the pane's centre, then
/// `offset(offset)`. The offset is clamped so a zoomed image never drags past
/// the pane's edges, and is zero whenever the image is at fit.
nonisolated struct ImageZoomState: Equatable {
    /// What the state is clamped against: the images' pixel sizes, the pane's
    /// frame in SwiftUI `.global` space, and the padding each image fits inside.
    struct Fit {
        var images: [CGSize]
        var frame: CGRect
        var padding: CGFloat

        /// How far the offset may go on each axis at `scale`. With two images,
        /// the further of the two on each axis, so each can reach its own edges.
        func limit(at scale: CGFloat) -> CGSize {
            let limits = images.map {
                ImageZoomState.panLimit(imageSize: $0, pane: frame.size, padding: padding, scale: scale)
            }
            return CGSize(width: limits.map(\.width).max() ?? 0, height: limits.map(\.height).max() ?? 0)
        }
    }

    /// A drag in progress: the offset when it began, and its translation so far.
    private struct Drag: Equatable {
        var base: CGSize
        var translation: CGSize
    }

    static let minScale: CGFloat = 1
    static let maxScale: CGFloat = 12

    /// How far an image fitted into `pane` (inside `padding`) and zoomed by
    /// `scale` can pan before its edge comes inside the pane.
    static func panLimit(imageSize: CGSize, pane: CGSize, padding: CGFloat, scale: CGFloat) -> CGSize {
        let availW = max(0, pane.width - 2 * padding)
        let availH = max(0, pane.height - 2 * padding)
        guard imageSize.width > 0, imageSize.height > 0, availW > 0, availH > 0 else { return .zero }
        let fit = min(availW / imageSize.width, availH / imageSize.height)
        return CGSize(
            width: max(0, (imageSize.width * fit * scale - pane.width) / 2),
            height: max(0, (imageSize.height * fit * scale - pane.height) / 2)
        )
    }

    private(set) var scale: CGFloat = minScale
    private(set) var offset: CGSize = .zero
    /// Nil between drags.
    private var drag: Drag?

    var isZoomed: Bool {
        scale > Self.minScale
    }

    /// Multiplies the scale by `factor`, kept between fit and `maxScale`.
    /// With a `pointer` (in `.global` space), the image point under it stays
    /// put; without one, the offset is kept. Does nothing before layout.
    mutating func zoom(by factor: CGFloat, toward pointer: CGPoint?, in fit: Fit) {
        guard fit.frame.width > 0, fit.frame.height > 0 else { return }
        let newScale = min(max(scale * factor, Self.minScale), Self.maxScale)
        guard newScale != scale else { return }
        let applied = newScale / scale
        scale = newScale
        var proposed = offset
        if let pointer {
            // The pointer relative to the pane's centre, the scale anchor.
            let vx = pointer.x - fit.frame.midX
            let vy = pointer.y - fit.frame.midY
            proposed = CGSize(width: vx - applied * (vx - offset.width), height: vy - applied * (vy - offset.height))
        }
        offset = isZoomed ? clamped(proposed, in: fit) : .zero
        // A zoom mid-drag moved the image: re-base the drag on where it is now,
        // so its next movement continues from here instead of jumping back.
        if let translation = drag?.translation {
            drag?.base = CGSize(width: offset.width - translation.width, height: offset.height - translation.height)
        }
    }

    /// Moves the image by a drag's total `translation` since the drag began.
    mutating func pan(by translation: CGSize, in fit: Fit) {
        let base = drag?.base ?? offset
        drag = Drag(base: base, translation: translation)
        offset = clamped(CGSize(width: base.width + translation.width, height: base.height + translation.height), in: fit)
    }

    mutating func endPan(in fit: Fit) {
        drag = nil
        offset = clamped(offset, in: fit)
    }

    mutating func reset() {
        self = Self()
    }

    private func clamped(_ proposed: CGSize, in fit: Fit) -> CGSize {
        let limit = fit.limit(at: scale)
        return CGSize(
            width: min(max(proposed.width, -limit.width), limit.width),
            height: min(max(proposed.height, -limit.height), limit.height)
        )
    }
}

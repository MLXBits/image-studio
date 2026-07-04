import SwiftUI

// MARK: - Resize handle

enum BBoxResizeHandle: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
    case topMid, bottomMid, leftMid, rightMid
}

// MARK: - BBoxGeometry

/// Stateless coordinate math for the bbox editor. Bounding boxes are
/// `[y_min, x_min, y_max, x_max]` in 0–1000 normalized space; `canvas` is the
/// fitted pixel size of the drawing surface.
enum BBoxGeometry {
    /// Rule-of-thirds + center line positions (in canvas pixels) for the guide
    /// overlay. `verticalThirds`/`horizontalThirds` are the two thirds lines on
    /// each axis; `centerX`/`centerY` are the center cross.
    struct GuideLines: Equatable {
        var verticalThirds: [CGFloat]
        var horizontalThirds: [CGFloat]
        var centerX: CGFloat
        var centerY: CGFloat
    }

    /// Pixel rect for a normalized bbox on a canvas of the given size.
    static func normRect(_ bbox: [Int], in canvas: CGSize) -> CGRect {
        guard bbox.count == 4 else { return .zero }
        let x = canvas.width * CGFloat(bbox[1]) / 1000
        let y = canvas.height * CGFloat(bbox[0]) / 1000
        let w = canvas.width * CGFloat(bbox[3] - bbox[1]) / 1000
        let h = canvas.height * CGFloat(bbox[2] - bbox[0]) / 1000
        return CGRect(x: x, y: y, width: max(1, w), height: max(1, h))
    }

    /// Pixel point → 0–1000 normalized point.
    static func toNorm(_ pt: CGPoint, in canvas: CGSize) -> CGPoint {
        CGPoint(x: pt.x / canvas.width * 1000, y: pt.y / canvas.height * 1000)
    }

    /// Clamps a pixel point to the canvas bounds.
    static func clamp(_ pt: CGPoint, in canvas: CGSize) -> CGPoint {
        CGPoint(
            x: max(0, min(canvas.width, pt.x)),
            y: max(0, min(canvas.height, pt.y))
        )
    }

    /// Normalized, min/max-ordered, 0–1000-clamped bbox from two drag endpoints.
    static func normalizeBox(from start: CGPoint, to end: CGPoint, in canvas: CGSize) -> [Int] {
        let n1 = toNorm(start, in: canvas)
        let n2 = toNorm(end, in: canvas)
        let y1 = Int(min(n1.y, n2.y).rounded())
        let x1 = Int(min(n1.x, n2.x).rounded())
        let y2 = Int(max(n1.y, n2.y).rounded())
        let x2 = Int(max(n1.x, n2.x).rounded())
        return [
            max(0, min(y1, 1000)), max(0, min(x1, 1000)),
            max(0, min(y2, 1000)), max(0, min(x2, 1000)),
        ]
    }

    /// Whether a normalized point falls inside a bbox.
    static func contains(_ pt: CGPoint, bbox: [Int]) -> Bool {
        guard bbox.count == 4 else { return false }
        return pt.x >= CGFloat(bbox[1]) && pt.x <= CGFloat(bbox[3])
            && pt.y >= CGFloat(bbox[0]) && pt.y <= CGFloat(bbox[2])
    }

    /// Pixel position of a resize handle on a rect.
    static func handlePoint(_ handle: BBoxResizeHandle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .topMid: CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .leftMid: CGPoint(x: rect.minX, y: rect.midY)
        case .rightMid: CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomMid: CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    /// A distinct shade within the type's colour family (blue for text, green for
    /// objects). Shades are spread by index using a golden-ratio step so adjacent
    /// boxes are easy to tell apart while staying recognisably blue/green.
    static func boxColor(at index: Int, type: IdeogramElementType) -> Color {
        let baseHue: Double = type == .text ? 0.58 : 0.36
        let frac = (Double(index) * 0.618).truncatingRemainder(dividingBy: 1)
        let hue = baseHue + (frac - 0.5) * 0.10 // ±0.05 jitter — stays in family
        let saturation = 0.55 + frac * 0.40 // 0.55…0.95
        let brightness = 0.95 - frac * 0.30 // 0.95…0.65
        return Color(hue: hue, saturation: saturation, brightness: brightness)
    }

    /// Translates a bbox by a normalized delta, keeping its size and staying in bounds.
    static func moved(_ original: [Int], delta: CGSize) -> [Int]? {
        guard original.count == 4 else { return nil }
        let dx = Int(delta.width.rounded())
        let dy = Int(delta.height.rounded())
        let w = original[3] - original[1]
        let h = original[2] - original[0]
        let x1 = max(0, min(1000 - w, original[1] + dx))
        let y1 = max(0, min(1000 - h, original[0] + dy))
        return [y1, x1, y1 + h, x1 + w]
    }

    /// Resizes a bbox by dragging a handle, enforcing a minimum size and bounds.
    static func resized(
        _ original: [Int], handle: BBoxResizeHandle, delta: CGSize, minBox: Int
    ) -> [Int]? {
        guard original.count == 4 else { return nil }
        let dx = Int(delta.width.rounded())
        let dy = Int(delta.height.rounded())
        var y1 = original[0], x1 = original[1], y2 = original[2], x2 = original[3]

        switch handle {
        case .topLeft: y1 += dy; x1 += dx
        case .topMid: y1 += dy
        case .topRight: y1 += dy; x2 += dx
        case .leftMid: x1 += dx
        case .rightMid: x2 += dx
        case .bottomLeft: y2 += dy; x1 += dx
        case .bottomMid: y2 += dy
        case .bottomRight: y2 += dy; x2 += dx
        }

        y1 = max(0, min(y1, 1000)); x1 = max(0, min(x1, 1000))
        y2 = max(0, min(y2, 1000)); x2 = max(0, min(x2, 1000))
        let topHandles: Set<BBoxResizeHandle> = [.topLeft, .topMid, .topRight]
        let leftHandles: Set<BBoxResizeHandle> = [.topLeft, .leftMid, .bottomLeft]
        if y2 - y1 < minBox {
            if topHandles.contains(handle) { y1 = y2 - minBox } else { y2 = y1 + minBox }
        }
        if x2 - x1 < minBox {
            if leftHandles.contains(handle) { x1 = x2 - minBox } else { x2 = x1 + minBox }
        }
        return [y1, x1, y2, x2]
    }

    // MARK: - Composition guides

    static func gridLines(in canvas: CGSize) -> GuideLines {
        GuideLines(
            verticalThirds: [canvas.width / 3, canvas.width * 2 / 3],
            horizontalThirds: [canvas.height / 3, canvas.height * 2 / 3],
            centerX: canvas.width / 2,
            centerY: canvas.height / 2
        )
    }

    // MARK: - Frame zones (orientation authoring)

    /// Human-readable frame zone for a 0–1000 normalized point, e.g.
    /// "bottom left of frame", "top center of frame", "center of frame". Used to
    /// translate an orientation anchor into `desc` language. `pt.x`/`pt.y` are the
    /// normalized x/y (not the y-first bbox order).
    static func frameZone(forNorm pt: CGPoint) -> String {
        let row = pt.y < 333 ? "top" : (pt.y < 667 ? "center" : "bottom")
        let col = pt.x < 333 ? "left" : (pt.x < 667 ? "center" : "right")
        if row == "center" && col == "center" { return "center of frame" }
        return "\(row) \(col) of frame"
    }

    /// Largest canvas size with the output aspect ratio that fits `available`.
    static func fitCanvas(width: Int, height: Int, in available: CGSize) -> CGSize {
        let ratio = Double(width) / Double(max(height, 1))
        let maxH = available.height
        let maxW = available.width
        if maxW / ratio <= maxH {
            return CGSize(width: maxW, height: maxW / ratio)
        }
        return CGSize(width: maxH * ratio, height: maxH)
    }
}

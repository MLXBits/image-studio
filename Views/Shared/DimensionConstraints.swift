import Foundation

/// Constraints for a dimension picker: a per-axis pixel range, a snap step, and an
/// optional total-area (megapixel) cap.
///
/// FLUX.2 is *area*-limited — it generates up to ~4 MP across any aspect ratio, not
/// a fixed per-side cap. A per-axis-only limit (e.g. 2048 per side) is therefore
/// wrong for non-square outputs: it lets a 1:1 image reach the full 4 MP but caps a
/// 16:9 image at ~2.36 MP. The `maxArea` field models the real constraint.
struct DimensionConstraints: Equatable {
    /// Legacy per-axis behaviour: 64–2048, multiples of 16, no area cap.
    /// Used by Ideogram 4 (which layers its own 256 floor on top) and custom models.
    static let legacy = Self(range: 64 ... 2048, step: 16, maxArea: nil)

    /// Krea 2: per-axis up to 4096, multiples of 16, no area cap. Krea 2 can render up
    /// to 4096×4096; our defaults sit well below that, but the picker allows the full
    /// range for anyone who wants to push higher and accepts the trade-offs.
    static let krea2 = Self(range: 64 ... 4096, step: 16, maxArea: nil)

    /// Z-Image: per-axis 256–2048, multiples of 16 (Flux VAE stride). The model is
    /// tuned around ~1 MP; the picker allows up to 2048 per side for higher-res
    /// renders while keeping the floor above the model's minimum.
    static let zimage = Self(range: 256 ... 2048, step: 16, maxArea: nil)

    /// FLUX.2 (all variants — distilled *klein* and dev *klein-base*, 4B and 9B —
    /// share one architecture and the same ~4 MP ceiling). Multiples of 32 to match
    /// the FLUX.2 VAE stride. The per-axis ceiling is generous (4096) so wide aspect
    /// ratios can still reach 4 MP; the area cap is the binding limit.
    static let flux2 = Self(range: 256 ... 4096, step: 32, maxArea: 2048 * 2048)

    /// Sensible bounds for the aspect-preset area targets, in megapixels. The per-model
    /// `range` and `maxArea` still bind on top of whatever the user picks.
    static let megapixelTargetRange: ClosedRange<Double> = 0.05 ... 8.0

    /// Clamps a user-entered megapixel target into ``megapixelTargetRange``.
    static func clampMegapixels(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        return min(max(value, megapixelTargetRange.lowerBound), megapixelTargetRange.upperBound)
    }

    /// Allowed per-axis range, in pixels.
    var range: ClosedRange<Int>
    /// Both axes snap to multiples of this value.
    var step: Int
    /// Maximum total pixels (width × height). `nil` = no area cap (per-axis only).
    var maxArea: Int?

    /// Snaps a value into `range`, rounding to the nearest `step`.
    func snap(_ value: Double) -> Int {
        guard value.isFinite, value > 0 else { return range.lowerBound }
        let snapped = Int((value / Double(step)).rounded()) * step
        return min(range.upperBound, max(range.lowerBound, snapped))
    }

    /// Snaps `width`/`height` to step+range and, if `maxArea` is set and exceeded,
    /// shrinks to fit. When `preserveRatio` is true both axes scale down together;
    /// otherwise only `width` (the just-edited axis) is reduced.
    func fit(width: Int, height: Int, preserveRatio: Bool) -> (width: Int, height: Int) {
        var w = snap(Double(width))
        let h = snap(Double(height))
        guard let maxArea, w * h > maxArea else { return (w, h) }
        if preserveRatio {
            let scale = (Double(maxArea) / Double(w * h)).squareRoot()
            return (snapDown(Double(w) * scale), snapDown(Double(h) * scale))
        }
        w = snapDown(Double(maxArea) / Double(h))
        return (w, h)
    }

    /// The ratio-preserving size closest to `megapixels` that this constraint set allows.
    ///
    /// The pre-scale into `range` is the part that matters: `snap` clamps each axis
    /// independently, so feeding it an over-large 16:9 target would peg both axes at the
    /// per-axis ceiling and hand back a square. Scaling the pair down first keeps the ratio,
    /// and `fit` then applies any area cap.
    func dimensions(ratio: Double, megapixels: Double) -> (width: Int, height: Int) {
        guard ratio.isFinite, ratio > 0, megapixels.isFinite, megapixels > 0 else {
            return (range.lowerBound, range.lowerBound)
        }
        let pixels = Self.clampMegapixels(megapixels) * 1_000_000
        var w = (pixels * ratio).squareRoot()
        var h = (pixels / ratio).squareRoot()
        let shrink = max(w / Double(range.upperBound), h / Double(range.upperBound), 1)
        w /= shrink
        h /= shrink
        let grow = max(Double(range.lowerBound) / w, Double(range.lowerBound) / h, 1)
        w *= grow
        h *= grow
        // Snapping both axes independently compounds two roundings, which at draft sizes
        // visibly skews the ratio — 16:9 at 0.25 MP lands on 1.83. Derive each candidate's
        // second axis from its already-snapped first axis, and keep the closer ratio.
        let snappedW = snap(w)
        let byWidth = (width: snappedW, height: snap(Double(snappedW) / ratio))
        let snappedH = snap(h)
        let byHeight = (width: snap(Double(snappedH) * ratio), height: snappedH)
        let best = ratioError(byWidth, target: ratio) <= ratioError(byHeight, target: ratio)
            ? byWidth : byHeight
        return fit(width: best.width, height: best.height, preserveRatio: true)
    }

    /// Relative distance between a candidate size's aspect and the one asked for.
    private func ratioError(_ dims: (width: Int, height: Int), target: Double) -> Double {
        abs(Double(dims.width) / Double(dims.height) - target) / target
    }

    /// Floors a value to a `step` boundary within `range` (used when shrinking to fit area).
    private func snapDown(_ value: Double) -> Int {
        let snapped = Int((value / Double(step)).rounded(.down)) * step
        return min(range.upperBound, max(range.lowerBound, snapped))
    }
}

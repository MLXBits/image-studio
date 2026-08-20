@testable import MLXBits_Image_Studio
import Testing

/// Covers the megapixel-target sizing behind the aspect-ratio preset buttons: a target
/// area plus a ratio has to survive the step snap, the per-axis range, and the area cap
/// without turning into something that no longer looks like the ratio asked for.
struct DimensionConstraintsTests {
    private static let sets: [(name: String, constraints: DimensionConstraints)] = [
        ("legacy", .legacy), ("krea2", .krea2), ("zimage", .zimage), ("flux2", .flux2),
    ]

    private static let ratios: [(label: String, value: Double)] = [
        ("1:1", 1.0), ("16:9", 16.0 / 9.0), ("9:16", 9.0 / 16.0), ("3:2", 1.5),
        ("2:3", 2.0 / 3.0), ("4:3", 4.0 / 3.0), ("21:9", 21.0 / 9.0), ("9:21", 9.0 / 21.0),
    ]

    // MARK: - Targets

    /// Every preset at either default target lands near the requested area and ratio,
    /// on a step boundary, inside the per-axis range.
    @Test func presetsTrackTargetAreaAndRatio() {
        for (name, constraints) in Self.sets {
            for (label, ratio) in Self.ratios {
                for target in [1.0, 0.25] {
                    let (w, h) = constraints.dimensions(ratio: ratio, megapixels: target)
                    let context = "\(name) \(label) @ \(target) MP → \(w)×\(h)"

                    #expect(w % constraints.step == 0, "\(context) width off step")
                    #expect(h % constraints.step == 0, "\(context) height off step")
                    #expect(constraints.range.contains(w), "\(context) width out of range")
                    #expect(constraints.range.contains(h), "\(context) height out of range")

                    let area = Double(w * h) / 1_000_000
                    #expect(abs(area - target) / target < 0.12, "\(context) area \(area) MP")

                    let actual = Double(w) / Double(h)
                    #expect(abs(actual - ratio) / ratio < 0.05, "\(context) ratio \(actual)")
                }
            }
        }
    }

    /// The rapid target is only meaningful if it actually produces a smaller canvas.
    @Test func rapidTargetIsSmallerEverywhere() {
        for (name, constraints) in Self.sets {
            for (label, ratio) in Self.ratios {
                let full = constraints.dimensions(ratio: ratio, megapixels: 1.0)
                let rapid = constraints.dimensions(ratio: ratio, megapixels: 0.25)
                #expect(rapid.width * rapid.height < full.width * full.height, "\(name) \(label)")
            }
        }
    }

    /// Documented anchors: 1 MP is not 1024² — 1.05 MP is. Worth pinning, because the
    /// difference is the first thing anyone notices after changing the target.
    @Test func squareAnchors() {
        #expect(DimensionConstraints.legacy.dimensions(ratio: 1, megapixels: 1.0) == (1008, 1008))
        #expect(DimensionConstraints.flux2.dimensions(ratio: 1, megapixels: 1.0) == (992, 992))
        #expect(DimensionConstraints.flux2.dimensions(ratio: 1, megapixels: 1.05) == (1024, 1024))
        #expect(DimensionConstraints.legacy.dimensions(ratio: 1, megapixels: 0.25) == (496, 496))
    }

    // MARK: - Limits

    /// A target the per-axis ceiling cannot hold has to scale the *pair* down. Clamping
    /// each axis into `range` on its own would peg both at 2048 and return a square.
    @Test func perAxisCeilingKeepsTheRatio() {
        let (w, h) = DimensionConstraints.legacy.dimensions(ratio: 16.0 / 9.0, megapixels: 8)
        #expect((w, h) == (2048, 1152))
    }

    /// FLUX.2's area cap binds before the per-axis ceiling does.
    @Test func areaCapBinds() {
        let (w, h) = DimensionConstraints.flux2.dimensions(ratio: 21.0 / 9.0, megapixels: 8)
        #expect(w * h <= 2048 * 2048)
        #expect(w <= 4096)
    }

    /// Targets past the settings bounds are clamped rather than trusted.
    @Test func megapixelTargetsAreClamped() {
        #expect(DimensionConstraints.clampMegapixels(.nan) == 1.0)
        #expect(DimensionConstraints.clampMegapixels(-3) == DimensionConstraints.megapixelTargetRange.lowerBound)
        #expect(DimensionConstraints.clampMegapixels(999) == DimensionConstraints.megapixelTargetRange.upperBound)
        #expect(DimensionConstraints.clampMegapixels(0.4) == 0.4)

        // A nonsense target still yields a usable canvas rather than a crash or a zero.
        let (w, h) = DimensionConstraints.flux2.dimensions(ratio: 1, megapixels: 0)
        #expect((w, h) == (256, 256))
    }

    // MARK: - Preset plumbing

    @Test func freePresetHasNoCanonicalSize() {
        #expect(AspectPreset.free.dimensions(megapixels: 1, constraints: .legacy) == nil)
    }

    /// A preset and its swap are mirror images at the same target.
    @Test func swappedPresetsMirror() {
        for preset in AspectPreset.allCases where preset != .free {
            guard let a = preset.dimensions(megapixels: 1, constraints: .flux2),
                  let b = preset.swapped.dimensions(megapixels: 1, constraints: .flux2)
            else {
                Issue.record("\(preset.rawValue) has no dimensions")
                continue
            }
            #expect(a.width == b.height && a.height == b.width, "\(preset.rawValue)")
        }
    }
}

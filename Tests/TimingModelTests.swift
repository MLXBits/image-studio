@testable import MLXBits_Image_Studio
import Testing

/// Covers the per-step timing curve fit: how an unseen image size is predicted
/// from prior runs, keyed purely on megapixels (total pixel count, not aspect).
struct TimingModelTests {
    private func samples(_ pairs: [(Double, Double)]) -> [PerStepSample] {
        pairs.map { PerStepSample(mp: $0.0, secPerStep: $0.1) }
    }

    private func expectClose(_ a: Double?, _ b: Double, tol: Double = 1e-6) {
        #expect(a != nil)
        if let a { #expect(abs(a - b) < tol) }
    }

    // MARK: - Degenerate

    @Test func emptySamplesYieldsNil() {
        let result = TimingModel.predictSecPerStep(samples: [], mp: 1.0)
        #expect(result.value == nil)
        #expect(result.isApproximate)
    }

    // MARK: - Aspect-ratio independence

    /// Only total pixels drive the estimate. A 2:3 and a 3:2 render of the same
    /// size have identical megapixels, so they resolve to the same prediction —
    /// the whole point of keying on MP rather than (width, height).
    @Test func sameMegapixelsDifferentAspectMatch() {
        // 832×1248 (2:3) and 1248×832 (3:2) are both ~1.038 MP.
        let mp = Double(832 * 1248) / 1_000_000
        let mpSwapped = Double(1248 * 832) / 1_000_000
        #expect(mp == mpSwapped)

        let s = samples([(0.5, 1.0), (1.038_336, 2.0), (2.0, 4.0)])
        let a = TimingModel.predictSecPerStep(samples: s, mp: mp)
        let b = TimingModel.predictSecPerStep(samples: s, mp: mpSwapped)
        #expect(a.value == b.value)
        #expect(a.isApproximate == b.isApproximate)
    }

    // MARK: - One bucket → proportional through origin

    @Test func singleSampleIsProportional() {
        let s = samples([(2.0, 1.0)]) // 0.5 s/step per MP
        expectClose(TimingModel.predictSecPerStep(samples: s, mp: 4.0).value, 2.0)
        expectClose(TimingModel.predictSecPerStep(samples: s, mp: 1.0).value, 0.5)
    }

    @Test func singleSampleExactHitIsNotApproximate() {
        let s = samples([(2.0, 1.0)])
        #expect(!TimingModel.predictSecPerStep(samples: s, mp: 2.0).isApproximate)
        // Anything off the single known point is an extrapolation.
        #expect(TimingModel.predictSecPerStep(samples: s, mp: 4.0).isApproximate)
        #expect(TimingModel.predictSecPerStep(samples: s, mp: 1.0).isApproximate)
    }

    // MARK: - Two buckets → linear fit (captures fixed overhead)

    @Test func twoSamplesFitLine() {
        // y = 0.4 + 0.6·mp  →  (1, 1.0), (2, 1.6)
        let s = samples([(1.0, 1.0), (2.0, 1.6)])
        expectClose(TimingModel.predictSecPerStep(samples: s, mp: 1.5).value, 1.3)
        // Extrapolation still uses the line, but is flagged approximate.
        let out = TimingModel.predictSecPerStep(samples: s, mp: 3.0)
        expectClose(out.value, 2.2)
        #expect(out.isApproximate)
    }

    @Test func interpolationWithinRangeIsNotApproximate() {
        let s = samples([(1.0, 1.0), (2.0, 1.6)])
        #expect(!TimingModel.predictSecPerStep(samples: s, mp: 1.5).isApproximate)
        #expect(!TimingModel.predictSecPerStep(samples: s, mp: 1.0).isApproximate)
        #expect(!TimingModel.predictSecPerStep(samples: s, mp: 2.0).isApproximate)
    }

    // MARK: - Three+ buckets → quadratic (captures attention blow-up)

    @Test func threeSamplesRecoverQuadratic() {
        /// y = 0.5 + 0.2·mp + 0.1·mp²; 3 distinct points fit exactly.
        func f(_ mp: Double) -> Double {
            0.5 + 0.2 * mp + 0.1 * mp * mp
        }
        let s = samples([(1.0, f(1)), (2.0, f(2)), (4.0, f(4))])

        // Interpolated point lands on the curve, not on the chord (super-linear).
        expectClose(TimingModel.predictSecPerStep(samples: s, mp: 3.0).value, f(3), tol: 1e-4)
        #expect(!TimingModel.predictSecPerStep(samples: s, mp: 3.0).isApproximate)
    }

    @Test func quadraticExtrapolationIsSuperLinearAndApproximate() {
        func f(_ mp: Double) -> Double {
            0.5 + 0.2 * mp + 0.1 * mp * mp
        }
        let s = samples([(1.0, f(1)), (2.0, f(2)), (4.0, f(4))])

        let out = TimingModel.predictSecPerStep(samples: s, mp: 8.0)
        #expect(out.isApproximate)
        // A pure per-MP rate from the largest sample would predict f(4)/4 · 8.
        let linearRateGuess = f(4) / 4 * 8
        #expect((out.value ?? 0) > linearRateGuess) // quadratic grows faster
        expectClose(out.value, f(8), tol: 1e-3)
    }

    // MARK: - Clamping

    @Test func predictionNeverNonPositive() {
        // A downward line would predict negative at large mp; must clamp to > 0.
        let s = samples([(1.0, 1.0), (2.0, 0.4)]) // slope -0.6
        let out = TimingModel.predictSecPerStep(samples: s, mp: 10.0)
        #expect((out.value ?? -1) > 0)
    }
}

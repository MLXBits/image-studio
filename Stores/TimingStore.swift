import Foundation

/// Learns per-job generation timing from completed runs so the UI can show a
/// pre-flight estimate before a job is queued.
///
/// Timing is keyed by `(model, quantize, lowRam)` — the factors that actually
/// move the numbers. Within a key:
///   - **Load time** is megapixel-independent (weights I/O + Python import +
///     prompt encode), so it is tracked as a single smoothed scalar.
///   - **Per-step denoise time** scales super-linearly with megapixels (the
///     transformer's attention is O(tokens²), tokens ∝ pixels), so it is fitted
///     as a curve in megapixels. That lets an *unseen* image size interpolate
///     between — or extrapolate beyond — sizes already run. Only total pixel
///     count matters, not aspect ratio, so a 2:3 and a 3:2 render of the same
///     size land in the same bucket.
///   - **Decode time** is a small one-off, approximated as a scalar.
///
/// An estimate is reported as *approximate* whenever the requested megapixel
/// count falls outside the range already sampled (i.e. we are extrapolating).
@Observable
@MainActor
final class TimingStore {
    struct Estimate {
        /// Predicted wall-clock seconds for the whole job (load + denoise + decode).
        let seconds: Double
        /// True when the requested megapixels are outside the sampled range, so the
        /// number is an extrapolation rather than an interpolation/direct hit.
        let isApproximate: Bool
    }

    /// One completed run, fed to ``record(_:)`` to update its key's profile.
    struct CompletedRun {
        let model: String
        let quantize: Int
        let lowRam: Bool
        /// Model-load span (job start → first denoise step), or nil if not measured.
        let loadSec: Double?
        /// Denoise span (first step → last step).
        let denoiseSec: Double
        /// Decode/save span (last step → completion), or nil.
        let decodeSec: Double?
        /// Number of denoise steps actually run (the tqdm total, not the request).
        let steps: Int
        /// width × height ÷ 1e6.
        let megapixels: Double
    }

    private static let storeURL: URL =
        JobStore.appSupportURL.appendingPathComponent("timing.json")

    /// EWMA smoothing factor for repeated samples at the same key/bucket.
    private static let alpha = 0.4
    /// Megapixel bucket width — samples within the same bucket are averaged.
    private static let bucketWidth = 0.05

    /// Stable key for a FLUX variant (custom repos keyed by their repo id).
    static func fluxModelKey(_ model: FluxModelVariant, customRepo: String) -> String {
        model == .custom ? "custom:\(customRepo)" : model.rawValue
    }

    private static func key(model: String, quantize: Int, lowRam: Bool) -> String {
        "\(model)|q\(quantize)|\(lowRam ? "lr" : "hr")"
    }

    private static func bucket(_ mp: Double) -> Double {
        (mp / bucketWidth).rounded() * bucketWidth
    }

    private static func ewma(_ old: Double?, _ new: Double) -> Double {
        guard let old else { return new }
        return old * (1 - alpha) + new * alpha
    }

    private var profiles: [String: TimingProfile] = [:]

    init() {
        load()
    }

    /// Folds one completed run into the profile for its key.
    func record(_ run: CompletedRun) {
        guard run.steps > 0, run.denoiseSec > 0, run.megapixels > 0 else { return }
        let key = Self.key(model: run.model, quantize: run.quantize, lowRam: run.lowRam)
        var profile = profiles[key] ?? TimingProfile()

        if let loadSec = run.loadSec, loadSec >= 0 {
            profile.loadEWMA = Self.ewma(profile.loadEWMA, loadSec)
        }
        if let decodeSec = run.decodeSec, decodeSec >= 0 {
            profile.decodeEWMA = Self.ewma(profile.decodeEWMA, decodeSec)
        }

        let secPerStep = run.denoiseSec / Double(run.steps)
        let bucket = Self.bucket(run.megapixels)
        if let idx = profile.samples.firstIndex(where: { Self.bucket($0.mp) == bucket }) {
            profile.samples[idx].secPerStep = Self.ewma(profile.samples[idx].secPerStep, secPerStep)
            profile.samples[idx].mp = run.megapixels
        } else {
            profile.samples.append(PerStepSample(mp: run.megapixels, secPerStep: secPerStep))
            if profile.samples.count > 32 { profile.samples.removeFirst() }
        }

        profiles[key] = profile
        save()
    }

    /// Predicted job time for the given parameters, or nil when there is no usable
    /// history for the key yet (no completed run with a measured load time).
    func estimate(
        model: String, quantize: Int, lowRam: Bool, steps: Int, megapixels: Double
    ) -> Estimate? {
        guard steps > 0, megapixels > 0 else { return nil }
        let key = Self.key(model: model, quantize: quantize, lowRam: lowRam)
        guard let profile = profiles[key],
              let load = profile.loadEWMA,
              !profile.samples.isEmpty else { return nil }

        let prediction = TimingModel.predictSecPerStep(samples: profile.samples, mp: megapixels)
        guard let perStep = prediction.value else { return nil }

        let seconds = load + Double(steps) * perStep + (profile.decodeEWMA ?? 0)
        return Estimate(seconds: seconds, isApproximate: prediction.isApproximate)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        try? FileManager.default.createDirectory(
            at: JobStore.appSupportURL, withIntermediateDirectories: true
        )
        try? data.write(to: Self.storeURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let loaded = try? JSONDecoder().decode([String: TimingProfile].self, from: data)
        else { return }
        profiles = loaded
    }
}

// MARK: - Persisted model

/// Learned timing for a single `(model, quantize, lowRam)` key.
struct TimingProfile: Codable {
    /// Smoothed model-load seconds (megapixel-independent).
    var loadEWMA: Double?
    /// Smoothed decode/save seconds (small, treated as megapixel-independent).
    var decodeEWMA: Double?
    /// One smoothed `seconds-per-step` measurement per megapixel bucket.
    var samples: [PerStepSample] = []
}

struct PerStepSample: Codable {
    var mp: Double
    var secPerStep: Double
}

// MARK: - Curve fitting (pure, unit-testable)

/// Fits per-step time as a function of megapixels and predicts an unseen size.
///
/// A requested size within one bucket of a stored sample short-circuits to that
/// measured point (see ``predictSecPerStep(samples:mp:)``). Otherwise the size is
/// predicted from a fit, tiered by how many distinct megapixel buckets exist:
///   - **1 bucket** → proportional through the origin from that point.
///   - **2 buckets** → linear least-squares `a + b·mp` (captures fixed overhead).
///   - **≥3 buckets** → quadratic least-squares `a + b·mp + c·mp²` (captures the
///     O(tokens²) attention blow-up, so extrapolation past the largest sample is
///     safe-ish). Falls back to linear if the quadratic predicts ≤ 0.
///
/// Both fits use relative-error weighting (`w = 1/y²`) so the large, slow high-res
/// samples don't dominate the least-squares and over-predict small images.
enum TimingModel {
    /// Requested megapixels within this distance of a stored sample count as a
    /// direct hit (one timing bucket wide; see ``TimingStore/bucketWidth``).
    private static let directHitBucket = 0.05

    static func predictSecPerStep(
        samples: [PerStepSample], mp: Double
    ) -> (value: Double?, isApproximate: Bool) {
        let pts = samples.map { ($0.mp, $0.secPerStep) }
        let mps = pts.map(\.0)
        guard let minMP = mps.min(), let maxMP = mps.max() else { return (nil, true) }

        // Within the sampled span we are interpolating (or hitting a known size),
        // which is trustworthy even from a single point; outside it we extrapolate.
        let isApproximate = mp < minMP - 1e-9 || mp > maxMP + 1e-9

        // Direct hit: when a measured sample sits within one bucket of the request,
        // trust it over any global fit. A curve fitted across a wide MP span is
        // dominated (in absolute least-squares) by the large, slow high-res samples,
        // so it systematically over-predicts small images — even ones we have direct
        // data for. Snapping to the nearest measured point avoids that bias entirely.
        if let nearest = pts.min(by: { abs($0.0 - mp) < abs($1.0 - mp) }),
           abs(nearest.0 - mp) <= directHitBucket {
            return (max(nearest.1, 0.001), isApproximate)
        }

        let distinct = Set(mps.map { ($0 / 0.05).rounded() }).count
        var value: Double
        if distinct >= 3 {
            value = quadratic(pts, at: mp) ?? linear(pts, at: mp) ?? proportional(pts, at: mp)
            if value <= 0 { value = linear(pts, at: mp) ?? proportional(pts, at: mp) }
        } else if distinct == 2 {
            value = linear(pts, at: mp) ?? proportional(pts, at: mp)
        } else {
            value = proportional(pts, at: mp)
        }
        return (max(value, 0.001), isApproximate)
    }

    private static func proportional(_ pts: [(Double, Double)], at mp: Double) -> Double {
        guard let first = pts.first else { return 0.001 }
        let (m0, s0) = first
        return m0 > 0 ? s0 * (mp / m0) : s0
    }

    private static func linear(_ pts: [(Double, Double)], at mp: Double) -> Double? {
        // Relative-error weighting (w = 1/y²) stops the large, slow samples from
        // dominating the fit and inflating predictions for small images. With only
        // two points the line passes through both regardless of the weights.
        var sw = 0.0, swx = 0.0, swy = 0.0, swxx = 0.0, swxy = 0.0
        for (x, y) in pts {
            let w = 1.0 / max(y * y, 1e-9)
            sw += w; swx += w * x; swy += w * y
            swxx += w * x * x; swxy += w * x * y
        }
        let denom = sw * swxx - swx * swx
        guard abs(denom) > 1e-12 else { return nil }
        let b = (sw * swxy - swx * swy) / denom
        let a = (swy - b * swx) / sw
        return a + b * mp
    }

    private static func quadratic(_ pts: [(Double, Double)], at mp: Double) -> Double? {
        // Weighted normal equations for y = a + b·x + c·x², weights w = 1/y² (relative
        // error) so the fit isn't dragged upward by the large-MP, high-cost samples.
        var s = [Double](repeating: 0, count: 5) // Σw·x^0 … Σw·x^4
        var t = [Double](repeating: 0, count: 3) // Σw·y, Σw·xy, Σw·x²y
        for (x, y) in pts {
            let w = 1.0 / max(y * y, 1e-9)
            var xp = w
            for k in 0 ..< 5 {
                s[k] += xp; xp *= x
            }
            t[0] += w * y; t[1] += w * x * y; t[2] += w * x * x * y
        }
        let m = [
            [s[0], s[1], s[2]],
            [s[1], s[2], s[3]],
            [s[2], s[3], s[4]],
        ]
        guard let coeffs = solve3x3(m, t) else { return nil }
        return coeffs[0] + coeffs[1] * mp + coeffs[2] * mp * mp
    }

    /// Solves a 3×3 linear system by Cramer's rule. Returns nil if singular.
    private static func solve3x3(_ m: [[Double]], _ v: [Double]) -> [Double]? {
        func det3(_ a: [[Double]]) -> Double {
            a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1])
                - a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0])
                + a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0])
        }
        let d = det3(m)
        guard abs(d) > 1e-12 else { return nil }
        var result = [Double](repeating: 0, count: 3)
        for col in 0 ..< 3 {
            var mc = m
            for row in 0 ..< 3 {
                mc[row][col] = v[row]
            }
            result[col] = det3(mc) / d
        }
        return result
    }
}

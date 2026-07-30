import Foundation

/// Facts about PiD decoding that both the params form and the metadata display
/// need, kept in one place so the advertised output size and the size shown after
/// the fact cannot drift apart.
nonisolated enum PidDecode {
    /// PiD's fixed super-resolution factor: the decoded image is this many times
    /// the generation width and height. Not configurable — the released
    /// checkpoints are 4x only.
    static let scaleFactor = 4

    /// Below this pixel count the base model has too little to work with and PiD's
    /// 4x mostly invents detail rather than resolving it. 0.25 MP ~= 512x512.
    static let recommendedMinPixels = 250_000

    /// Valid range for `--pid-degrade-sigma`. The upper bound is the sigma~U[0, 0.8]
    /// degradation PiD's LQ gate was distilled against; mflux rejects anything past it
    /// because the decoder has never seen that input distribution.
    static let degradeSigmaRange = 0.0 ... 0.8

    /// Stepper increment. 0.05 lands on the values worth trying (0.2 is the reported
    /// starting point for over-textured skin) without pretending to more precision.
    static let degradeSigmaStep = 0.05
}

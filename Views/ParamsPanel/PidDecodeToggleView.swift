import SwiftUI

/// "Enable PiD" toggle for the Dimensions section.
///
/// Renders nothing unless the configured mflux install actually has the decoder,
/// so the control cannot be switched on against an mflux that would reject
/// `--pid-decode`. PiD is unmerged upstream (filipstrand/mflux#490); once it ships
/// in a release, drop the `BinaryDetector.supportsPidDecode` guard and show the
/// toggle unconditionally.
struct PidDecodeToggleView: View {
    private static let infoText = """
    PiD allows you to generate at a lower resolution and upscale by 4x during \
    decoding. Recommended minimum is 0.25MP.

    Instead of the usual single VAE decode, a 4-step diffusion runs in pixel \
    space, conditioned on the latent and your prompt, so the extra detail is \
    generated rather than interpolated.

    Adds roughly 15–20s per image and needs a few GB more memory. Strongest on \
    hair, feathers, fabric and metal; it can over-texture skin, so check faces \
    at full size.
    """

    private static let degradeInfoText = """
    How much noise to add to the latent before PiD conditions on it, matching the \
    degradation PiD's conditioning was trained against (0.0–0.8).

    0.00 hands PiD the clean latent — maximum detail, but it can read latent noise as \
    texture and produce crusty skin. Raising it makes PiD lean on its own prior instead. \
    Try 0.20 first when skin over-textures.

    Costs nothing extra to run.
    """

    @Binding var pidDecode: Bool
    @Binding var pidDegradeSigma: Double
    let width: Int
    let height: Int

    @Environment(AppSettings.self) private var settings

    private var isSupported: Bool {
        BinaryDetector.supportsPidDecode(in: settings.mfluxBinaryDir)
    }

    private var isBelowRecommended: Bool {
        width * height < PidDecode.recommendedMinPixels
    }

    /// Rounds each write to the step grid, so the stored value is exactly the number shown.
    private var snappedSigma: Binding<Double> {
        Binding(
            get: { pidDegradeSigma },
            set: { pidDegradeSigma = (($0 / PidDecode.degradeSigmaStep).rounded() * PidDecode.degradeSigmaStep) }
        )
    }

    var body: some View {
        if isSupported {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 6) {
                    Toggle("Enable PiD", isOn: $pidDecode)
                        .font(.system(size: 11))
                        .toggleStyle(.checkbox)

                    if pidDecode {
                        Text("→ \(width * PidDecode.scaleFactor)×\(height * PidDecode.scaleFactor)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 4)

                    if pidDecode, isBelowRecommended {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .help("Below the recommended 0.25 MP minimum — PiD will invent detail "
                                + "rather than resolve it. Try 512×512 or larger.")
                    }

                    InfoButton(title: "PiD decoding", description: Self.infoText)
                }

                // Hidden rather than removed. A conditionally-constructed Stepper is torn
                // down and rebuilt on every toggle; keeping one instance alive for the
                // panel's lifetime means the control cannot lose track of its value, and
                // costs nothing since it collapses to zero height when off.
                degradeSigmaRow
                    .frame(height: pidDecode ? nil : 0, alignment: .leading)
                    .opacity(pidDecode ? 1 : 0)
                    .disabled(!pidDecode)
                    .clipped()
                    .accessibilityHidden(!pidDecode)
            }
        }
    }

    private var degradeSigmaRow: some View {
        HStack(alignment: .center, spacing: 6) {
            Text("Degrade σ")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            // Snapped, not bound directly: repeated 0.05 increments accumulate binary
            // floating-point error, so stepping back down to "0.00" was leaving ~1.4e-17
            // behind. Harmless numerically, but it lands in the sidecar as a nonsense value
            // and makes the runners' `> 0` check pass a flag the user believes is off.
            Stepper(value: snappedSigma, in: PidDecode.degradeSigmaRange, step: PidDecode.degradeSigmaStep) {
                Text(String(format: "%.2f", pidDegradeSigma))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 34, alignment: .trailing)
            }
            .accessibilityLabel("PiD degrade sigma")
            .accessibilityValue(String(format: "%.2f", pidDegradeSigma))

            Spacer(minLength: 4)

            InfoButton(title: "Degrade sigma", description: Self.degradeInfoText)
        }
        .padding(.leading, 18)
    }
}

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

    0.00 hands PiD the clean latent and is the recommended default.

    Raising it is NOT a fix for over-textured skin — measured on Krea 2, 0.20 roughly \
    doubles invented facial detail, darkens the image, and drifts further from the plain \
    VAE result. It reaches conditioning the decoder is otherwise never given, so it is \
    worth having, but treat it as "a different, darker sample" rather than a repair.

    Costs nothing extra to run.
    """

    private static func snap(_ value: Double) -> Double {
        let clamped = min(max(value, PidDecode.degradeSigmaRange.lowerBound), PidDecode.degradeSigmaRange.upperBound)
        return (clamped / PidDecode.degradeSigmaStep).rounded() * PidDecode.degradeSigmaStep
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    @Binding var pidDecode: Bool
    @Binding var pidDegradeSigma: Double
    let width: Int
    let height: Int

    @Environment(AppSettings.self) private var settings

    // Typing is buffered so intermediate keystrokes never reach the binding (mirrors
    // DimensionSliderRow); committed on Return or focus-out.
    @State private var sigmaText: String = ""
    @FocusState private var sigmaFocused: Bool

    private var isSupported: Bool {
        BinaryDetector.supportsPidDecode(in: settings.mfluxBinaryDir)
    }

    private var isBelowRecommended: Bool {
        width * height < PidDecode.recommendedMinPixels
    }

    /// Rounds each write to the step grid, so the stored value is exactly the number shown.
    private var snappedSigma: Binding<Double> {
        Binding(get: { pidDegradeSigma }, set: { pidDegradeSigma = Self.snap($0) })
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

            // The arrows drive a snapped binding: repeated 0.05 increments accumulate binary
            // floating-point error, so stepping back down to "0.00" was leaving ~1.4e-17
            // behind. Harmless numerically, but it lands in the sidecar as a nonsense value
            // and makes the runners' `> 0` check pass a flag the user believes is off.
            //
            // The field is a TextField, not a Text, matching DimensionSliderRow: typing is
            // buffered so intermediate keystrokes never reach the binding, and commits on
            // Return or focus-out. Tabbing out of a display-only Text saved nothing.
            Stepper(value: snappedSigma, in: PidDecode.degradeSigmaRange, step: PidDecode.degradeSigmaStep) {
                TextField("", text: $sigmaText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 48)
                    .focused($sigmaFocused)
                    .onSubmit(commitSigmaText)
                    .onChange(of: sigmaFocused) { _, isFocused in
                        if !isFocused {
                            commitSigmaText()
                        }
                    }
            }
            .accessibilityLabel("PiD degrade sigma")
            .accessibilityValue(String(format: "%.2f", pidDegradeSigma))
            // Keep the buffer in step with changes made by the arrows, a metadata replay,
            // or the last-used form restore — but never while the user is mid-edit.
            .onAppear { sigmaText = Self.format(pidDegradeSigma) }
            .onChange(of: pidDegradeSigma) { _, new in
                if !sigmaFocused {
                    sigmaText = Self.format(new)
                }
            }

            Spacer(minLength: 4)

            InfoButton(title: "Degrade sigma", description: Self.degradeInfoText)
        }
        .padding(.leading, 18)
    }

    /// Parses the buffer, clamping and snapping; unparseable input reverts to the live value
    /// rather than silently becoming 0.0.
    private func commitSigmaText() {
        pidDegradeSigma = Self.snap(Double(sigmaText.replacingOccurrences(of: ",", with: ".")) ?? pidDegradeSigma)
        sigmaText = Self.format(pidDegradeSigma)
    }
}

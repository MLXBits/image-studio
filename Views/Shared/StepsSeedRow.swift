import SwiftUI

/// The Steps and Seed fields on one row, as the per-family panels show them.
struct StepsSeedRow: View {
    @Binding var steps: Int
    @Binding var seed: Int
    /// Supplies the step range and clamping.
    let model: FluxModelVariant
    let stepsInfo: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 3) {
                    Text("Steps").font(.caption2).fontWeight(.medium).foregroundStyle(.secondary)
                    InfoButton(
                        title: "Denoising Steps",
                        description: stepsInfo
                    )
                }
                Stepper(value: $steps, in: 1 ... model.maxSteps) {
                    TextField("", value: $steps, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                        .onSubmit { steps = model.clampedSteps(steps) }
                }
                .accessibilityLabel("Steps")
                .accessibilityValue("\(steps)")
            }

            Divider().frame(height: 44)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 3) {
                    Text("Seed").font(.caption2).fontWeight(.medium).foregroundStyle(.secondary)
                    InfoButton(
                        title: "Random Seed",
                        description: "The same seed + prompt produces the same image every time. "
                            + "Use -1 for a unique result each run."
                    )
                }
                HStack(spacing: 4) {
                    TextField("-1", value: $seed, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 100)
                        .accessibilityLabel("Seed")
                        .accessibilityHint("Use -1 for random")
                    Button {
                        seed = Int.random(in: 0 ..< 1_000_000_000)
                    } label: {
                        Image(systemName: "dice").font(.caption)
                    }
                    .buttonStyle(.iconButton)
                    .accessibilityLabel("Pick random seed")
                    Button {
                        seed = -1
                    } label: {
                        Image(systemName: "arrow.counterclockwise").font(.caption)
                    }
                    .buttonStyle(.iconButton)
                    .accessibilityLabel("Reset to random (-1)")
                }
            }
            Spacer(minLength: 0)
        }
    }
}

import SwiftUI

/// Compact learned-time estimate shown below the dimension picker. Renders nothing
/// until there is comparable history for the current model/quantize/size; appends
/// "est." when the requested pixel count is outside the sampled range (extrapolated).
struct GenerationEstimateView: View {
    let estimate: TimingStore.Estimate?

    var body: some View {
        if let estimate {
            Divider()
            HStack(spacing: 4) {
                Image(systemName: "clock")
                Text("Est. ~\(RunnerSupport.formatDuration(estimate.seconds))\(estimate.isApproximate ? " (rough)" : "")")
                Spacer(minLength: 0)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .help(estimate.isApproximate
                ? "Rough estimate — extrapolated from a different image size."
                : "Estimated from previous runs at a similar pixel count.")
        }
    }
}

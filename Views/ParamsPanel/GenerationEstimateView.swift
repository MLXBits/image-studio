import SwiftUI

/// Compact info strip below the dimension picker: learned-time estimate on the
/// left, megapixel count of the current width × height on the right. The estimate
/// stays hidden until there is comparable history for the current
/// model/quantize/size, and appends "(rough)" when the requested pixel count is
/// outside the sampled range (extrapolated); the megapixel readout is always shown.
struct GenerationEstimateView: View {
    let estimate: TimingStore.Estimate?
    let width: Int
    let height: Int

    private var megapixels: Double {
        Double(width * height) / 1_000_000
    }

    private var megapixelText: String {
        String(format: megapixels < 1 ? "%.2f MP" : "%.1f MP", megapixels)
    }

    var body: some View {
        Divider()
        HStack(spacing: 4) {
            if let estimate {
                Image(systemName: "clock")
                Text("Est. ~\(RunnerSupport.formatDuration(estimate.seconds))\(estimate.isApproximate ? " (rough)" : "")")
                    .help(estimate.isApproximate
                        ? "Rough estimate — extrapolated from a different image size."
                        : "Estimated from previous runs at a similar pixel count.")
            }
            Spacer(minLength: 8)
            Text(megapixelText)
                .monospacedDigit()
                .help("\(width) × \(height) = \(megapixelText) total pixels.")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

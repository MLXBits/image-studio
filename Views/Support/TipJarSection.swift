import SwiftUI

/// The App Store build's three tips, with names and prices from the store.
struct TipJarSection: View {
    /// The caption under the tips for a finished, waiting or failed purchase.
    static func note(for phase: TipJarStore.Phase) -> String? {
        switch phase {
        case .thanked: "Thank you! Your tip helps keep Image Studio going."
        case .pending: "Your tip is waiting for approval."
        case .failed: "The tip didn't go through. Please try again later."
        default: nil
        }
    }

    @Environment(TipJarStore.self) private var tipJar

    var body: some View {
        VStack(spacing: 12) {
            switch tipJar.phase {
            case .idle, .loading:
                ProgressView().controlSize(.small)
            case .unavailable:
                Text("Tips can't be loaded right now.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Try Again") { Task { await tipJar.load() } }
                    .buttonStyle(.bordered)
            default:
                HStack(spacing: 10) {
                    ForEach(tipJar.products) { product in
                        Button {
                            Task { await tipJar.purchase(product.id) }
                        } label: {
                            VStack(spacing: 2) {
                                Text(product.displayName)
                                Text(product.displayPrice)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(minWidth: 88)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(!tipJar.canPurchase)
                    }
                }
                if let note = Self.note(for: tipJar.phase) {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task {
            tipJar.clearOutcome()
            await tipJar.load()
        }
    }
}

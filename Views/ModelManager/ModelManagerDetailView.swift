import SwiftUI

/// The Models window's detail pane for one model: what it is good at, and its BF16/Q8/Q4 table.
struct ModelManagerDetailView: View {
    let model: FluxModelVariant

    @Environment(AppSettings.self) private var settings
    @Environment(WeightDownloadStore.self) private var weightDownloads

    private var guide: ModelGuide {
        model.guide
    }

    private var hasSettingsOverride: Bool {
        let repo = model.isIdeogram4
            ? (settings.ideogram4ModelRepoOverride ?? "")
            : (settings.defaults(for: model).modelRepoOverride ?? "")
        return !repo.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        // Reading the revision re-evaluates the cached flags when a download or removal finishes.
        let row = settings.inventoryRow(for: model)
        let _ = weightDownloads.revision // swiftlint:disable:this redundant_discardable_let
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                Text(guide.blurb)
                if !guide.greatAt.isEmpty {
                    greatAt
                }
                if let note = guide.note {
                    Text(note).font(.callout).foregroundStyle(.secondary)
                }
                if hasSettingsOverride {
                    Text("Override set in Settings")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(row.quants, id: \.quantize) { status in
                        QuantRowView(model: model, status: status)
                    }
                }
                if row.quants.contains(where: { weightDownloads.runs[.weights(model, quantize: $0.quantize)]?.phase == .running }) {
                    BackgroundDownloadCaption()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.displayName).font(.title2.bold())
            Text(ModelInventory.headerLine(for: model))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var greatAt: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Great at").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(guide.greatAt, id: \.self) { tag in
                    Text(tag)
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(.secondary.opacity(0.12), in: Capsule())
                }
            }
        }
    }
}

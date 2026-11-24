import SwiftUI

extension AppSettings {
    /// `model`'s three quants as the Models window shows them: what is cached, sizes, and RAM fit.
    func inventoryRow(for model: FluxModelVariant) -> ModelRow {
        ModelInventory.row(
            for: model,
            isCached: { model.isOnDisk(quantize: $0, savedIn: effectiveMfluxCacheDir, hubDir: hfHubDir) },
            ramGB: { model.approximateRAMGB(quantize: $0, settings: self) },
            physicalGB: RAMFit.physicalGB,
            toolMissing: model.generateTool.map { !toolchain.hasTool($0) } ?? false
        )
    }

    /// The model source set for `model` in Settings, trimmed, or nil when there is none. The
    /// override names a repo or path with its own precision, so the quant choice doesn't apply.
    /// Ideogram keeps its own setting; every other model uses its per-model default.
    func modelSourceOverride(for model: FluxModelVariant) -> String? {
        guard model != .custom else { return nil }
        let repo = model.isIdeogram4
            ? (ideogram4ModelRepoOverride ?? "")
            : (defaults(for: model).modelRepoOverride ?? "")
        let trimmed = repo.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}

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
}

import Foundation

/// AppSettings' checks for model weights already on disk.
extension AppSettings {
    /// Returns true when Ideogram 4 model weights are fully cached locally: the
    /// published Q8/Q4 repo or the FP8 checkpoint, judged by the catalog's
    /// completeness check (mflux's answer when it has one), so a partial download
    /// doesn't count.
    func ideogram4ModelOnDisk(quantize: Int) -> Bool {
        FluxModelVariant.ideogram4.isOnDisk(quantize: quantize, savedIn: effectiveMfluxCacheDir, hubDir: hfHubDir)
    }
}

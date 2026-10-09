import Foundation

/// AppSettings' checks for model weights already on disk.
extension AppSettings {
    /// Returns true when Ideogram 4 model weights are already cached locally.
    func ideogram4ModelOnDisk(quantize: Int) -> Bool {
        let hfBase = hfHubDir
        if quantize > 0 {
            // Q8/Q4 ship as published mflux-save repos and load straight from the hub cache.
            // The legacy mflux-save dir is never used for them (and may be stale), so
            // a present pre-quantized repo is the only signal we trust.
            if let repo = FluxModelVariant.ideogram4.preQuantizedRepoID(quantize: quantize) {
                let cacheName = "models--" + repo.replacingOccurrences(of: "/", with: "--")
                let snapshots = hfBase.appendingPathComponent(cacheName + "/snapshots")
                return FileManager.default.fileExists(atPath: snapshots.path)
            }
            let savedPath = effectiveMfluxCacheDir
                .appendingPathComponent("saved/ideogram4-q\(quantize)", isDirectory: true)
            return FluxModelVariant.hasSavedWeights(at: savedPath)
        }
        // Check HF hub cache for the FP8 base checkpoint.
        let snapshots = hfBase.appendingPathComponent("models--ideogram-ai--ideogram-4-fp8/snapshots")
        return FileManager.default.fileExists(atPath: snapshots.path)
    }
}

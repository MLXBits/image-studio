import Foundation

extension AppSettings {
    /// The UNet, CLIP and VAE filenames set under `key` (a family's id, or a FLUX.2 variant's raw
    /// value), or nil when any of the three is unset.
    func comfyFiles(key: String) -> [String]? {
        let files = [comfyUNet[key], comfyClip[key], comfyVae[key]].map { $0 ?? "" }
        return files.contains(where: \.isEmpty) ? nil : files
    }

    /// A job for `variant` runs on ComfyUI, not local mflux. The checks match the runner's:
    /// the family's backend is set to ComfyUI and a server URL is set (`JobRunner.makeComfyTarget`),
    /// and the family's `comfyGraph` has a graph and all its files for the variant. A custom
    /// checkpoint passes the variant it loads as.
    func runsOnComfy(_ variant: FluxModelVariant) -> Bool {
        let family = variant.family
        guard comfyBackendEnabled[family.id] == true, !comfyURL.trimmed().isEmpty else { return false }
        switch family {
        case .flux:
            // Only FLUX.2 has templates; FLUX.3 runs locally even with the backend set to ComfyUI.
            return FluxRunnerSpec.flux2FlowKey(variant: variant, hasRefs: false) != nil
                && comfyFiles(key: variant.rawValue) != nil
        case .krea2, .qwen21:
            return comfyFiles(key: family.id) != nil
        case .seedvr2:
            // Its graph picks the files from the server's lists.
            return true
        case .ideogram4, .zimage:
            return false
        }
    }
}

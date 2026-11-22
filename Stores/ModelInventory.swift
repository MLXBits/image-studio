import Foundation

/// One quantization of a model: whether it is cached, how big it is, and how it fits this Mac.
nonisolated struct QuantStatus: Equatable, Sendable {
    let quantize: Int
    let label: String
    let cached: Bool
    let sizeGB: Double
    let ramGB: Double
    let fit: RAMFit
}

/// A model with its three quants, as the Models window lists it.
struct ModelRow: @MainActor Equatable, @MainActor Identifiable {
    let model: FluxModelVariant
    let quants: [QuantStatus]
    let toolMissing: Bool

    var id: FluxModelVariant {
        model
    }
}

/// A titled group of models in the Models window.
nonisolated struct ModelSection: Equatable, Identifiable, Sendable {
    let title: String
    let models: [FluxModelVariant]

    var id: String {
        title
    }
}

/// The pure logic behind the Models window: grouping, per-quant status, and disk use.
enum ModelInventory {
    /// Display order: BF16, Q8, Q4.
    static let quantOrder = [0, 8, 4]

    static let sections: [ModelSection] = [
        ModelSection(title: "FLUX.3", models: [.flux3Klein, .flux3KleinBase]),
        ModelSection(title: "FLUX.2", models: [.flux2Klein9B, .flux2Klein4B, .flux2KleinBase9B, .flux2KleinBase4B]),
        ModelSection(title: "Ideogram", models: [.ideogram4]),
        ModelSection(title: "Krea", models: [.krea2]),
        ModelSection(title: "Qwen", models: [.qwen21Turbo]),
        ModelSection(title: "Z-Image", models: [.zimageTurbo, .zimage]),
    ]

    static func row(
        for model: FluxModelVariant,
        isCached: (Int) -> Bool,
        ramGB: (Int) -> Double,
        physicalGB: Double,
        toolMissing: Bool
    ) -> ModelRow {
        let quants = quantOrder.map { quantize in
            let ram = ramGB(quantize)
            return QuantStatus(
                quantize: quantize,
                label: quantize == 0 ? model.baseWeightLabel : "Q\(quantize)",
                cached: isCached(quantize),
                sizeGB: model.approximateSizeGB(quantize: quantize),
                ramGB: ram,
                fit: RAMFit.of(ramGB: ram, physicalGB: physicalGB)
            )
        }
        return ModelRow(model: model, quants: quants, toolMissing: toolMissing)
    }

    /// The largest cached quant that fits this Mac, else Q8.
    static func preferredQuantize(_ row: ModelRow) -> Int {
        row.quants.first { $0.cached && ($0.fit == .comfortable || $0.fit == .tight) }?.quantize ?? 8
    }

    /// Bytes under the repos' `blobs/` folders, following links and counting each resolved file once.
    nonisolated static func diskBytes(repoFolders: [URL]) -> Int64 {
        var seen = Set<String>()
        var total: Int64 = 0
        for folder in repoFolders {
            let blobs = folder.appendingPathComponent("blobs", isDirectory: true)
            let entries = (try? FileManager.default.contentsOfDirectory(at: blobs, includingPropertiesForKeys: nil)) ?? []
            for entry in entries {
                let resolved = entry.resolvingSymlinksInPath()
                guard seen.insert(resolved.path).inserted else { continue }
                total += Int64((try? resolved.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }

    /// Whether every file `spec` includes is in its revision's snapshot (links followed, so an
    /// include whose blob never landed doesn't count). A spec without a revision or includes isn't cached.
    nonisolated static func isCached(_ spec: HFDownloadSpec, hubDir: URL) -> Bool {
        guard let revision = spec.revision, !spec.include.isEmpty else { return false }
        let snapshot = ModelDownloadStore.cacheFolder(repo: spec.repo, hubDir: hubDir)
            .appendingPathComponent("snapshots/\(revision)", isDirectory: true)
        return spec.include.allSatisfy {
            FileManager.default.fileExists(atPath: snapshot.appendingPathComponent($0).path)
        }
    }

    /// The cache folders the Models window accounts for: every model at every precision, plus the
    /// SeedVR2 and Gemma repos, each only if it exists on disk.
    static func listedRepoFolders(hubDir: URL, seedVR2Repo: String?, gemmaRepo: String?) -> [URL] {
        let models = FluxModelVariant.allModels.flatMap { model in
            quantOrder.compactMap { model.hubCacheFolder(quantize: $0, hubDir: hubDir) }
        }
        let tools = [seedVR2Repo, gemmaRepo].compactMap { $0 }
            .map { ModelDownloadStore.cacheFolder(repo: $0, hubDir: hubDir) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        return models + tools
    }
}

import Foundation

/// The JSON metadata a family writes beside each image it saves.
nonisolated protocol SidecarMetadata: Codable {}

nonisolated extension GenerationMetadata: SidecarMetadata {}
nonisolated extension Ideogram4Metadata: SidecarMetadata {}
nonisolated extension Krea2Metadata: SidecarMetadata {}
nonisolated extension ZImageMetadata: SidecarMetadata {}
nonisolated extension Qwen21Metadata: SidecarMetadata {}
nonisolated extension SeedVR2Metadata: SidecarMetadata {}

/// One image's sidecar, read once and classified as the family that wrote it.
/// The gallery and a SeedVR2 upscale both use this, so they always agree.
nonisolated enum AnySidecar {
    case flux(GenerationMetadata)
    case ideogram4(Ideogram4Metadata)
    case krea2(Krea2Metadata)
    case zimage(ZImageMetadata)
    case qwen21(Qwen21Metadata)
    case seedVR2(SeedVR2Metadata)

    /// Reads and classifies the sidecar beside `imagePath`. Nil when there is
    /// none, or when it does not decode as the family its keys name.
    static func read(forImageAt imagePath: String) -> Self? {
        guard let data = try? Data(contentsOf: MetadataSidecar.sidecarURL(for: imagePath)) else { return nil }
        return classify(data: data, fileName: (imagePath as NSString).lastPathComponent)
    }

    /// Classifies by the keys only one family writes, then decodes as that
    /// family alone. A sidecar that fails its own family's decode (a Flux model
    /// this build does not know, say) is no family, not the next one that fits.
    ///
    /// Krea 2 and Z-Image sidecars from before `modelVariant` have no key of
    /// their own and the same shape, so the `zimage` file prefix decides those.
    static func classify(data: Data, fileName: String) -> Self? {
        guard let keys = MetadataSidecar.decode(TopLevelKeys.self, from: data)?.names else { return nil }
        if keys.contains("sourcePath") {
            return MetadataSidecar.decode(SeedVR2Metadata.self, from: data).map(Self.seedVR2)
        }
        if keys.contains("caption") {
            return MetadataSidecar.decode(Ideogram4Metadata.self, from: data).map(Self.ideogram4)
        }
        if keys.contains("customBaseModel") {
            return MetadataSidecar.decode(GenerationMetadata.self, from: data).map(Self.flux)
        }
        if keys.contains("isEditMode") {
            return MetadataSidecar.decode(Qwen21Metadata.self, from: data).map(Self.qwen21)
        }
        if keys.contains("modelVariant") || fileName.lowercased().hasPrefix("zimage") {
            return MetadataSidecar.decode(ZImageMetadata.self, from: data).map(Self.zimage)
        }
        return MetadataSidecar.decode(Krea2Metadata.self, from: data).map(Self.krea2)
    }
}

/// The key names of a JSON object, without decoding any values.
nonisolated private struct TopLevelKeys: Decodable {
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? {
            nil
        }

        init(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue _: Int) {
            nil
        }
    }

    let names: Set<String>

    init(from decoder: Decoder) throws {
        names = try Set(decoder.container(keyedBy: Key.self).allKeys.map(\.stringValue))
    }
}

nonisolated extension GallerySidecars {
    init(_ sidecar: AnySidecar?) {
        self.init()
        switch sidecar {
        case let .flux(meta): flux = meta
        case let .ideogram4(meta): ideogram4 = meta
        case let .krea2(meta): krea2 = meta
        case let .zimage(meta): zimage = meta
        case let .qwen21(meta): qwen21 = meta
        case let .seedVR2(meta): seedVR2 = meta
        case nil: break
        }
    }
}

nonisolated extension SeedVR2Source {
    /// The generation an upscale's source came from. An upscale of an upscale
    /// carries that one's own source forward, one hop, so the recipe survives.
    init(_ sidecar: AnySidecar?) {
        if case let .seedVR2(prior) = sidecar {
            self.init(
                flux: prior.sourceFlux, ideogram4: prior.sourceIdeogram4, krea2: prior.sourceKrea2,
                zimage: prior.sourceZImage, qwen21: prior.sourceQwen21
            )
        } else {
            let found = GallerySidecars(sidecar)
            self.init(
                flux: found.flux, ideogram4: found.ideogram4, krea2: found.krea2,
                zimage: found.zimage, qwen21: found.qwen21
            )
        }
    }
}

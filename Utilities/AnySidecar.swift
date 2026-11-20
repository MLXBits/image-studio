import Foundation

/// The family a sidecar belongs to, as the `family` tag every sidecar carries
/// from this build on. The raw values are written to disk: never change one.
nonisolated enum SidecarFamily: String, CaseIterable {
    case flux, ideogram4, krea2, zimage, qwen21, seedvr2
}

/// The JSON metadata a family writes beside each image it saves.
/// ``MetadataSidecar/write(_:for:)`` sets ``family`` from ``sidecarFamily``.
nonisolated protocol SidecarMetadata: Codable {
    static var sidecarFamily: SidecarFamily { get }
    /// The tag as stored: a string, so a tag this build does not know still decodes.
    var family: String? { get set }
}

nonisolated extension GenerationMetadata: SidecarMetadata {
    static let sidecarFamily = SidecarFamily.flux
}

nonisolated extension Ideogram4Metadata: SidecarMetadata {
    static let sidecarFamily = SidecarFamily.ideogram4
}

nonisolated extension Krea2Metadata: SidecarMetadata {
    static let sidecarFamily = SidecarFamily.krea2
}

nonisolated extension ZImageMetadata: SidecarMetadata {
    static let sidecarFamily = SidecarFamily.zimage
}

nonisolated extension Qwen21Metadata: SidecarMetadata {
    static let sidecarFamily = SidecarFamily.qwen21
}

nonisolated extension SeedVR2Metadata: SidecarMetadata {
    static let sidecarFamily = SidecarFamily.seedvr2
}

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
    /// none, or when it does not decode as its family.
    static func read(forImageAt imagePath: String) -> Self? {
        guard let data = try? Data(contentsOf: MetadataSidecar.sidecarURL(for: imagePath)) else { return nil }
        return classify(data: data, fileName: (imagePath as NSString).lastPathComponent)
    }

    /// Classifies by the sidecar's `family` tag, then decodes it as that family
    /// alone. A tagged sidecar is trusted: one that fails its family's decode, or
    /// carries a tag this build does not know, is no family rather than a guess.
    /// Only a sidecar with no tag (written before it) goes to ``legacyFamily(keys:fileName:)``.
    static func classify(data: Data, fileName: String) -> Self? {
        guard let top = MetadataSidecar.decode(TopLevelKeys.self, from: data) else { return nil }
        let family: SidecarFamily
        if let tag = top.family {
            guard let known = SidecarFamily(rawValue: tag) else { return nil }
            family = known
        } else {
            family = legacyFamily(keys: top.names, fileName: fileName)
        }
        return decode(data, as: family)
    }

    private static func decode(_ data: Data, as family: SidecarFamily) -> Self? {
        switch family {
        case .flux: MetadataSidecar.decode(GenerationMetadata.self, from: data).map(flux)
        case .ideogram4: MetadataSidecar.decode(Ideogram4Metadata.self, from: data).map(ideogram4)
        case .krea2: MetadataSidecar.decode(Krea2Metadata.self, from: data).map(krea2)
        case .zimage: MetadataSidecar.decode(ZImageMetadata.self, from: data).map(zimage)
        case .qwen21: MetadataSidecar.decode(Qwen21Metadata.self, from: data).map(qwen21)
        case .seedvr2: MetadataSidecar.decode(SeedVR2Metadata.self, from: data).map(seedVR2)
        }
    }

    /// LEGACY: the family of a sidecar written before the `family` tag, from the
    /// keys only one family writes. Remove, with the untagged-sidecar tests, once
    /// untagged sidecars no longer need reading.
    ///
    /// Krea 2 has no key of its own, and neither does Z-Image from before
    /// `modelVariant`. The two share a shape, so the `zimage` file prefix
    /// decides those, and anything left over is Krea 2.
    private static func legacyFamily(keys: Set<String>, fileName: String) -> SidecarFamily {
        if keys.contains("sourcePath") {
            return .seedvr2
        }
        if keys.contains("caption") {
            return .ideogram4
        }
        if keys.contains("customBaseModel") {
            return .flux
        }
        if keys.contains("isEditMode") {
            return .qwen21
        }
        if keys.contains("modelVariant") || fileName.lowercased().hasPrefix("zimage") {
            return .zimage
        }
        return .krea2
    }
}

/// The key names of a JSON object, and its `family` tag if it has a string one.
/// No other value is decoded.
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
    let family: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        names = Set(container.allKeys.map(\.stringValue))
        family = try? container.decodeIfPresent(String.self, forKey: Key(stringValue: "family"))
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

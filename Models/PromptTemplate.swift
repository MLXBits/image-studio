import Foundation

// MARK: - Helpers

private extension UUID {
    /// Convenience init for stable hardcoded UUIDs. Only used for built-in template IDs
    /// where the string is guaranteed valid at compile time.
    init(fixed string: String) {
        guard let value = UUID(uuidString: string) else {
            preconditionFailure("Invalid UUID string: \(string)")
        }
        self = value
    }
}

// MARK: - Category

enum TemplateCategory: String, CaseIterable, Codable {
    case lighting = "Lighting"
    case camera = "Camera"
    case detail = "Detail"
    case shotType = "Shot Type"
    case custom = "Custom"

    var displayName: String { rawValue }
}

// MARK: - PromptTemplate

struct PromptTemplate: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var positiveTemplate: String
    var negativeTemplate: String
    var category: TemplateCategory
    var isBuiltIn: Bool
    /// One-line use-case hint shown in the picker. Empty = no hint displayed.
    var useCases: String
    /// Asset image name (built-ins) or absolute file path (custom). Nil = no thumbnail.
    var exampleImageName: String?

    init(
        id: UUID = UUID(),
        name: String,
        positiveTemplate: String,
        negativeTemplate: String = "",
        category: TemplateCategory,
        isBuiltIn: Bool = false,
        useCases: String = "",
        exampleImageName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.positiveTemplate = positiveTemplate
        self.negativeTemplate = negativeTemplate
        self.category = category
        self.isBuiltIn = isBuiltIn
        self.useCases = useCases
        self.exampleImageName = exampleImageName
    }

    /// Returns the composed (positive, negative) prompts.
    ///
    /// - Parameters:
    ///   - prompt: The raw user prompt.
    ///   - negativePrompt: The raw user negative prompt.
    ///   - supportsNegativePrompt: Whether the selected model accepts a negative prompt.
    func apply(
        to prompt: String,
        negativePrompt: String,
        supportsNegativePrompt: Bool
    ) -> (positive: String, negative: String) {
        let positive: String
        let trimmedTemplate = positiveTemplate.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedTemplate.contains("{prompt}") {
            positive = trimmedTemplate.replacingOccurrences(of: "{prompt}", with: prompt)
        } else if trimmedTemplate.isEmpty {
            positive = prompt
        } else if prompt.isEmpty {
            positive = trimmedTemplate
        } else {
            positive = "\(prompt), \(trimmedTemplate)"
        }

        let negative: String
        if supportsNegativePrompt, !negativeTemplate.isEmpty {
            let parts = [negativePrompt, negativeTemplate].filter { !$0.isEmpty }
            negative = parts.joined(separator: ", ")
        } else {
            negative = negativePrompt
        }

        return (positive, negative)
    }
}

// MARK: - Built-in Templates

enum BuiltInTemplates {
    static let all: [PromptTemplate] = [
        // ── Lighting ──────────────────────────────────────────────────────────
        PromptTemplate(
            id: UUID(fixed: "A1000001-0000-0000-0000-000000000001"),
            name: "Golden Hour",
            positiveTemplate: "{prompt}, golden hour lighting, warm sunlight, long soft shadows, amber glow",
            category: .lighting,
            isBuiltIn: true,
            useCases: "Outdoor portraits, travel, landscapes, romantic or editorial scenes where warmth and depth matter",
            exampleImageName: "template_goldenhour"
        ),
        PromptTemplate(
            id: UUID(fixed: "A1000001-0000-0000-0000-000000000002"),
            name: "Studio Light",
            positiveTemplate: "{prompt}, professional studio lighting, soft box, clean white background, even illumination",
            category: .lighting,
            isBuiltIn: true,
            useCases: "Headshots, product shots, e-commerce, catalog and editorial work requiring clean, controlled light",
            exampleImageName: "template_studiolight"
        ),
        PromptTemplate(
            id: UUID(fixed: "A1000001-0000-0000-0000-000000000003"),
            name: "Cinematic",
            positiveTemplate: "{prompt}, cinematic lighting, dramatic shadows, high contrast, moody atmosphere",
            category: .lighting,
            isBuiltIn: true,
            useCases: "Film stills, dramatic portraits, narrative scenes, concept art, anything that needs mood and tension",
            exampleImageName: "template_cinematic"
        ),
        PromptTemplate(
            id: UUID(fixed: "A1000001-0000-0000-0000-000000000004"),
            name: "Neon Glow",
            positiveTemplate: "{prompt}, neon lighting, vivid colors, dark environment, cyberpunk glow, reflective surfaces",
            category: .lighting,
            isBuiltIn: true,
            useCases: "Cyberpunk, nightlife, tech and gaming visuals, music, futuristic editorial",
            exampleImageName: "template_neonglow"
        ),

        // ── Camera ────────────────────────────────────────────────────────────
        PromptTemplate(
            id: UUID(fixed: "A1000001-0000-0000-0000-000000000011"),
            name: "Portrait 85mm",
            positiveTemplate: "{prompt}, 85mm portrait lens, shallow depth of field, creamy bokeh background, f/1.8",
            category: .camera,
            isBuiltIn: true,
            useCases: "Headshots, professional portraits, dating profiles, flattering face compression",
            exampleImageName: "template_portrait85mm"
        ),
        PromptTemplate(
            id: UUID(fixed: "A1000001-0000-0000-0000-000000000012"),
            name: "Wide Angle",
            positiveTemplate: "{prompt}, wide angle lens, 24mm, expansive environment, full scene context",
            category: .camera,
            isBuiltIn: true,
            useCases: "Architecture, interiors, landscapes, group shots where context matters",
            exampleImageName: "template_wideangle"
        ),
        PromptTemplate(
            id: UUID(fixed: "A1000001-0000-0000-0000-000000000013"),
            name: "Macro",
            positiveTemplate: "{prompt}, macro photography, extreme close-up, ultra-fine detail, shallow depth of field",
            category: .camera,
            isBuiltIn: true,
            useCases: "Jewelry, insects, flowers, textures, skin detail, food photography",
            exampleImageName: "template_macro"
        ),
        PromptTemplate(
            id: UUID(fixed: "A1000001-0000-0000-0000-000000000014"),
            name: "Film 35mm",
            positiveTemplate: "{prompt}, shot on 35mm film, film grain, analog photography, Kodak Portra, warm tones",
            category: .camera,
            isBuiltIn: true,
            useCases: "Travel, street photography, documentary, nostalgic editorial",
            exampleImageName: "template_film35mm"
        ),

        // ── Detail ────────────────────────────────────────────────────────────
        PromptTemplate(
            id: UUID(fixed: "A1000001-0000-0000-0000-000000000021"),
            name: "Photorealistic 8K",
            positiveTemplate: "{prompt}, photorealistic, 8K resolution, skin pores visible, ultra-detailed, sharp focus, RAW photo",
            negativeTemplate: "illustration, cartoon, painting, anime, sketch, cgi, 3d render",
            category: .detail,
            isBuiltIn: true,
            useCases: "high attention to detail, ultra realistic",
            exampleImageName: "template_photorealistic8k"
        ),
        PromptTemplate(
            id: UUID(fixed: "A1000001-0000-0000-0000-000000000022"),
            name: "Painterly",
            positiveTemplate: "{prompt}, oil painting, painterly brushstrokes, impasto, sfumato, high contrast palette",
            negativeTemplate: "photo, photorealistic, photography, camera",
            category: .detail,
            isBuiltIn: true,
            useCases: "Makes an image look like an oil painting",
            exampleImageName: "template_painterly"
        ),
        PromptTemplate(
            id: UUID(fixed: "A1000001-0000-0000-0000-000000000023"),
            name: "Illustration",
            positiveTemplate: "{prompt}, digital illustration, clean lines, stylized, concept art, professional artwork",
            negativeTemplate: "photo, photorealistic, photography",
            category: .detail,
            isBuiltIn: true,
            useCases: "digital artwork",
            exampleImageName: "template_illustration"
        ),

        // ── Shot Type ─────────────────────────────────────────────────────────
        PromptTemplate(
            id: UUID(fixed: "A1000001-0000-0000-0000-000000000031"),
            name: "POV",
            positiveTemplate: "{prompt}, point of view shot, first person perspective, immersive, POV",
            category: .shotType,
            isBuiltIn: true,
            useCases: "Action sequences, first-person experiences, immersive storytelling",
            exampleImageName: "template_pov"
        ),
        PromptTemplate(
            id: UUID(fixed: "A1000001-0000-0000-0000-000000000032"),
            name: "Extreme Close-Up",
            positiveTemplate: "{prompt}, extreme close-up shot, XCU, filling the frame, intense detail",
            category: .shotType,
            isBuiltIn: true,
            useCases: "Eyes, lips, skin texture — maximum emotional intensity or fine detail",
            exampleImageName: "template_extremecloseup"
        ),
        PromptTemplate(
            id: UUID(fixed: "A1000001-0000-0000-0000-000000000033"),
            name: "Close-Up Portrait",
            positiveTemplate: "{prompt}, close-up portrait, face-centered, intimate framing, head and shoulders",
            category: .shotType,
            isBuiltIn: true,
            useCases: "Headshots, emotion-forward portraits, social media profile photos",
            exampleImageName: "template_closeupportrait"
        ),
        PromptTemplate(
            id: UUID(fixed: "A1000001-0000-0000-0000-000000000034"),
            name: "Profile",
            positiveTemplate: "{prompt}, side profile view, lateral angle",
            category: .shotType,
            isBuiltIn: true,
            useCases: "side views, dramatic reveals, coin-style character portraits",
            exampleImageName: "template_profile"
        ),
        PromptTemplate(
            id: UUID(fixed: "A1000001-0000-0000-0000-000000000035"),
            name: "¾ Portrait",
            positiveTemplate: "{prompt}, three-quarter view, 3/4 angle portrait, slight turn",
            category: .shotType,
            isBuiltIn: true,
            useCases: "Classic editorial, LinkedIn, most flattering angle for most faces",
            exampleImageName: "template_threequarterportrait"
        ),
        PromptTemplate(
            id: UUID(fixed: "A1000001-0000-0000-0000-000000000036"),
            name: "Full Body",
            positiveTemplate: "{prompt}, full body shot, head to toe, standing",
            category: .shotType,
            isBuiltIn: true,
            useCases: "Fashion, fitness, costume/cosplay, character design reference",
            exampleImageName: "template_fullbody"
        ),
        PromptTemplate(
            id: UUID(fixed: "A1000001-0000-0000-0000-000000000037"),
            name: "Aerial",
            positiveTemplate: "{prompt}, aerial view, bird's eye perspective, drone shot, top-down",
            category: .shotType,
            isBuiltIn: true,
            useCases: "Cityscapes, nature, real estate, events, maps, overhead food",
            exampleImageName: "template_aerial"
        ),
        PromptTemplate(
            id: UUID(fixed: "A1000001-0000-0000-0000-000000000038"),
            name: "Action",
            positiveTemplate: "{prompt}, action shot, motion blur, dynamic pose, high shutter speed, energy",
            category: .shotType,
            isBuiltIn: true,
            useCases: "Sports, dance, wildlife, anything requiring conveyed movement",
            exampleImageName: "template_action"
        ),
        PromptTemplate(
            id: UUID(fixed: "A1000001-0000-0000-0000-000000000039"),
            name: "Landscape",
            positiveTemplate: "{prompt}, landscape photography, wide vista, environmental storytelling, horizon",
            category: .shotType,
            isBuiltIn: true,
            useCases: "Travel, nature, environmental context, wide scene-setting shots",
            exampleImageName: "template_landscape"
        ),
    ]
}

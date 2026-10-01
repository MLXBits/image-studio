@testable import MLXBits_Image_Studio
import Testing

/// Tests for ``ComfyUIClient/seedVR2Geometry(sourceWidth:sourceHeight:scale:softness:)`` — the port of mflux's
/// `SeedVR2Util.preprocess_image` sizing that keeps a remote upscale the same size, and softened the same way, as a local one.
/// Expected values were produced by running mflux's own formulas (`ScaleFactor.get_scaled_value` with 16-px steps, even
/// flooring, `factor = 1 + softness × 7`) on the same inputs.
@Suite("seedVR2Geometry matches mflux")
struct ComfySeedVR2GeometryTests {
    @Test func noSoftnessHasNoPreBlur() {
        let g = ComfyUIClient.seedVR2Geometry(sourceWidth: 1024, sourceHeight: 576, scale: 2, softness: 0)
        #expect(g == ComfyUIClient.SeedVR2Geometry(width: 2048, height: 1152))
    }

    @Test func shortSideFloorsToSixteenAndSidesFloorToEven() {
        // 767 × 3 = 2301 → 2288 on the short side; the long side follows the 2288/767 ratio and floors to even.
        let g = ComfyUIClient.seedVR2Geometry(sourceWidth: 1023, sourceHeight: 767, scale: 3, softness: 0.35)
        #expect(g == ComfyUIClient.SeedVR2Geometry(width: 3050, height: 2288, softWidth: 884, softHeight: 663))
    }

    @Test func fullSoftnessDividesByEight() {
        let g = ComfyUIClient.seedVR2Geometry(sourceWidth: 832, sourceHeight: 1216, scale: 4, softness: 1.0)
        #expect(g == ComfyUIClient.SeedVR2Geometry(width: 3328, height: 4864, softWidth: 416, softHeight: 608))
    }

    @Test func smallSoftnessStillPreBlurs() {
        let g = ComfyUIClient.seedVR2Geometry(sourceWidth: 1000, sourceHeight: 1001, scale: 2, softness: 0.05)
        #expect(g == ComfyUIClient.SeedVR2Geometry(width: 2000, height: 2002, softWidth: 1481, softHeight: 1482))
    }

    @Test func softnessIsClamped() {
        let over = ComfyUIClient.seedVR2Geometry(sourceWidth: 832, sourceHeight: 1216, scale: 4, softness: 3.0)
        #expect(over.softWidth == 416)
        let under = ComfyUIClient.seedVR2Geometry(sourceWidth: 832, sourceHeight: 1216, scale: 4, softness: -1.0)
        #expect(under.softWidth == nil)
    }
}

/// Tests for ``ComfyUIClient/pickSeedVR2Files(unets:vaes:is7B:)`` against the file names on the live server.
@Suite("pickSeedVR2Files")
struct ComfySeedVR2FilePickTests {
    private static let unets = [
        "krea2_turbo_fp8_scaled.safetensors",
        "seedvr2_3b_int8_convrot.safetensors",
        "seedvr2_7b_int8_convrot.safetensors",
        "seedvr2_7b_nvfp4.safetensors",
        "seedvr2_7b_sharp_nvfp4.safetensors",
    ]
    private static let vaes = ["qwen_image_vae.safetensors", "seedvr2_ema_vae_fp16.safetensors"]

    @Test func picksInt8BySize() {
        #expect(ComfyUIClient.pickSeedVR2Files(unets: Self.unets, vaes: Self.vaes, is7B: false)?.unet
            == "seedvr2_3b_int8_convrot.safetensors")
        #expect(ComfyUIClient.pickSeedVR2Files(unets: Self.unets, vaes: Self.vaes, is7B: true)?.unet
            == "seedvr2_7b_int8_convrot.safetensors")
        #expect(ComfyUIClient.pickSeedVR2Files(unets: Self.unets, vaes: Self.vaes, is7B: true)?.vae
            == "seedvr2_ema_vae_fp16.safetensors")
    }

    @Test func fallsBackToNonInt8ButNeverSharp() {
        let unets = ["seedvr2_7b_sharp_nvfp4.safetensors", "seedvr2_7b_nvfp4.safetensors"]
        #expect(ComfyUIClient.pickSeedVR2Files(unets: unets, vaes: Self.vaes, is7B: true)?.unet == "seedvr2_7b_nvfp4.safetensors")
    }

    @Test func missingModelOrVaeIsNil() {
        #expect(ComfyUIClient.pickSeedVR2Files(unets: ["seedvr2_7b_int8_convrot.safetensors"], vaes: Self.vaes, is7B: false) == nil)
        #expect(ComfyUIClient.pickSeedVR2Files(unets: Self.unets, vaes: ["qwen_image_vae.safetensors"], is7B: false) == nil)
    }
}

/// Tests for ``ComfyUIClient/buildSeedVR2Workflow(_:)`` — the wiring the server validates: two-output conditioning feeds the
/// sampler's positive/negative, the resized (and softened) image is both the model input and the colour reference, and
/// softness adds exactly one extra resize in front.
@Suite("buildSeedVR2Workflow topology")
struct ComfySeedVR2WorkflowTopologyTests {
    private static func build(softness: Double) throws -> [String: [String: Any]] {
        let input = ComfyUIClient.SeedVR2WorkflowInput(
            imageName: "mlxbits/source.png",
            geometry: ComfyUIClient.seedVR2Geometry(sourceWidth: 1024, sourceHeight: 576, scale: 2, softness: softness),
            seed: 42,
            unetName: "seedvr2_3b_int8_convrot.safetensors",
            vaeName: "seedvr2_ema_vae_fp16.safetensors",
            saveSubfolder: "seedvr2"
        )
        return try #require(ComfyUIClient(config: .init(baseURL: "http://test")).buildSeedVR2Workflow(input) as? [String: [String: Any]])
    }

    private static func inputs(_ payload: [String: [String: Any]], _ id: String) -> [String: Any] {
        (payload[id]?["inputs"] as? [String: Any]) ?? [:]
    }

    private static func link(_ inputs: [String: Any], _ key: String) -> String? {
        guard let raw = inputs[key] as? [Any], raw.count == 2, let id = raw[0] as? String, let slot = raw[1] as? Int else { return nil }
        return "\(id):\(slot)"
    }

    @Test func plainGraphWiring() throws {
        let p = try Self.build(softness: 0)
        #expect(p.count == ComfyUIClient.seedVR2NodeCount(ComfyUIClient.seedVR2Geometry(
            sourceWidth: 1024, sourceHeight: 576, scale: 2, softness: 0
        )))
        #expect(p["SOFTEN"] == nil)
        #expect(Self.link(Self.inputs(p, "RESIZE"), "image") == "LOAD:0")
        #expect(Self.inputs(p, "RESIZE")["width"] as? Int == 2048)
        #expect(Self.inputs(p, "RESIZE")["height"] as? Int == 1152)
        #expect(Self.inputs(p, "RESIZE")["upscale_method"] as? String == "bicubic")

        let ks = Self.inputs(p, "KSAMPLER")
        #expect(Self.link(ks, "positive") == "COND:0")
        #expect(Self.link(ks, "negative") == "COND:1")
        #expect(Self.link(ks, "latent_image") == "ENCODE:0")
        #expect(ks["seed"] as? Int == 42)
        #expect(ks["steps"] as? Int == 1)

        let post = Self.inputs(p, "POST")
        #expect(Self.link(post, "original_resized_images") == "RESIZE:0")
        #expect(post["color_correction_method"] as? String == "lab")
        #expect(Self.inputs(p, "SAVE")["filename_prefix"] as? String == "mlxbits/seedvr2")
        #expect(Self.inputs(p, "LOAD")["image"] as? String == "mlxbits/source.png")
    }

    @Test func softnessInsertsPreBlurBeforeResize() throws {
        let p = try Self.build(softness: 0.5)
        #expect(p.count == 12)
        #expect(Self.link(Self.inputs(p, "SOFTEN"), "image") == "LOAD:0")
        #expect(Self.link(Self.inputs(p, "RESIZE"), "image") == "SOFTEN:0")
        // factor 4.5 on 2048×1152
        #expect(Self.inputs(p, "SOFTEN")["width"] as? Int == 455)
        #expect(Self.inputs(p, "SOFTEN")["height"] as? Int == 256)
    }
}

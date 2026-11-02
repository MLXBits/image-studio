import Foundation
@testable import MLXBits_Image_Studio
import Testing

// MARK: - FLUX.2 topology

/// Topology pins for the 8 bundled FLUX.2 templates (`comfy_templates/flux2/`). Each template is loaded
/// through the real `ComfyTemplate.load(familyFlowKey:)` bundle path and its node set + critical wiring
/// asserted. Deterministic: no network, no live server (live validation is deferred to the user).
@Suite("FLUX.2 topology")
struct FluxTopologyTests {
    /// The 8 flow keys: `<size>-<flow>-<variant>` (confirmed lowercase, flat naming).
    static let t2iKeys = ["flux2/4b-t2i-base", "flux2/4b-t2i-distilled", "flux2/9b-t2i-base", "flux2/9b-t2i-distilled"]
    static let i2eKeys = ["flux2/4b-i2e-base", "flux2/4b-i2e-distilled", "flux2/9b-i2e-base", "flux2/9b-i2e-distilled"]

    /// The FLUX.2 advanced sampler stack (no classic KSampler) every template must carry.
    static let advancedStack = [
        "UNETLoader", "CFGGuider", "CLIPLoader", "VAELoader", "SaveImage",
        "Flux2Scheduler", "KSamplerSelect", "RandomNoise", "EmptyFlux2LatentImage",
    ]

    // MARK: helpers

    /// The node IDs of the given class type.
    private static func ids(_ t: ComfyTemplate, _ classType: String) -> [String] {
        t.nodes.filter { $0.value.classType == classType }.keys.sorted()
    }

    /// The template's single CFGGuider, or nil when the count is not exactly one.
    private static func guider(_ t: ComfyTemplate) -> ComfyNode? {
        let matches = t.nodes.filter { $0.value.classType == "CFGGuider" }
        return matches.count == 1 ? matches.first?.value : nil
    }

    /// A scalar input as a Double (whole-number JSON numbers decode as `.int`).
    private static func number(_ value: ComfyInputValue?) -> Double? {
        switch value {
        case let .scalar(.int(n)): Double(n)
        case let .scalar(.double(d)): d
        default: nil
        }
    }

    /// A `CLIPTextEncode` with empty (negative) text, or nil.
    private static func negativeEncode(_ t: ComfyTemplate) -> String? {
        t.nodes.first { $0.value.classType == "CLIPTextEncode" && $0.value.inputs["text"] == .scalar(.string("")) }?.key
    }

    /// Asserts the template carries the advanced stack and its CFGGuider.model is wired straight to the
    /// UNETLoader output — the model consumer for FLUX.2 LoRA insertion (no KSampler in this stack).
    private static func assertAdvancedStack(_ t: ComfyTemplate, key: String) {
        for classType in advancedStack {
            #expect(!ids(t, classType).isEmpty, "\(key): missing \(classType)")
        }
        guard let unet = ids(t, "UNETLoader").first, let guider = Self.guider(t) else {
            Issue.record("\(key): need exactly one UNETLoader + CFGGuider to check wiring")
            return
        }
        #expect(guider.inputs["model"] == .ref(nodeID: unet, outputIndex: 0), "\(key): CFGGuider.model must be [\(unet), 0]")
    }

    // MARK: t2i

    /// All 4 t2i templates carry the advanced stack, and CFGGuider.model is wired to the UNETLoader.
    @Test func t2iTemplatesWireTheAdvancedStack() throws {
        for key in Self.t2iKeys {
            try Self.assertAdvancedStack(ComfyTemplate.load(familyFlowKey: key), key: key)
        }
    }

    /// Distilled t2i runs CFG-free: a ConditioningZeroOut node exists and CFGGuider.cfg is 1.
    @Test func t2iDistilledUsesZeroOutAndCfgOne() throws {
        // 9b-t2i-distilled is pinned separately (`nineBT2iDistilledShippedAsBaseStack`): the shipped
        // template is a re-export of the base stack, not distilled.
        let t = try ComfyTemplate.load(familyFlowKey: "flux2/4b-t2i-distilled")
        #expect(!Self.ids(t, "ConditioningZeroOut").isEmpty, "4b-t2i-distilled: missing ConditioningZeroOut")
        let g = try #require(Self.guider(t))
        #expect(Self.number(g.inputs["cfg"]) == 1, "4b-t2i-distilled: cfg must be 1, got \(Self.number(g.inputs["cfg"]) ?? -1)")
    }

    /// Base t2i uses real CFG: a negative `CLIPTextEncode` (empty text) exists and cfg is not 1.
    @Test func t2iBaseHasNegativeEncodeAndCfgAboveOne() throws {
        for key in ["flux2/4b-t2i-base", "flux2/9b-t2i-base"] {
            let t = try ComfyTemplate.load(familyFlowKey: key)
            #expect(Self.negativeEncode(t) != nil, "\(key): missing negative CLIPTextEncode (empty text)")
            let g = try #require(Self.guider(t))
            #expect(Self.number(g.inputs["cfg"]) != 1, "\(key): cfg must not be 1 for a base template")
        }
    }

    /// DEVIATION FROM PLAN — pinned as shipped: `flux2/9b-t2i-distilled` is byte-identical to
    /// `flux2/9b-t2i-base` except the UNet filename (`flux-2-klein-9b-fp8` vs
    /// `flux-2-klein-base-9b-fp8`). It carries the base stack (cfg 5, negative encode, no
    /// ConditioningZeroOut), not the distilled stack. If the template is re-exported as truly
    /// distilled, update this test and `t2iDistilledUsesZeroOutAndCfgOne`.
    @Test func nineBT2iDistilledShippedAsBaseStack() throws {
        let t = try ComfyTemplate.load(familyFlowKey: "flux2/9b-t2i-distilled")
        #expect(Self.ids(t, "ConditioningZeroOut").isEmpty, "9b-t2i-distilled: unexpectedly has ConditioningZeroOut")
        #expect(Self.negativeEncode(t) != nil, "9b-t2i-distilled: negative encode disappeared")
        let g = try #require(Self.guider(t))
        #expect(Self.number(g.inputs["cfg"]) == 5, "9b-t2i-distilled: cfg changed from 5")
    }

    // MARK: i2e

    /// All 4 i2e (edit) templates carry the advanced stack, reference conditioning (ReferenceLatent),
    /// and >= 2 LoadImage nodes (currently 2 per template; the user will re-export with 6 slots later).
    @Test func i2eTemplatesWireTheAdvancedStackAndReferences() throws {
        for key in Self.i2eKeys {
            let t = try ComfyTemplate.load(familyFlowKey: key)
            Self.assertAdvancedStack(t, key: key)
            #expect(!Self.ids(t, "ReferenceLatent").isEmpty, "\(key): missing ReferenceLatent")
            #expect(Self.ids(t, "LoadImage").count >= 2, "\(key): expected >= 2 LoadImage, got \(Self.ids(t, "LoadImage").count)")
        }
    }

    /// Distilled i2e runs CFG-free: ConditioningZeroOut + cfg 1.
    @Test func i2eDistilledUsesZeroOutAndCfgOne() throws {
        for key in ["flux2/4b-i2e-distilled", "flux2/9b-i2e-distilled"] {
            let t = try ComfyTemplate.load(familyFlowKey: key)
            #expect(!Self.ids(t, "ConditioningZeroOut").isEmpty, "\(key): missing ConditioningZeroOut")
            let g = try #require(Self.guider(t))
            #expect(Self.number(g.inputs["cfg"]) == 1, "\(key): cfg must be 1, got \(Self.number(g.inputs["cfg"]) ?? -1)")
        }
    }

    /// Base i2e uses real CFG: a negative `CLIPTextEncode` (empty text) exists and cfg is not 1.
    @Test func i2eBaseHasNegativeEncodeAndCfgAboveOne() throws {
        for key in ["flux2/4b-i2e-base", "flux2/9b-i2e-base"] {
            let t = try ComfyTemplate.load(familyFlowKey: key)
            #expect(Self.negativeEncode(t) != nil, "\(key): missing negative CLIPTextEncode (empty text)")
            let g = try #require(Self.guider(t))
            #expect(Self.number(g.inputs["cfg"]) != 1, "\(key): cfg must not be 1 for a base template")
        }
    }
}

// MARK: - FLUX.2 bundle

/// Bundle verification: all 8 templates + 8 param maps must resolve through the real
/// `ComfyTemplate.load` / `ComfyParamMap.load` paths (`Bundle.main`, the `comfy_templates/flux2/`
/// subdirectory via the folder reference). A folder ref regressing to a group, or a filename drift,
/// fails here instead of at runtime.
@Suite("FLUX.2 bundle")
struct FluxBundleTests {
    static let keys = FluxTopologyTests.t2iKeys + FluxTopologyTests.i2eKeys

    @Test func allEightTemplatesLoadFromTheAppBundle() {
        for key in Self.keys {
            #expect((try? ComfyTemplate.load(familyFlowKey: key)) != nil, "\(key).json missing from the app bundle")
        }
    }

    @Test func allEightParamMapsLoadFromTheAppBundle() {
        for key in Self.keys {
            #expect((try? ComfyParamMap.load(familyFlowKey: key)) != nil, "\(key).parammap.json missing from the app bundle")
        }
    }

    /// Every param-map target must resolve in its own template (node + input): a stale sidecar after a
    /// re-export would throw at render time — catch it at test time instead.
    @Test func paramMapTargetsResolveInTheirTemplates() throws {
        for key in Self.keys {
            let t = try ComfyTemplate.load(familyFlowKey: key)
            let m = try ComfyParamMap.load(familyFlowKey: key)
            for (param, target) in m.params {
                let node = t.nodes[target.node]
                #expect(node != nil, "\(key): param \(param) targets missing node \(target.node)")
                #expect(node?.inputs[target.input] != nil, "\(key): param \(param) targets missing input \(target.input)")
            }
        }
    }
}

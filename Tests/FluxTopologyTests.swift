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

    /// Distilled t2i runs CFG-free: a ConditioningZeroOut node exists with a wired conditioning input, and CFGGuider.cfg is 1.
    @Test func t2iDistilledUsesZeroOutAndCfgOne() throws {
        for key in ["flux2/4b-t2i-distilled", "flux2/9b-t2i-distilled"] {
            let t = try ComfyTemplate.load(familyFlowKey: key)
            let zeroIDs = Self.ids(t, "ConditioningZeroOut")
            #expect(!zeroIDs.isEmpty, "\(key): missing ConditioningZeroOut")
            for zid in zeroIDs {
                let z = try #require(t.nodes[zid])
                #expect(z.inputs["conditioning"] != nil, "\(key): ConditioningZeroOut \(zid) missing 'conditioning' input")
            }
            let g = try #require(Self.guider(t))
            #expect(Self.number(g.inputs["cfg"]) == 1, "\(key): cfg must be 1, got \(Self.number(g.inputs["cfg"]) ?? -1)")
        }
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

    // MARK: i2e

    /// All 4 i2e (edit) templates carry the advanced stack, reference conditioning (ReferenceLatent),
    /// and exactly 6 LoadImage nodes (one per reference slot, source_image through source_image_5).
    @Test func i2eTemplatesWireTheAdvancedStackAndReferences() throws {
        for key in Self.i2eKeys {
            let t = try ComfyTemplate.load(familyFlowKey: key)
            Self.assertAdvancedStack(t, key: key)
            #expect(!Self.ids(t, "ReferenceLatent").isEmpty, "\(key): missing ReferenceLatent")
            #expect(Self.ids(t, "LoadImage").count == 6, "\(key): expected == 6 LoadImage, got \(Self.ids(t, "LoadImage").count)")
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

    /// Every `VAEEncode` node in every i2e template must carry a `vae` input wired to the template's
    /// VAELoader — ComfyUI rejects the graph with a required-input error when a job keeps 3+ reference
    /// slots and a VAEEncode is missing its `vae`.
    @Test func i2eVAEEncodeNodesAllReferenceTheVAE() throws {
        for key in Self.i2eKeys {
            let t = try ComfyTemplate.load(familyFlowKey: key)
            for vaeID in Self.ids(t, "VAEEncode") {
                let node = try #require(t.nodes[vaeID])
                #expect(node.inputs["vae"] != nil, "\(key): VAEEncode \(vaeID) missing 'vae' input")
            }
        }
    }

    /// The param-map slot order (`referenceSlotOrder`: source_image, source_image_1..5) must equal the order the
    /// model actually sees the references — the ReferenceLatent chain traced from `CFGGuider.positive` (head to
    /// tail). A re-export that drifts the two orders would let a prompt's "image N" edit with the wrong reference,
    /// and the i2e excision would stop removing a contiguous tail. (FLUX.2 Klein interprets a prompt's "image N"
    /// as the N-th entry in reference_latents, i.e. the N-th slot in this order.)
    @Test func i2eReferenceSlotOrderMatchesCFGGuiderChain() throws {
        for key in Self.i2eKeys {
            let t = try ComfyTemplate.load(familyFlowKey: key)
            let m = try ComfyParamMap.load(familyFlowKey: key)
            guard let guider = Self.guider(t) else {
                Issue.record("\(key): need exactly one CFGGuider to trace the chain")
                continue
            }
            guard case let .ref(nodeID: tail, _) = guider.inputs["positive"] else {
                Issue.record("\(key): CFGGuider.positive must be a node ref")
                continue
            }
            // Trace the ReferenceLatent chain from the tail (CFGGuider.positive) back to the head, collecting the
            // LoadImage each node encodes (latent -> VAEEncode -> ImageScaleToTotalPixels -> LoadImage).
            var chain: [String] = []
            var cur: String? = tail
            while let nid = cur, let node = t.nodes[nid], node.classType == "ReferenceLatent" {
                guard case let .ref(nodeID: vaeID, _) = node.inputs["latent"],
                      let vae = t.nodes[vaeID],
                      case let .ref(nodeID: scaleID, _) = vae.inputs["pixels"],
                      let scale = t.nodes[scaleID],
                      case let .ref(nodeID: loadID, _) = scale.inputs["image"] else {
                    Issue.record("\(key): chain node \(nid) does not resolve to a LoadImage")
                    break
                }
                chain.append(loadID)
                // Follow the conditioning link to the previous node in the chain (stop at a non-ReferenceLatent).
                if case let .ref(nodeID: condID, _) = node.inputs["conditioning"] {
                    cur = t.nodes[condID]?.classType == "ReferenceLatent" ? condID : nil
                } else {
                    cur = nil
                }
            }
            chain.reverse() // head -> tail
            #expect(chain.count == 6, "\(key): expected 6 reference slots in the chain, got \(chain.count)")
            #expect(m.referenceSlotOrder == chain, "\(key): referenceSlotOrder \(m.referenceSlotOrder) != chain order \(chain)")
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

import Foundation
@testable import MLXBits_Image_Studio
import Testing

// MARK: - insertLoras missing-node guard

/// The ``ComfyTemplate/render(map:params:loras:)`` → `insertLoras` guard must fail loudly when LoRAs are
/// requested but the template has no UNETLoader or KSampler to chain them between. Silently returning here
/// would run the job without the user's LoRAs and show no error — the silent-wrong-graph failure class this
/// change eliminates. With no LoRAs the missing nodes are irrelevant, so render still succeeds.
@Suite("ComfyTemplate insertLoras missing-node guard")
struct ComfyInsertLorasMissingNodeTests {
    private static let emptyMap = ComfyParamMap(params: [:])
    private static let oneLora = [ComfyLora(name: "krea2/a.safetensors", strength: 0.8)]

    /// A graph with a KSampler but NO UNETLoader — the guard's `unet` lookup fails.
    private static func makeTemplateMissingUnet() -> ComfyTemplate {
        ComfyTemplate(nodes: [
            "1": ComfyNode(classType: "KSampler", inputs: [
                "steps": .scalar(.int(20)),
                "model": .scalar(.string("unwired")),
            ]),
        ])
    }

    /// A graph with a UNETLoader but NO KSampler — the guard's `ks` lookup fails.
    private static func makeTemplateMissingKSampler() -> ComfyTemplate {
        ComfyTemplate(nodes: [
            "10": ComfyNode(classType: "UNETLoader", inputs: [
                "unet_name": .scalar(.string("krea2.safetensors")),
            ]),
        ])
    }

    /// (a) Non-empty LoRAs + no UNETLoader → throws `missingNode` (never a silent LoRA-less graph).
    @Test func missingUnetThrowsWithLoras() {
        do {
            _ = try Self.makeTemplateMissingUnet().render(map: Self.emptyMap, params: [:], loras: Self.oneLora)
            Issue.record("expected missingNode")
        } catch let e as ComfyTemplateError {
            #expect(e == .missingNode("UNETLoader/KSampler"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    /// (b) Non-empty LoRAs + no KSampler → throws `missingNode`.
    @Test func missingKSamplerThrowsWithLoras() {
        do {
            _ = try Self.makeTemplateMissingKSampler().render(map: Self.emptyMap, params: [:], loras: Self.oneLora)
            Issue.record("expected missingNode")
        } catch let e as ComfyTemplateError {
            #expect(e == .missingNode("UNETLoader/KSampler"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    /// (c) Empty LoRAs + no UNETLoader → does NOT throw: nothing to insert, so the missing node is moot.
    @Test func missingUnetDoesNotThrowWithoutLoras() throws {
        _ = try Self.makeTemplateMissingUnet().render(map: Self.emptyMap, params: [:], loras: [])
    }
}

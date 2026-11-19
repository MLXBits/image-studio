@testable import MLXBits_Image_Studio
import Testing

struct ComfyPhaseLabelTests {
    /// Node ids and classes as the bundled FLUX.2 template submits them.
    private let workflow: [String: Any] = [
        "9": ["class_type": "SaveImage", "inputs": [:]],
        "75:64": ["class_type": "SamplerCustomAdvanced", "inputs": [:]],
        "75:65": ["class_type": "VAEDecode", "inputs": [:]],
        "75:66": ["class_type": "EmptyFlux2LatentImage", "inputs": [:]],
        "75:67": ["class_type": "CLIPTextEncode", "inputs": [:]],
        "75:70": ["class_type": "UNETLoader", "inputs": [:]],
        "75:61": ["class_type": "KSamplerSelect", "inputs": [:]],
        "_meta": "not a node",
    ]

    private func label(_ id: String) -> String? {
        let classes = ComfyUIClient.classTypes(in: workflow)
        return ComfyUIClient.phaseLabel(nodeID: id, classType: classes[id])
    }

    @Test func templateNodesGetLabelsFromTheirClass() {
        #expect(label("75:64") == "Denoising")
        #expect(label("75:67") == "Encoding prompt")
        #expect(label("75:66") == "Preparing")
        #expect(label("75:65") == "Decoding & saving")
        #expect(label("9") == "Decoding & saving")
        #expect(label("75:70") == "Loading models")
        #expect(label("75:61") == nil) // KSamplerSelect only picks a sampler
    }

    @Test func classTypesSkipsNonNodes() {
        #expect(ComfyUIClient.classTypes(in: workflow)["_meta"] == nil)
        #expect(ComfyUIClient.classTypes(in: "not a workflow").isEmpty)
    }

    @Test func namedSeedVR2IdsStillWorkWithoutAClass() {
        #expect(ComfyUIClient.phaseLabel(nodeID: "KSAMPLER", classType: nil) == "Denoising")
        #expect(ComfyUIClient.phaseLabel(nodeID: "CLIP_POS", classType: nil) == "Encoding prompt")
        #expect(ComfyUIClient.phaseLabel(nodeID: "UNKNOWN", classType: nil) == nil)
        #expect(ComfyUIClient.phaseLabel(nodeID: nil, classType: nil) == nil)
    }
}

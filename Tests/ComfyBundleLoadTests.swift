import Foundation
@testable import MLXBits_Image_Studio
import Testing

// MARK: - Bundle loading (real app-bundle path)

/// Exercises the actual `Bundle.main` load path (Task 7): the bundled `comfy_templates/krea2` folder
/// reference must resolve `ComfyTemplate.load(familyFlowKey: "krea2/t2i")` → `comfy_templates/krea2/t2i.json`
/// (and the `.parammap.json` sidecars). A filename or folder-structure mismatch fails here, not at runtime.
@Suite("ComfyTemplate bundle load")
struct ComfyBundleLoadTests {
    @Test func loadsT2ITemplateFromBundle() throws {
        let template = try ComfyTemplate.load(familyFlowKey: "krea2/t2i")
        #expect(template.nodes.count == 10)
        #expect(template.nodes["30:3"]?.classType == "KSampler")
    }

    @Test func loadsT2iParamMapFromBundle() throws {
        let map = try ComfyParamMap.load(familyFlowKey: "krea2/t2i")
        #expect(map.params["prompt"] == ParamTarget(node: "30:19", input: "value"))
        #expect(map.params["steps"] == ParamTarget(node: "30:3", input: "steps"))
    }

    @Test func loadsI2ITemplateFromBundle() throws {
        let template = try ComfyTemplate.load(familyFlowKey: "krea2/i2i")
        #expect(template.nodes.count == 11)
        #expect(template.nodes["30:70"]?.classType == "LoadImage")
    }

    @Test func loadsI2iParamMapFromBundle() throws {
        let map = try ComfyParamMap.load(familyFlowKey: "krea2/i2i")
        #expect(map.params["source_image"] == ParamTarget(node: "30:70", input: "image"))
        #expect(map.params["denoise"] == ParamTarget(node: "30:3", input: "denoise"))
    }

    /// A key with no bundled template throws `notFound` (never a nil or empty template).
    @Test func missingKeyThrowsNotFound() {
        do {
            _ = try ComfyTemplate.load(familyFlowKey: "krea2/bogus")
            Issue.record("expected notFound")
        } catch let e as ComfyTemplateError {
            #expect(e == .notFound("krea2/bogus.json"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}

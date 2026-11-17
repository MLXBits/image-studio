import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// A sidecar records an empty LoRA stack as `[]`, not as an absent field, so a
/// replay of a LoRA-less image clears the form's stack. An absent field still
/// means a sidecar from before LoRA support, and replay keeps the form's stack.
@MainActor
struct SidecarLoraReplayTests {
    private let lora = LoraEntry(path: "/loras/style.safetensors", modelFamily: .krea2)

    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    @Test func everyFamilyRecordsAnEmptyStackAsEmpty() throws {
        #expect(try roundTrip(Krea2Metadata.from(job: Krea2Job())).loras == [])
        #expect(try roundTrip(ZImageMetadata.from(job: ZImageJob())).loras == [])
        #expect(try roundTrip(Ideogram4Metadata.from(job: Ideogram4Job())).loras == [])
        #expect(try roundTrip(Qwen21Metadata.from(job: Qwen21Job())).loras == [])
    }

    @Test func replayingALoraLessKrea2ImageClearsTheStack() throws {
        let meta = try roundTrip(Krea2Metadata.from(job: Krea2Job(prompt: "a fox")))
        let form = Krea2ParamsPanelState()
        form.loras = [lora]
        form.apply(metadata: meta, newSeed: false)
        #expect(form.loras.isEmpty)
    }

    @Test func replayingAPreLoraKrea2SidecarKeepsTheStack() throws {
        var meta = Krea2Metadata.from(job: Krea2Job(prompt: "a fox"))
        meta.loras = nil
        let form = Krea2ParamsPanelState()
        form.loras = [lora]
        try form.apply(metadata: roundTrip(meta), newSeed: false)
        #expect(form.loras == [lora])
    }
}

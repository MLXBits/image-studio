@testable import MLXBits_Image_Studio
import Testing

/// What each family's job reads while it runs: LoRA files, a local model folder
/// and source images. FileAccess holds them open for the job (spec §4). Repo IDs
/// and empty fields aren't files and are left out.
struct JobAccessPathsTests {
    private let lora = LoraEntry(path: "/Loras/style.safetensors")

    @Test func fluxReadsItsLorasModelAndImages() {
        let job = FluxJob(
            customModelRepo: "/Models/klein", loras: [lora], imagePath: "/Lib/a.png", editImagePaths: ["/Lib/b.png"]
        )
        #expect(Set(FluxRunnerSpec.accessPaths(job: job))
            == ["/Loras/style.safetensors", "/Models/klein", "/Lib/a.png", "/Lib/b.png"])
    }

    @Test func krea2AndZImageReadTheirLorasModelAndImage() {
        let krea2 = Krea2Job(customModelRepo: "/Models/k2", loras: [lora], imagePath: "/Lib/a.png")
        let zimage = ZImageJob(customModelRepo: "/Models/z", loras: [lora], imagePath: "/Lib/a.png")
        #expect(Set(Krea2RunnerSpec.accessPaths(job: krea2)) == ["/Loras/style.safetensors", "/Models/k2", "/Lib/a.png"])
        #expect(Set(ZImageRunnerSpec.accessPaths(job: zimage)) == ["/Loras/style.safetensors", "/Models/z", "/Lib/a.png"])
    }

    @Test func ideogramReadsItsLorasAndModel() {
        let job = Ideogram4Job(customModelRepo: "/Models/i4", loras: [lora])
        #expect(Set(Ideogram4RunnerSpec.accessPaths(job: job)) == ["/Loras/style.safetensors", "/Models/i4"])
    }

    @Test func seedVR2ReadsItsSource() {
        #expect(SeedVR2RunnerSpec.accessPaths(job: SeedVR2Job(sourcePath: "/Lib/a.png")) == ["/Lib/a.png"])
    }

    @Test func repoIDsAreLeftOut() {
        let job = FluxJob(customModelRepo: "org/model", loras: [LoraEntry(path: "org/lora")])
        #expect(FluxRunnerSpec.accessPaths(job: job).isEmpty)
    }
}

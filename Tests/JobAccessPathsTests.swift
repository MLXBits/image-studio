@testable import MLXBits_Image_Studio
import Testing

/// What each family's job reads while it runs: LoRA files, a local model folder
/// and source images. FileAccess holds them open for the job (spec §4), and a
/// job fails when one can't be reached — so the list must be exactly what the
/// runner passes on: enabled LoRAs of its own family, the custom folder only
/// when it's used, and only the images its mode reads. Repo IDs and empty
/// fields aren't files and are left out.
struct JobAccessPathsTests {
    @Test func fluxReadsItsLorasCustomModelAndImage() {
        let job = FluxJob(
            model: .custom, customModelRepo: "/Models/klein",
            loras: [LoraEntry(path: "/Loras/style.safetensors")], imagePath: "/Lib/a.png"
        )
        #expect(Set(FluxRunnerSpec.accessPaths(job: job)) == ["/Loras/style.safetensors", "/Models/klein", "/Lib/a.png"])
    }

    @Test func fluxReadsOnlyTheImagesItsModeUses() {
        let edit = FluxJob(imagePath: "/Lib/a.png", isEditMode: true, editImagePaths: ["/Lib/b.png"])
        let img2img = FluxJob(imagePath: "/Lib/a.png", isEditMode: false, editImagePaths: ["/Lib/b.png"])
        #expect(FluxRunnerSpec.accessPaths(job: edit) == ["/Lib/b.png"])
        #expect(FluxRunnerSpec.accessPaths(job: img2img) == ["/Lib/a.png"])
    }

    @Test func fluxIgnoresACustomFolderLeftOverFromTheCustomModel() {
        let job = FluxJob(model: .flux2Klein9B, customModelRepo: "/Models/old")
        #expect(FluxRunnerSpec.accessPaths(job: job).isEmpty)
    }

    /// Switching a LoRA off is how someone stops using a file that's gone.
    @Test func disabledAndOtherFamilyLorasAreLeftOut() {
        let job = FluxJob(loras: [
            LoraEntry(path: "/Loras/on.safetensors"),
            LoraEntry(path: "/Loras/off.safetensors", enabled: false),
            LoraEntry(path: "/Loras/krea.safetensors", modelFamily: .krea2),
        ])
        #expect(FluxRunnerSpec.accessPaths(job: job) == ["/Loras/on.safetensors"])
    }

    @Test func krea2AndZImageReadTheirLorasModelAndImage() {
        let krea2 = Krea2Job(
            customModelRepo: "/Models/k2", loras: [LoraEntry(path: "/Loras/k.safetensors", modelFamily: .krea2)],
            imagePath: "/Lib/a.png"
        )
        let zimage = ZImageJob(
            customModelRepo: "/Models/z", loras: [LoraEntry(path: "/Loras/z.safetensors", modelFamily: .zimage)],
            imagePath: "/Lib/a.png"
        )
        #expect(Set(Krea2RunnerSpec.accessPaths(job: krea2)) == ["/Loras/k.safetensors", "/Models/k2", "/Lib/a.png"])
        #expect(Set(ZImageRunnerSpec.accessPaths(job: zimage)) == ["/Loras/z.safetensors", "/Models/z", "/Lib/a.png"])
    }

    @Test func ideogramReadsItsLorasAndModel() {
        let job = Ideogram4Job(
            customModelRepo: "/Models/i4", loras: [LoraEntry(path: "/Loras/i.safetensors", modelFamily: .ideogram4)]
        )
        #expect(Set(Ideogram4RunnerSpec.accessPaths(job: job)) == ["/Loras/i.safetensors", "/Models/i4"])
    }

    @Test func seedVR2ReadsItsSource() {
        #expect(SeedVR2RunnerSpec.accessPaths(job: SeedVR2Job(sourcePath: "/Lib/a.png")) == ["/Lib/a.png"])
    }

    @Test func repoIDsAreLeftOut() {
        let job = FluxJob(model: .custom, customModelRepo: "org/model", loras: [LoraEntry(path: "org/lora")])
        #expect(FluxRunnerSpec.accessPaths(job: job).isEmpty)
    }
}

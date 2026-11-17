import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// Splitting a finished multi-seed batch into one queue row per seed must carry
/// every user-settable field over. Each test sets all of them to non-default
/// values, expands three seeds, and compares field by field.
@MainActor
struct BatchExpansionTests {
    private let seeds = [11, 22, 33]
    private let paths = ["/o/1.png", "/o/2.png", "/o/3.png"]
    private let loras = [LoraEntry(path: "/l/a.safetensors", strength: 0.6, enabled: false, notes: "n", modelFamily: .krea2)]

    /// Expands `batch` in a store holding only it and returns the resulting rows.
    private func expand<Store: ProfileScopedJobStore & GenerationJobStore>(
        _ batch: Store.PersistedJob, in store: Store
    ) -> [Store.PersistedJob] where Store.PersistedJob == Store.Job {
        batch.seeds = seeds
        batch.outputPaths = paths
        batch.status = .completed
        store.jobs = [batch]
        store.expandBatchJob(batch)
        return store.jobs
    }

    /// The identity, seed and result checks every family shares.
    private func expectSplit(_ rows: [some GeneratedJob], of batch: some GeneratedJob) {
        #expect(rows.count == 3)
        #expect(Set(rows.map(\.id)).count == 3)
        #expect(!rows.contains { $0.id == batch.id })
        #expect(rows.map(\.seed) == seeds)
        #expect(rows.map(\.resolvedSeed) == seeds)
        #expect(rows.map(\.outputPath) == paths)
        #expect(rows.allSatisfy { $0.seeds.isEmpty && $0.outputPaths.isEmpty && $0.status == .completed })
        #expect(rows.allSatisfy { $0.board == batch.board && $0.width == batch.width && $0.height == batch.height })
        #expect(rows.allSatisfy { $0.quantize == batch.quantize && $0.createdAt == batch.createdAt })
    }

    @Test func fluxKeepsEveryField() {
        let batch = FluxJob(
            model: .custom, customModelRepo: "me/flux", customBaseModel: .flux2KleinBase4B,
            prompt: "p", negativePrompt: "np", width: 640, height: 832, steps: 7, guidance: 3.5,
            loras: loras, quantize: 4, lowRam: true, imagePath: "/i.png", imageStrength: 0.4,
            isEditMode: true, editImagePaths: ["/e1.png", "/e2.png"], board: "B",
            pidDecode: true, pidDegradeSigma: 0.3
        )
        let rows = expand(batch, in: JobStore())
        expectSplit(rows, of: batch)
        for row in rows {
            #expect(row.model == batch.model && row.customModelRepo == "me/flux")
            #expect(row.customBaseModel == .flux2KleinBase4B)
            #expect(row.prompt == "p" && row.negativePrompt == "np")
            #expect(row.steps == 7 && row.guidance == 3.5 && row.loras == loras && row.lowRam)
            #expect(row.imagePath == "/i.png" && row.imageStrength == 0.4)
            #expect(row.isEditMode && row.editImagePaths == ["/e1.png", "/e2.png"])
            #expect(row.pidDecode && row.pidDegradeSigma == 0.3)
        }
    }

    @Test func ideogram4KeepsEveryField() {
        var caption = IdeogramCaption.empty()
        caption.highLevelDescription = "a caption"
        let batch = Ideogram4Job(
            customModelRepo: "me/ideo", preset: .quality, caption: caption, usePlainPrompt: true,
            plainPrompt: "plain", width: 704, height: 960, quantize: 8, lowRam: true,
            strictValidation: true, loras: loras, board: "B", pidDecode: true, pidDegradeSigma: 0.3
        )
        let rows = expand(batch, in: Ideogram4JobStore())
        expectSplit(rows, of: batch)
        for row in rows {
            #expect(row.customModelRepo == "me/ideo" && row.preset == .quality)
            #expect(row.caption == caption && row.usePlainPrompt && row.plainPrompt == "plain")
            #expect(row.lowRam && row.strictValidation && row.loras == loras)
            #expect(row.pidDecode && row.pidDegradeSigma == 0.3)
            #expect(row.totalSteps == Ideogram4Preset.quality.stepCount)
        }
    }

    @Test func krea2KeepsEveryField() {
        let batch = Krea2Job(
            customModelRepo: "me/krea", prompt: "p", negativePrompt: "np", width: 640, height: 832,
            steps: 5, guidance: 2.5, quantize: 4, lowRam: true, loras: loras,
            imagePath: "/i.png", imageStrength: 0.4, board: "B", pidDecode: true, pidDegradeSigma: 0.3
        )
        let rows = expand(batch, in: Krea2JobStore())
        expectSplit(rows, of: batch)
        for row in rows {
            #expect(row.customModelRepo == "me/krea" && row.prompt == "p" && row.negativePrompt == "np")
            #expect(row.steps == 5 && row.guidance == 2.5 && row.lowRam && row.loras == loras)
            #expect(row.imagePath == "/i.png" && row.imageStrength == 0.4)
            #expect(row.pidDecode && row.pidDegradeSigma == 0.3)
        }
    }

    @Test func zImageKeepsEveryField() {
        let batch = ZImageJob(
            modelVariant: .zimage, customModelRepo: "me/z", prompt: "p", negativePrompt: "np",
            width: 640, height: 832, steps: 30, guidance: 4.0, quantize: 4, loras: loras,
            imagePath: "/i.png", imageStrength: 0.4, board: "B", pidDecode: true, pidDegradeSigma: 0.3
        )
        let rows = expand(batch, in: ZImageJobStore())
        expectSplit(rows, of: batch)
        for row in rows {
            #expect(row.modelVariant == .zimage && row.customModelRepo == "me/z")
            #expect(row.prompt == "p" && row.negativePrompt == "np")
            #expect(row.steps == 30 && row.guidance == 4.0 && row.loras == loras)
            #expect(row.imagePath == "/i.png" && row.imageStrength == 0.4)
            #expect(row.pidDecode && row.pidDegradeSigma == 0.3)
        }
    }

    @Test func qwen21KeepsEveryField() {
        let batch = Qwen21Job(
            isEditMode: true, editImagePaths: ["/e1.png", "/e2.png"], matchReferenceSize: false,
            prompt: "p", customModelRepo: "me/qwen", steps: 6, quantize: 4, width: 640, height: 832,
            loras: loras, lowRam: true, board: "B", enhancePrompt: true
        )
        let rows = expand(batch, in: Qwen21JobStore())
        expectSplit(rows, of: batch)
        for row in rows {
            #expect(row.isEditMode && row.editImagePaths == ["/e1.png", "/e2.png"])
            #expect(!row.matchReferenceSize && row.prompt == "p" && row.customModelRepo == "me/qwen")
            #expect(row.steps == 6 && row.loras == loras && row.lowRam && row.enhancePrompt)
        }
    }
}

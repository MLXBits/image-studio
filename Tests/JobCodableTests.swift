import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// The queue history on disk: every persisted job field survives a save and
/// load, and a record from an older build (fields missing, or a value this
/// build no longer knows) still loads with defaults instead of dropping the job.
@Suite("Job history encoding")
struct JobCodableTests {
    /// Whole seconds: the history file stores ISO 8601 dates, which drop fractions.
    private static let created = Date(timeIntervalSince1970: 1_700_000_000)
    private static let started = Date(timeIntervalSince1970: 1_700_000_060)
    private static let completed = Date(timeIntervalSince1970: 1_700_000_120)
    private static let id = UUID()
    private static let lora = LoraEntry(path: "/loras/style.safetensors", strength: 0.6, enabled: false, notes: "n")

    /// A value of the wrong type (hand-edited, or a field whose type a later
    /// build changed) falls back to its default; the job still loads.
    private static let mistyped = #"{"id": "\#(id.uuidString)", "board": 5, "seed": "x", "log": 7, "currentStep": "x"}"#

    /// The history keys each family writes. History files from earlier builds
    /// use exactly these, so the shared run-state coding must not change them.
    private static let runStateKeys: Set = [
        "status", "log", "outputPath", "resolvedSeed", "thumbnailData",
        "currentStep", "totalSteps", "createdAt", "startedAt", "completedAt",
    ]

    /// Encodes and decodes the way `JobHistoryFile` does.
    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: encoder.encode(value))
    }

    private func decode<T: Decodable>(_: T.Type, _ json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: Data(json.utf8))
    }

    /// Sets the run-state fields every job type persists to non-default values.
    private func finish(_ job: some GeneratedJob) {
        job.status = .failed("out of memory")
        job.log = "line 1\nline 2"
        job.outputPath = "/out/image.png"
        job.resolvedSeed = 31337
        job.thumbnailData = Data([1, 2, 3])
        job.currentStep = 7
        job.totalSteps = 12
        job.startedAt = Self.started
        job.completedAt = Self.completed
    }

    private func expectRunState(_ decoded: some GeneratedJob) {
        #expect(decoded.status == .failed("out of memory"))
        #expect(decoded.log == "line 1\nline 2")
        #expect(decoded.outputPath == "/out/image.png")
        #expect(decoded.resolvedSeed == 31337)
        #expect(decoded.thumbnailData == Data([1, 2, 3]))
        #expect(decoded.currentStep == 7)
        #expect(decoded.totalSteps == 12)
        #expect(decoded.startedAt == Self.started)
        #expect(decoded.completedAt == Self.completed)
    }

    // MARK: - Status

    @Test(arguments: [JobStatus.pending, .running, .completed, .cancelled, .failed("boom")])
    func everyStatusRoundTrips(_ status: JobStatus) throws {
        #expect(try roundTrip(status) == status)
    }

    // MARK: - Flux

    @Test func fluxKeepsEveryPersistedField() throws {
        let job = FluxJob(
            id: Self.id, model: .custom, customModelRepo: "me/model", customBaseModel: .flux2Klein4B,
            prompt: "a cat", negativePrompt: "blur", width: 832, height: 1216, seed: 5, seeds: [5, 6],
            steps: 20, guidance: 3.5, loras: [Self.lora], quantize: 4, lowRam: true,
            imagePath: "/in.png", imageStrength: 0.4, isEditMode: true, editImagePaths: ["/a.png", "/b.png"],
            board: "Cats", pidDecode: true, pidDegradeSigma: 0.3, createdAt: Self.created
        )
        finish(job)

        let decoded = try roundTrip(job)

        #expect(decoded.id == Self.id && decoded.createdAt == Self.created)
        #expect(decoded.model == .custom && decoded.customModelRepo == "me/model")
        #expect(decoded.customBaseModel == .flux2Klein4B)
        #expect(decoded.prompt == "a cat" && decoded.negativePrompt == "blur")
        #expect(decoded.width == 832 && decoded.height == 1216)
        #expect(decoded.seed == 5 && decoded.seeds == [5, 6])
        #expect(decoded.steps == 20 && decoded.guidance == 3.5)
        #expect(decoded.loras == [Self.lora])
        #expect(decoded.quantize == 4 && decoded.lowRam)
        #expect(decoded.imagePath == "/in.png" && decoded.imageStrength == 0.4)
        #expect(decoded.isEditMode && decoded.editImagePaths == ["/a.png", "/b.png"])
        #expect(decoded.board == "Cats")
        #expect(decoded.pidDecode && decoded.pidDegradeSigma == 0.3)
        expectRunState(decoded)
    }

    @Test func aBareFluxRecordLoadsWithDefaults() throws {
        let job = try decode(FluxJob.self, #"{"id": "\#(Self.id.uuidString)", "steps": 6}"#)

        #expect(job.id == Self.id)
        #expect(job.model == .flux2Klein9B && job.board == "Default")
        #expect(job.seed == -1 && job.seeds.isEmpty)
        #expect(job.status == .pending && job.log.isEmpty)
        // An old record without totalSteps takes it from its steps.
        #expect(job.totalSteps == 6)
    }

    /// A model a later build removed (or an older one never had) falls back to
    /// the default instead of failing the whole history file.
    @Test func anUnknownFluxModelFallsBackToTheDefault() throws {
        let job = try decode(FluxJob.self, #"{"id": "\#(Self.id.uuidString)", "model": "flux9-ultra"}"#)
        #expect(job.model == .flux2Klein9B)
    }

    // MARK: - Ideogram 4

    @Test func ideogram4KeepsEveryPersistedField() throws {
        var caption = IdeogramCaption.empty()
        caption.highLevelDescription = "a lighthouse at dusk"
        let job = Ideogram4Job(
            id: Self.id, customModelRepo: "me/ideo", preset: .quality, caption: caption,
            usePlainPrompt: true, plainPrompt: "plain", width: 768, height: 1344, seed: 9, seeds: [9, 10],
            quantize: 8, lowRam: true, strictValidation: true, loras: [Self.lora], board: "Sea",
            pidDecode: true, pidDegradeSigma: 0.2, createdAt: Self.created
        )
        finish(job)

        let decoded = try roundTrip(job)

        #expect(decoded.id == Self.id && decoded.createdAt == Self.created)
        #expect(decoded.customModelRepo == "me/ideo" && decoded.preset == .quality)
        #expect(decoded.caption == caption)
        #expect(decoded.usePlainPrompt && decoded.plainPrompt == "plain")
        #expect(decoded.width == 768 && decoded.height == 1344)
        #expect(decoded.seed == 9 && decoded.seeds == [9, 10])
        #expect(decoded.quantize == 8 && decoded.lowRam && decoded.strictValidation)
        #expect(decoded.loras == [Self.lora] && decoded.board == "Sea")
        #expect(decoded.pidDecode && decoded.pidDegradeSigma == 0.2)
        expectRunState(decoded)
    }

    @Test func aBareIdeogram4RecordLoadsWithDefaults() throws {
        let job = try decode(Ideogram4Job.self, #"{"id": "\#(Self.id.uuidString)", "preset": "V4_TURBO_12"}"#)

        #expect(job.preset == .turbo)
        #expect(job.caption == .empty() && !job.usePlainPrompt)
        #expect(job.quantize == 0 && job.board == "Default")
        // An old record without totalSteps takes it from its preset.
        #expect(job.totalSteps == Ideogram4Preset.turbo.stepCount)
    }

    // MARK: - Z-Image

    @Test func zimageKeepsEveryPersistedField() throws {
        let job = ZImageJob(
            id: Self.id, modelVariant: .zimage, customModelRepo: "me/z", prompt: "a fox",
            negativePrompt: "text", width: 896, height: 1152, seed: 3, seeds: [3, 4], steps: 28,
            guidance: 4.0, quantize: 6, loras: [Self.lora], imagePath: "/in.png", imageStrength: 0.5,
            board: "Fox", pidDecode: true, pidDegradeSigma: 0.1, createdAt: Self.created
        )
        finish(job)

        let decoded = try roundTrip(job)

        #expect(decoded.id == Self.id && decoded.createdAt == Self.created)
        #expect(decoded.modelVariant == .zimage && decoded.customModelRepo == "me/z")
        #expect(decoded.prompt == "a fox" && decoded.negativePrompt == "text")
        #expect(decoded.width == 896 && decoded.height == 1152)
        #expect(decoded.seed == 3 && decoded.seeds == [3, 4])
        #expect(decoded.steps == 28 && decoded.guidance == 4.0 && decoded.quantize == 6)
        #expect(decoded.loras == [Self.lora])
        #expect(decoded.imagePath == "/in.png" && decoded.imageStrength == 0.5)
        #expect(decoded.board == "Fox")
        #expect(decoded.pidDecode && decoded.pidDegradeSigma == 0.1)
        expectRunState(decoded)
    }

    /// Z-Image records from before the base model shipped have no variant: Turbo.
    @Test func aZImageRecordWithoutAVariantIsTurbo() throws {
        let job = try decode(ZImageJob.self, #"{"id": "\#(Self.id.uuidString)"}"#)

        #expect(job.modelVariant == .zimageTurbo)
        #expect(job.steps == 9 && job.totalSteps == 9)
        #expect(job.status == .pending)
    }

    // MARK: - SeedVR2

    @Test func seedVR2KeepsEveryPersistedField() throws {
        let job = SeedVR2Job(
            id: Self.id, sourcePath: "/out/src.png", scale: 4, softness: 0.25, is7B: true,
            quantize: 4, seed: 11, board: "Up", width: 2048, height: 3072, createdAt: Self.created
        )
        finish(job)

        let decoded = try roundTrip(job)

        #expect(decoded.id == Self.id && decoded.createdAt == Self.created)
        #expect(decoded.sourcePath == "/out/src.png")
        #expect(decoded.scale == 4 && decoded.softness == 0.25 && decoded.is7B)
        #expect(decoded.quantize == 4 && decoded.seed == 11 && decoded.board == "Up")
        #expect(decoded.width == 2048 && decoded.height == 3072)
        expectRunState(decoded)
    }

    @Test func aBareSeedVR2RecordLoadsWithDefaults() throws {
        let job = try decode(SeedVR2Job.self, #"{"id": "\#(Self.id.uuidString)"}"#)

        #expect(job.sourcePath.isEmpty)
        #expect(job.scale == 2 && !job.is7B && job.quantize == 8)
        #expect(job.width == 0 && job.height == 0 && job.totalSteps == 0)
    }

    // MARK: - Krea 2

    @Test func krea2KeepsEveryPersistedField() throws {
        let job = Krea2Job(
            id: Self.id, customModelRepo: "me/k", prompt: "a heron", negativePrompt: "noise",
            width: 960, height: 1280, seed: 8, seeds: [8, 9], steps: 12, guidance: 2.5, quantize: 6,
            lowRam: true, loras: [Self.lora], imagePath: "/in.png", imageStrength: 0.35, board: "Birds",
            pidDecode: true, pidDegradeSigma: 0.15, createdAt: Self.created
        )
        finish(job)

        let decoded = try roundTrip(job)

        #expect(decoded.id == Self.id && decoded.createdAt == Self.created)
        #expect(decoded.customModelRepo == "me/k")
        #expect(decoded.prompt == "a heron" && decoded.negativePrompt == "noise")
        #expect(decoded.width == 960 && decoded.height == 1280)
        #expect(decoded.seed == 8 && decoded.seeds == [8, 9])
        #expect(decoded.steps == 12 && decoded.guidance == 2.5 && decoded.quantize == 6 && decoded.lowRam)
        #expect(decoded.loras == [Self.lora])
        #expect(decoded.imagePath == "/in.png" && decoded.imageStrength == 0.35)
        #expect(decoded.board == "Birds")
        #expect(decoded.pidDecode && decoded.pidDegradeSigma == 0.15)
        expectRunState(decoded)
    }

    // MARK: - Qwen-Image 2.1

    @Test func qwen21KeepsEveryPersistedField() throws {
        let job = Qwen21Job(
            id: Self.id, isEditMode: true, editImagePaths: ["/a.png"], matchReferenceSize: false,
            prompt: "a tram", customModelRepo: "me/q", steps: 6, quantize: 4, width: 1152, height: 896,
            seed: 2, seeds: [2, 3], loras: [Self.lora], lowRam: true, board: "Trams", enhancePrompt: true,
            createdAt: Self.created
        )
        finish(job)

        let decoded = try roundTrip(job)

        #expect(decoded.id == Self.id && decoded.createdAt == Self.created)
        #expect(decoded.isEditMode && decoded.editImagePaths == ["/a.png"] && !decoded.matchReferenceSize)
        #expect(decoded.prompt == "a tram" && decoded.customModelRepo == "me/q")
        #expect(decoded.steps == 6 && decoded.quantize == 4)
        #expect(decoded.width == 1152 && decoded.height == 896)
        #expect(decoded.seed == 2 && decoded.seeds == [2, 3])
        #expect(decoded.loras == [Self.lora] && decoded.lowRam)
        #expect(decoded.board == "Trams" && decoded.enhancePrompt)
        expectRunState(decoded)
    }

    // MARK: - Every family

    private func expectMistypedFallsBack(_ job: some GeneratedJob) {
        #expect(job.id == Self.id)
        #expect(job.board == "Default" && job.seed == -1)
        #expect(job.log.isEmpty && job.currentStep == 0)
    }

    @Test func aMistypedValueFallsBackToItsDefaultInEveryFamily() throws {
        try expectMistypedFallsBack(decode(FluxJob.self, Self.mistyped))
        try expectMistypedFallsBack(decode(Ideogram4Job.self, Self.mistyped))
        try expectMistypedFallsBack(decode(Krea2Job.self, Self.mistyped))
        try expectMistypedFallsBack(decode(ZImageJob.self, Self.mistyped))
        try expectMistypedFallsBack(decode(Qwen21Job.self, Self.mistyped))
        try expectMistypedFallsBack(decode(SeedVR2Job.self, Self.mistyped))
    }

    private func encodedKeys(_ job: some GeneratedJob & Encodable) throws -> Set<String> {
        finish(job)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let object = try JSONSerialization.jsonObject(with: encoder.encode(job)) as? [String: Any]
        return Set(object?.keys.map { $0 } ?? [])
    }

    @Test func everyFamilyWritesTheSameHistoryKeys() throws {
        let generation: Set = ["id", "board", "width", "height", "seed", "seeds", "quantize", "loras"]
        #expect(try encodedKeys(FluxJob()) == Self.runStateKeys.union(generation).union([
            "model", "customModelRepo", "customBaseModel", "prompt", "negativePrompt", "steps", "guidance",
            "lowRam", "imagePath", "imageStrength", "isEditMode", "editImagePaths", "pidDecode", "pidDegradeSigma",
        ]))
        #expect(try encodedKeys(Ideogram4Job()) == Self.runStateKeys.union(generation).union([
            "customModelRepo", "preset", "caption", "usePlainPrompt", "plainPrompt", "lowRam",
            "strictValidation", "pidDecode", "pidDegradeSigma",
        ]))
        #expect(try encodedKeys(Krea2Job()) == Self.runStateKeys.union(generation).union([
            "customModelRepo", "prompt", "negativePrompt", "steps", "guidance", "lowRam",
            "imagePath", "imageStrength", "pidDecode", "pidDegradeSigma",
        ]))
        #expect(try encodedKeys(ZImageJob()) == Self.runStateKeys.union(generation).union([
            "modelVariant", "customModelRepo", "prompt", "negativePrompt", "steps", "guidance",
            "imagePath", "imageStrength", "pidDecode", "pidDegradeSigma",
        ]))
        #expect(try encodedKeys(Qwen21Job()) == Self.runStateKeys.union(generation).union([
            "isEditMode", "editImagePaths", "matchReferenceSize", "prompt", "customModelRepo", "steps",
            "lowRam", "enhancePrompt",
        ]))
        #expect(try encodedKeys(SeedVR2Job(sourcePath: "/s.png")) == Self.runStateKeys.union([
            "id", "sourcePath", "scale", "softness", "is7B", "quantize", "seed", "board", "width", "height",
        ]))
    }

    /// The id is the one field a record cannot do without.
    @Test func aRecordWithoutAnIdIsRejected() {
        #expect(throws: DecodingError.self) {
            try decode(SeedVR2Job.self, #"{"sourcePath": "/x.png"}"#)
        }
    }
}
